// scripts/worker/lib/doubao-tts.mjs
//
// Worker 镜像版. 跟 review-server/lib/doubao-tts/{protocol,error,concurrency,client}.js
// 协议层 + client 行为字节级一致. Task 1.9 protocol.test.js 双 import 测试防止漂移.
//
// 改动同步规则: 改了 review-server/lib/doubao-tts/* 必须同步改这里
// (EVENT / buildFrame / parseFrame / 错误分类 / client lifecycle / additions stringify).
//
// 依赖: ws (worker 仓库 package.json 已含, 跟 jimeng_cuihua / refresh-douyin-cdp 复用).
//
// Worker 跟 VPS 差异:
//   - semaphore env var: DOUBAO_TTS_WORKER_MAX_CONCURRENCY (worker only)
//   - semaphore default: 2 (worker 跑独立 Mac mini, 每台并发降低)
//   - user.uid: 'worker' (VPS 用 'review-server', 便于 grep audit log 区分来源)

import { WebSocket } from 'ws';
import { randomUUID } from 'node:crypto';

// ─── Protocol ────────────────────────────────────────────────────────────────
// Mirror of review-server/lib/doubao-tts/protocol.js
// 豆包 WS 双向流式协议: 4 字节 header + event_number + [session_id] + payload_size + payload.
// 整数大端. 详见 docs/接口文档/火山引擎-豆包语音 2.0 接口.md 第 2.1 节.
//
// 纯函数, 不依赖 ws 库.
//
// 帧布局:
//   header[4] = [0x11, msgType<<4|flags, ser<<4|comp, 0x00]
//   event_number  uint32  (flags 含 0b0100 时存在)
//   [session_id_len uint32 + session_id]  (session/data 类事件)
//   payload_size  uint32
//   payload
//
// msgType: 0b0001 Full-client request / 0b1001 Full-server response /
//          0b1011 Audio-only response  / 0b1111 Error
// ser:     0b0000 Raw / 0b0001 JSON

export const EVENT = {
  StartConnection: 1,
  FinishConnection: 2,
  ConnectionStarted: 50,
  ConnectionFailed: 51,
  ConnectionFinished: 52,
  StartSession: 100,
  CancelSession: 101,
  FinishSession: 102,
  SessionStarted: 150,
  SessionCanceled: 151,
  SessionFinished: 152,
  SessionFailed: 153,
  TaskRequest: 200,
  TTSSentenceStart: 350,
  TTSSentenceEnd: 351,
  TTSResponse: 352,
  TTSSubtitle: 360, // word-level 时间戳事件 (enable_subtitle=true 才会有)
};

export const EVENT_NAME = Object.fromEntries(
  Object.entries(EVENT).map(([k, v]) => [v, k]),
);

/**
 * 构造一帧二进制消息 (客户端 → 服务端, Full-client request).
 *
 * 低层编码器, 不强制 session 类事件必带 sessionId (调用方 / client 层负责语义校验).
 *
 * @param {object} opts
 * @param {number} opts.event - 事件号 (EVENT.X)
 * @param {object|Buffer|null} opts.payload - JSON object 或 raw buffer
 * @param {string|null} [opts.sessionId] - session 类 / data 类事件必填
 * @returns {Buffer}
 */
export function buildFrame({ event, payload, sessionId = null }) {
  const isJson = payload && typeof payload === 'object' && !Buffer.isBuffer(payload);
  const payloadBuf = isJson
    ? Buffer.from(JSON.stringify(payload))
    : (Buffer.isBuffer(payload) ? payload : Buffer.alloc(0));

  const header = Buffer.from([
    0x11,                   // v1 + 4-byte header
    0x14,                   // Full-client request (0b0001) + event-number flag (0b0100)
    isJson ? 0x10 : 0x00,   // JSON (0b0001<<4) / Raw (0b0000<<4), no compression
    0x00,                   // reserved
  ]);

  const eventBuf = Buffer.alloc(4);
  eventBuf.writeUInt32BE(event, 0);

  let idBuf = Buffer.alloc(0);
  if (sessionId) {
    const sid = Buffer.from(sessionId);
    const sidLen = Buffer.alloc(4);
    sidLen.writeUInt32BE(sid.length, 0);
    idBuf = Buffer.concat([sidLen, sid]);
  }

  const sizeBuf = Buffer.alloc(4);
  sizeBuf.writeUInt32BE(payloadBuf.length, 0);

  return Buffer.concat([header, eventBuf, idBuf, sizeBuf, payloadBuf]);
}

/**
 * 解析一帧响应消息. 低层解码器, 不做语义校验 (truncation / 空 session_id /
 * 协议外字段由 client 层兜底).
 *
 * @param {Buffer} buf
 * @returns {{ type: 'error', errorCode: number, payload: any }
 *         | { type: 'data', event: number|null, sessionId: string|null,
 *             connectionId: string|null, messageType: number, payload: Buffer|object|string|null }}
 */
export function parseFrame(buf) {
  const headerSize = (buf[0] & 0x0f) * 4;
  const messageType = (buf[1] >> 4) & 0x0f;
  const flags = buf[1] & 0x0f;
  const serialization = (buf[2] >> 4) & 0x0f;

  let offset = headerSize;

  // Error frame (0xf): 4 字节 errorCode + 4 字节 payloadSize + JSON payload
  if (messageType === 0xf) {
    const errorCode = buf.readUInt32BE(offset); offset += 4;
    const payloadSize = buf.readUInt32BE(offset); offset += 4;
    const raw = buf.slice(offset, offset + payloadSize).toString('utf8');
    let parsed;
    try { parsed = JSON.parse(raw); } catch { parsed = raw; }
    return { type: 'error', errorCode, payload: parsed };
  }

  const hasEvent = (flags & 0b0100) === 0b0100;
  let event = null;
  if (hasEvent) {
    event = buf.readUInt32BE(offset); offset += 4;
  }

  // Downstream event classification:
  //   50/51/52 → connection_id (Connect-class server frames)
  //   100-360  → session_id (Session/Data-class server frames)
  // (events 1/2 are upstream-only; never decoded here)
  let sessionId = null;
  let connectionId = null;
  if (event !== null) {
    const isConnId = [50, 51, 52].includes(event);
    // Range upper bound 360 = TTSSubtitle (highest data-class event in spec §2.3+§2.4).
    // Bump if Doubao adds new data-class events above this.
    const hasSessionId = event >= 100 && event <= 360;
    if (isConnId || hasSessionId) {
      const idLen = buf.readUInt32BE(offset); offset += 4;
      const idStr = buf.slice(offset, offset + idLen).toString('utf8');
      offset += idLen;
      if (isConnId) connectionId = idStr; else sessionId = idStr;
    }
  }

  let payload = null;
  if (offset + 4 <= buf.length) {
    const payloadSize = buf.readUInt32BE(offset); offset += 4;
    const raw = buf.slice(offset, offset + payloadSize);
    if (serialization === 0b0001) {
      try { payload = JSON.parse(raw.toString('utf8')); } catch { payload = raw.toString('utf8'); }
    } else {
      payload = raw;
    }
  }

  return { type: 'data', event, sessionId, connectionId, messageType, payload };
}

// ─── Error ───────────────────────────────────────────────────────────────────
// Mirror of review-server/lib/doubao-tts/error.js
// 豆包 TTS 错误分类: 4xxxxxxx 客户端不可重试 / 5xxxxxxx 服务端可重试 / 20000000 成功.

export class DoubaoTtsError extends Error {
  constructor(message, { code, kind, logid, retryable } = {}) {
    super(message);
    this.name = 'DoubaoTtsError';
    this.code = code;
    this.kind = kind;
    this.logid = logid;
    this.retryable = retryable;
  }
}

/**
 * 把豆包错误码映射成 DoubaoTtsError. 成功码返 null.
 *
 * @param {number} code - 豆包返的 error code
 * @param {object} [ctx] - { logid, payload }
 * @returns {DoubaoTtsError|null}
 */
export function classifyError(code, ctx = {}) {
  if (code === 20000000) return null;

  const { logid, payload } = ctx;
  const detail = typeof payload === 'object' ? JSON.stringify(payload) : String(payload || '');

  let kind, retryable;
  // 豆包 client_param range: [45000000, 50000000).
  // 40xxxxxx-44xxxxxx (auth/quota 等) 留给 else 默认重试 (defensive — 文档没明确分类).
  if (code >= 45000000 && code < 50000000) {
    kind = 'client_param';
    retryable = false;
  } else {
    // 55xxxxxx + 任何未知 6xxxxxxx 都按服务端瞬态处理 (defensive)
    kind = 'server';
    retryable = true;
  }

  return new DoubaoTtsError(
    `Doubao TTS error code=${code}${detail ? ` payload=${detail}` : ''}${logid ? ` logid=${logid}` : ''}`,
    { code, kind, logid, retryable },
  );
}

/**
 * 把网络层错误 (WS close / connect failed) 包成 DoubaoTtsError.
 * Idempotent: 已经是 DoubaoTtsError 的直接返回原实例.
 *
 * @param {Error|object|null|undefined} err - 原始错误 (允许 falsy, 内部兜底成 'unknown network error')
 * @param {object} [ctx]
 * @param {string} [ctx.logid]
 * @returns {DoubaoTtsError} kind='network', retryable=true
 */
export function wrapNetworkError(err, { logid } = {}) {
  if (err instanceof DoubaoTtsError) return err;
  const message = err?.message || String(err ?? '') || 'unknown network error';
  return new DoubaoTtsError(
    `Doubao TTS network error: ${message}`,
    { code: null, kind: 'network', logid, retryable: true },
  );
}

// ─── Semaphore ───────────────────────────────────────────────────────────────
// Mirror of review-server/lib/doubao-tts/concurrency.js (createSemaphore)
// + lazy-init wrapper from client.js (getSemaphore).
//
// Worker-specific divergence:
//   - env var: DOUBAO_TTS_WORKER_MAX_CONCURRENCY (vs VPS DOUBAO_TTS_MAX_CONCURRENCY)
//   - default: 2 (vs VPS 6) — worker 跑独立 Mac mini, 每台并发降低

function createSemaphore(maxConcurrency) {
  if (!Number.isInteger(maxConcurrency) || maxConcurrency < 1) {
    throw new Error(`createSemaphore: maxConcurrency must be positive integer, got ${maxConcurrency}`);
  }
  let active = 0;
  const queue = [];

  function next() {
    if (active >= maxConcurrency || queue.length === 0) return;
    active++;
    const { fn, resolve, reject } = queue.shift();
    Promise.resolve()
      .then(fn)
      .then(resolve, reject)
      .finally(() => { active--; next(); });
  }

  return {
    async acquire(fn) {
      return new Promise((resolve, reject) => {
        queue.push({ fn, resolve, reject });
        next();
      });
    },
    get active() { return active; },
    get queued() { return queue.length; },
  };
}

// Lazy-init: 第一次 acquire 时才读 env, 让测试可以在 import 后 setEnv 改 max.
let _semaphore = null;
function getSemaphore() {
  if (!_semaphore) {
    const max = parseInt(process.env.DOUBAO_TTS_WORKER_MAX_CONCURRENCY || '2', 10);
    _semaphore = createSemaphore(max);
  }
  return _semaphore;
}

// ─── Client ──────────────────────────────────────────────────────────────────
// Mirror of review-server/lib/doubao-tts/client.js
// 主入口: 跑一次完整的豆包 TTS 合成 (单 WS 连接 + 单 session).
//
// 事件流 (POC + docs/接口文档/火山引擎-豆包语音 2.0 接口.md 第 2.3 节):
//   1   StartConnection  →  50 ConnectionStarted
//   100 StartSession     → 150 SessionStarted
//   200 TaskRequest      → 350/351/352/360 (sentence start / end / audio / subtitle)
//   102 FinishSession    → 152 SessionFinished
//   2   FinishConnection →  52 ConnectionFinished
//
// 内置 semaphore 限并发 (env DOUBAO_TTS_WORKER_MAX_CONCURRENCY 默认 2, 跟 worker 内
// 所有 TTS 调用复用同一个全局, 不要在 caller 层再开一个 — 否则限不住).
//
// 不做内部 retry / ai_call_log — 那是 caller 的事.

const DEFAULT_WS_URL = 'wss://openspeech.bytedance.com/api/v3/tts/bidirection';
const DEFAULT_RESOURCE_ID = 'seed-tts-2.0';
const DEFAULT_SUB_MODEL = 'expressive';
const SUB_MODEL_FULL = {
  standard: 'seed-tts-2.0-standard',
  expressive: 'seed-tts-2.0-expressive',
};

/**
 * 跑一次完整的豆包 TTS 合成. 单 WS 连接 + 单 session.
 *
 * @param {object} opts
 * @param {string} opts.text - 待合成文本
 * @param {string} opts.voiceId - speaker_id e.g. 'en_female_dacey_uranus_bigtts'
 * @param {'standard'|'expressive'} [opts.subModel='expressive']
 * @param {string} [opts.apiKey=process.env.VOLC_TTS_API_KEY]
 * @param {string} [opts.wsUrl=DEFAULT_WS_URL] - test override
 * @param {string} [opts.resourceId='seed-tts-2.0']
 * @param {string} [opts.format='mp3']
 * @param {number} [opts.sampleRate=24000]
 * @param {number} [opts.bitRate=64000]
 * @param {boolean} [opts.enableSubtitle=true]
 * @param {string} [opts.explicitLanguage] - 默认按 voiceId 前缀推断 'en'
 * @param {string} [opts.emotion]
 * @returns {Promise<{ audioBuffer: Buffer, durationS: number|null, voiceId: string,
 *                    subModel: string, subtitleWords: object[]|null,
 *                    rawSentenceText: string, usage: {textWords: number|null, billableChars: number|null},
 *                    logId: string|null }>}
 */
export async function runDoubaoTts(opts) {
  return getSemaphore().acquire(() => runOnce(opts));
}

async function runOnce({
  text,
  voiceId,
  subModel = DEFAULT_SUB_MODEL,
  apiKey = process.env.VOLC_TTS_API_KEY,
  wsUrl = DEFAULT_WS_URL,
  resourceId = DEFAULT_RESOURCE_ID,
  format = 'mp3',
  sampleRate = 24000,
  bitRate = 64000,
  enableSubtitle = true,
  explicitLanguage,
  emotion,
}) {
  // Validation: caller bugs throw before WS handshake.
  if (!apiKey) {
    throw new DoubaoTtsError('VOLC_TTS_API_KEY not set', {
      kind: 'auth',
      retryable: false,
    });
  }
  if (!SUB_MODEL_FULL[subModel]) {
    throw new DoubaoTtsError(`invalid subModel: ${subModel}`, {
      kind: 'client_param',
      retryable: false,
    });
  }
  const subModelFull = SUB_MODEL_FULL[subModel];

  const connectId = randomUUID();
  const sessionId = randomUUID();

  const ws = new WebSocket(wsUrl, {
    headers: {
      'X-Api-Key': apiKey,
      'X-Api-Resource-Id': resourceId,
      'X-Api-Connect-Id': connectId,
      // 让服务端在 SessionFinished 里带回权威 text_words (官方计费维度).
      'X-Control-Require-Usage-Tokens-Return': 'text_words',
    },
  });

  let logId = null;
  ws.on('upgrade', (res) => {
    logId = res.headers['x-tt-logid'] || null;
  });

  const audioChunks = [];
  let subtitleWords = null;
  let rawSentenceText = '';
  let usage = null;
  let sessionDone = false;

  // additions 必须 stringify (jsonstring type per spec).
  // POC 踩过: 直接传 object 会让 server 返 "cannot unmarshal object into req_params.additions of type string".
  // Drift 1 (2026-05-22 Task 1.7 live test): enable_subtitle 应该在 req_params.audio_params 里
  // (docs/接口文档/火山引擎-豆包语音 2.0 接口.md line 282-294), 不是在 additions jsonstring 里.
  // POC + mock server 都基于错误假设, live 才发现.
  const additionsObj = { disable_markdown_filter: true };
  if (explicitLanguage) additionsObj.explicit_language = explicitLanguage;
  else if (voiceId.startsWith('en_')) additionsObj.explicit_language = 'en';

  const audioParams = { format, sample_rate: sampleRate, bit_rate: bitRate };
  if (enableSubtitle) audioParams.enable_subtitle = true;
  if (emotion) audioParams.emotion = emotion;

  try {
    await new Promise((resolve, reject) => {
      const closeWith = (err) => {
        try {
          ws.close();
        } catch {
          /* ignore */
        }
        if (err) reject(err);
        else resolve();
      };

      ws.on('open', () => {
        ws.send(buildFrame({ event: EVENT.StartConnection, payload: {} }));
      });

      ws.on('message', (data) => {
        const buf = Buffer.isBuffer(data) ? data : Buffer.from(data);
        const frame = parseFrame(buf);

        if (frame.type === 'error') {
          const err = classifyError(frame.errorCode, { logid: logId, payload: frame.payload });
          return closeWith(err);
        }

        const { event, payload } = frame;

        // Audio frames: raw bytes, append and return immediately.
        if (event === EVENT.TTSResponse && Buffer.isBuffer(payload)) {
          audioChunks.push(payload);
          return;
        }

        switch (event) {
          case EVENT.ConnectionStarted: {
            const sessionPayload = {
              user: { uid: 'worker' },
              event: EVENT.StartSession,
              namespace: 'BidirectionalTTS',
              req_params: {
                text: '',
                model: subModelFull,
                speaker: voiceId,
                audio_params: audioParams,
                additions: JSON.stringify(additionsObj), // jsonstring type
              },
            };
            ws.send(buildFrame({ event: EVENT.StartSession, sessionId, payload: sessionPayload }));
            break;
          }
          case EVENT.SessionStarted: {
            const taskPayload = {
              user: { uid: 'worker' },
              event: EVENT.TaskRequest,
              namespace: 'BidirectionalTTS',
              req_params: { text, speaker: voiceId },
            };
            ws.send(buildFrame({ event: EVENT.TaskRequest, sessionId, payload: taskPayload }));
            ws.send(buildFrame({ event: EVENT.FinishSession, sessionId, payload: {} }));
            break;
          }
          case EVENT.TTSSubtitle:
            // TODO(2026-05-22): TTSSubtitle event number unverified. Task 1.7 live probe
            // shows real server sends event 364 with UUID payload, not subtitle words at 360.
            // 可能是 event number 不同, 或是 2-step protocol (UUID first, words later).
            // Caller (commentary cron) handles subtitleWords null gracefully via
            // cuesFromWordTimestamps → cuesFromAlignment → cuesFromWordProportion 3-layer
            // fallback in buildSimpleSrt. Investigate when ai_call_log shows missing subtitle data.
            subtitleWords = payload?.words || null;
            if (payload?.text) rawSentenceText = payload.text;
            break;
          case EVENT.TTSSentenceEnd:
            if (payload?.text && !rawSentenceText) rawSentenceText = payload.text;
            break;
          case EVENT.SessionFinished: {
            sessionDone = true;
            // Drift 2 (2026-05-22 Task 1.7 live test): 真实服务器返
            // payload.usage.text_words 嵌套, 不是 payload.text_words 顶层.
            // 之前 ai_call_log billable_chars 会全 fallback 到 text.length
            // (truthy-null silent fallback bug 的 sibling, mock 跟旧假设一致没暴露).
            // 只在嵌套 payload.usage.text_words 是合法 number > 0 时才设 usage;
            // 否则 leave null 让外层 || 兜底 fire 走 text.length.
            const serverTextWords = payload?.usage?.text_words;
            if (typeof serverTextWords === 'number' && serverTextWords > 0) {
              usage = {
                textWords: serverTextWords,
                billableChars: serverTextWords,
              };
            }
            ws.send(buildFrame({ event: EVENT.FinishConnection, payload: {} }));
            break;
          }
          case EVENT.SessionFailed:
            return closeWith(
              new DoubaoTtsError(`SessionFailed: ${JSON.stringify(payload)}`, {
                code: payload?.code ?? null,
                kind: 'server',
                logid: logId,
                retryable: true,
              }),
            );
          case EVENT.ConnectionFailed:
            return closeWith(
              new DoubaoTtsError(`ConnectionFailed: ${JSON.stringify(payload)}`, {
                code: payload?.status_code ?? null,
                kind: 'auth',
                logid: logId,
                retryable: false,
              }),
            );
          case EVENT.ConnectionFinished:
            return closeWith(null);
          default:
            // 其他事件 (TTSSentenceStart 等) 不需要特殊处理.
            break;
        }
      });

      ws.on('error', (err) => closeWith(wrapNetworkError(err, { logid: logId })));
      ws.on('close', (code) => {
        if (!sessionDone) {
          reject(
            wrapNetworkError(new Error(`ws closed early code=${code}`), { logid: logId }),
          );
        }
      });
    });
  } finally {
    try {
      ws.close();
    } catch {
      /* ignore */
    }
  }

  const audioBuffer = Buffer.concat(audioChunks);
  const durationS =
    subtitleWords && subtitleWords.length
      ? subtitleWords[subtitleWords.length - 1].endTime
      : null;

  return {
    audioBuffer,
    durationS,
    voiceId,
    subModel,
    subtitleWords,
    rawSentenceText,
    // 服务端没给 text_words 时降级用 text.length (中文按字符 / 英文按字符, 不准但不为 null).
    usage: usage || { textWords: text.length, billableChars: text.length },
    logId,
  };
}
