#!/usr/bin/env node
// Usage: node tts_narration.mjs <work_dir>
// Input:  work_dir/script.json + skills/tracks/commentary/track.yaml
// Output: work_dir/narration.mp3, work_dir/narration_manifest.json
//
// Provider dispatch (COMMENTARY_TTS_PROVIDER env, default 'kie'):
//   kie     — elevenlabs/text-to-dialogue-v3 via Kie async jobs
//   minimax — MiniMax speech-2.8-hd async TTS (100+ preset voices + cloned voice IDs)
//
// Kie env:
//   KIE_API_KEY (primary) | ELEVENLABS_API_KEY (fallback)
//   KIE_API_URL (default https://api.kie.ai)
// MiniMax env:
//   MINIMAX_API_KEY
//   MINIMAX_API_URL (default https://api.minimaxi.com)
//   MINIMAX_MODEL (default speech-2.8-hd)
// Shared env:
//   COMMENTARY_VOICE (per-task voice override)
//   COMMENTARY_STABILITY (0-1, Kie only)
//   COMMENTARY_LANGUAGE_CODE (Kie language hint)
//   COMMENTARY_TTS_TIMEOUT_SEC (default 600)

import { readFileSync, writeFileSync, createWriteStream, existsSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';
import { pipeline } from 'stream/promises';
import { Readable } from 'stream';

const __dirname = dirname(fileURLToPath(import.meta.url));
const workDir = process.argv[2];
if (!workDir) { console.error('Usage: node tts_narration.mjs <work_dir>'); process.exit(2); }

const provider = (process.env.COMMENTARY_TTS_PROVIDER || 'kie').toLowerCase();
const totalTimeoutMs = (parseInt(process.env.COMMENTARY_TTS_TIMEOUT_SEC || '600', 10) || 600) * 1000;

const script = JSON.parse(readFileSync(join(workDir, 'script.json'), 'utf8'));
const taskJsonPath = join(workDir, 'task.json');
const task = existsSync(taskJsonPath) ? JSON.parse(readFileSync(taskJsonPath, 'utf8')) : {};

// task.video_metadata 在 queue JSON 里是字符串, api/v1/tasks 响应里是对象 — 统一解析.
let taskCp = {};
if (task?.video_metadata) {
  const vm = task.video_metadata;
  try {
    const parsed = typeof vm === 'string' ? JSON.parse(vm) : vm;
    taskCp = parsed?.commentary_params || {};
  } catch { /* leave taskCp as {} */ }
}

// voice_id 优先级：script.protagonist.voice_id (第一视角 Task 7 填) > env > commentary_params.voice > Brian
// env 名优先 COMMENTARY_TTS_VOICE_ID (新), 兼容 COMMENTARY_VOICE (export_params.sh 现行名).
const voiceId = script?.protagonist?.voice_id
             || process.env.COMMENTARY_TTS_VOICE_ID
             || process.env.COMMENTARY_VOICE
             || taskCp.voice
             || 'Brian';
console.log(`[tts] voice_id=${voiceId}`);

const trackDir = process.env.SKILLS_DIR
  ? join(process.env.SKILLS_DIR, 'tracks/commentary')
  : join(__dirname, '../../../skills/tracks/commentary');

function parseYaml(content) {
  const obj = {};
  const lines = content.split('\n');
  let currentKey = null;

  function cleanValue(raw) {
    let v = raw.replace(/\s+#.*$/, '').trim();
    if ((v.startsWith('"') && v.endsWith('"')) ||
        (v.startsWith("'") && v.endsWith("'"))) {
      v = v.slice(1, -1);
    }
    return v;
  }

  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    if (line.startsWith('  ')) {
      const match = trimmed.match(/^(\w+):\s*(.*)$/);
      if (match && currentKey) {
        if (!obj[currentKey] || typeof obj[currentKey] !== 'object') obj[currentKey] = {};
        const val = cleanValue(match[2]);
        obj[currentKey][match[1]] = val === '' ? val : (isNaN(val) ? val : parseFloat(val));
      }
    } else {
      const match = trimmed.match(/^(\w+):\s*(.*)$/);
      if (match) {
        currentKey = match[1];
        obj[currentKey] = cleanValue(match[2]);
      }
    }
  }
  return obj;
}

const track = parseYaml(readFileSync(join(trackDir, 'track.yaml'), 'utf8'));

function resolveStability() {
  if (process.env.COMMENTARY_STABILITY !== undefined && process.env.COMMENTARY_STABILITY !== '') {
    const n = parseFloat(process.env.COMMENTARY_STABILITY);
    if (!Number.isNaN(n) && n >= 0 && n <= 1) return n;
  }
  if (track.tts && track.tts.stability !== undefined && track.tts.stability !== '') {
    const n = typeof track.tts.stability === 'number' ? track.tts.stability : parseFloat(track.tts.stability);
    if (!Number.isNaN(n) && n >= 0 && n <= 1) return n;
  }
  return 0.5;
}

const fullText = [
  script.hook,
  ...(Array.isArray(script.events) ? script.events : []),
  script.tease,
  script.cta && script.cta.text,
  script.reveal,
].filter(Boolean).join(' ');

const MAX_CHARS = provider === 'minimax' ? 100000 : 5000;
if (fullText.length > MAX_CHARS) {
  console.error(`[tts] script too long: ${fullText.length} chars (${provider} limit ${MAX_CHARS})`);
  process.exit(1);
}

// ─────────────────────────────── Kie path ────────────────────────────────
async function runKie() {
  const apiKey = process.env.KIE_API_KEY || process.env.ELEVENLABS_API_KEY;
  if (!apiKey) { console.error('KIE_API_KEY or ELEVENLABS_API_KEY not set'); process.exit(2); }
  const kieBase = (process.env.KIE_API_URL || 'https://api.kie.ai').replace(/\/+$/, '');

  // voiceId resolved above (priority chain: protagonist.voice_id > env > commentary_params.voice > Brian)
  // track.tts.voice_id / COMMENTARY_VOICE / ELEVENLABS_VOICE_ID are subsumed by the shared chain above.
  const stability = resolveStability();
  const languageCode = (process.env.COMMENTARY_LANGUAGE_CODE || '').trim();

  async function createTask() {
    const url = `${kieBase}/api/v1/jobs/createTask`;
    const input = { dialogue: [{ voice: voiceId, text: fullText }], stability };
    if (languageCode) input.language_code = languageCode;
    const body = { model: 'elevenlabs/text-to-dialogue-v3', input };

    let lastErr;
    for (let attempt = 0; attempt < 3; attempt++) {
      try {
        const resp = await fetch(url, {
          method: 'POST',
          headers: { 'authorization': `Bearer ${apiKey}`, 'content-type': 'application/json' },
          body: JSON.stringify(body),
        });
        if (!resp.ok) {
          const detail = await resp.text().catch(() => '');
          throw new Error(`Kie createTask HTTP ${resp.status}: ${detail.slice(0, 200)}`);
        }
        const json = await resp.json();
        if (json.code !== 200 && json.code !== 0) {
          throw new Error(`Kie createTask code=${json.code} msg=${json.msg || json.message || ''}`);
        }
        const taskId = json.data && (json.data.taskId || json.data.task_id);
        if (!taskId) throw new Error(`Kie createTask: no taskId: ${JSON.stringify(json).slice(0, 200)}`);
        return taskId;
      } catch (e) {
        lastErr = e;
        const wait = 3000 * Math.pow(2, attempt);
        console.error(`[tts] createTask attempt ${attempt + 1}: ${e.message}; retry in ${wait}ms`);
        await new Promise(r => setTimeout(r, wait));
      }
    }
    throw lastErr;
  }

  async function poll(taskId) {
    const url = `${kieBase}/api/v1/jobs/recordInfo?taskId=${encodeURIComponent(taskId)}`;
    const deadline = Date.now() + totalTimeoutMs;
    const fastPhaseEnd = Date.now() + 30_000;

    while (Date.now() < deadline) {
      const waitMs = Date.now() < fastPhaseEnd ? 3000 : 10_000;
      try {
        const resp = await fetch(url, { headers: { 'authorization': `Bearer ${apiKey}` } });
        if (!resp.ok) {
          const detail = await resp.text().catch(() => '');
          console.error(`[tts] recordInfo HTTP ${resp.status}: ${detail.slice(0, 200)}; retry in ${waitMs}ms`);
          await new Promise(r => setTimeout(r, waitMs));
          continue;
        }
        const json = await resp.json();
        if (json.code !== 200 && json.code !== 0) {
          console.error(`[tts] recordInfo code=${json.code} msg=${json.msg || ''}; retry in ${waitMs}ms`);
          await new Promise(r => setTimeout(r, waitMs));
          continue;
        }
        const data = json.data || {};
        const state = data.state;
        if (state === 'success') {
          let parsed;
          try {
            parsed = typeof data.resultJson === 'string' ? JSON.parse(data.resultJson) : (data.resultJson || {});
          } catch (e) {
            throw new Error(`Kie resultJson parse failed: ${e.message}; raw=${String(data.resultJson).slice(0, 200)}`);
          }
          const urls = parsed.resultUrls || parsed.result_urls || [];
          if (!urls.length) throw new Error(`Kie success but no resultUrls: ${JSON.stringify(parsed).slice(0, 200)}`);
          return { audioUrl: urls[0], parsed };
        }
        if (state === 'fail' || state === 'failed') {
          throw new Error(`Kie TTS failed: code=${data.failCode || data.fail_code || '?'} msg=${data.failMsg || data.fail_msg || '?'}`);
        }
        console.log(`[tts] state=${state || '?'} taskId=${taskId}`);
      } catch (e) {
        if (/Kie TTS failed|Kie resultJson/.test(e.message)) throw e;
        console.error(`[tts] recordInfo attempt: ${e.message}; retry in ${waitMs}ms`);
      }
      await new Promise(r => setTimeout(r, waitMs));
    }
    throw new Error(`Kie TTS timeout after ${Math.round(totalTimeoutMs / 1000)}s (taskId=${taskId})`);
  }

  console.log(`[tts] creating Kie task (voice=${voiceId}, stability=${stability}${languageCode ? `, lang=${languageCode}` : ''}, chars=${fullText.length})`);
  const taskId = await createTask();
  console.log(`[tts] taskId=${taskId}; polling`);
  const { audioUrl, parsed } = await poll(taskId);
  const outPath = join(workDir, 'narration.mp3');
  const resp = await fetch(audioUrl);
  if (!resp.ok) throw new Error(`download audio HTTP ${resp.status}`);
  await pipeline(Readable.fromWeb(resp.body), createWriteStream(outPath));

  writeFileSync(join(workDir, 'narration_manifest.json'), JSON.stringify({
    provider: 'kie', taskId, voice_id: voiceId, stability,
    language_code: languageCode || null, text_char_count: fullText.length,
    audio_url: audioUrl, mp3_path: outPath, result_raw: parsed,
  }, null, 2));

  console.log(`[tts] narration.mp3 written (${fullText.length} chars, taskId=${taskId})`);
}

// ───────────────────────────── MiniMax path ──────────────────────────────
async function runMiniMax() {
  const apiKey = process.env.MINIMAX_API_KEY;
  if (!apiKey) { console.error('MINIMAX_API_KEY not set'); process.exit(2); }
  const base = (process.env.MINIMAX_API_URL || 'https://api.minimaxi.com').replace(/\/+$/, '');
  const model = process.env.MINIMAX_MODEL || 'speech-2.8-hd';

  // voiceId resolved above (priority chain: protagonist.voice_id > env > commentary_params.voice > Brian)
  // track.tts.minimax_voice_id / COMMENTARY_VOICE are subsumed by the shared chain above.

  async function createTask() {
    const url = `${base}/v1/t2a_async_v2`;
    const body = {
      model,
      text: fullText,
      language_boost: 'auto',
      voice_setting: { voice_id: voiceId, speed: 1, vol: 10, pitch: 0 },
      audio_setting: { audio_sample_rate: 32000, bitrate: 128000, format: 'mp3', channel: 2 },
    };

    let lastErr;
    for (let attempt = 0; attempt < 3; attempt++) {
      try {
        const resp = await fetch(url, {
          method: 'POST',
          headers: { 'Authorization': `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
          body: JSON.stringify(body),
        });
        if (!resp.ok) {
          const detail = await resp.text().catch(() => '');
          throw new Error(`MiniMax createTask HTTP ${resp.status}: ${detail.slice(0, 200)}`);
        }
        const json = await resp.json();
        const status = json?.base_resp?.status_code ?? 0;
        if (status !== 0) {
          throw new Error(`MiniMax createTask status=${status} msg=${json?.base_resp?.status_msg || ''}`);
        }
        const taskId = json.task_id;
        if (!taskId) throw new Error(`MiniMax createTask: no task_id: ${JSON.stringify(json).slice(0, 200)}`);
        return taskId;
      } catch (e) {
        lastErr = e;
        const wait = 3000 * Math.pow(2, attempt);
        console.error(`[tts] createTask attempt ${attempt + 1}: ${e.message}; retry in ${wait}ms`);
        await new Promise(r => setTimeout(r, wait));
      }
    }
    throw lastErr;
  }

  async function poll(taskId) {
    const url = `${base}/v1/query/t2a_async_query_v2?task_id=${encodeURIComponent(taskId)}`;
    const deadline = Date.now() + totalTimeoutMs;
    const fastPhaseEnd = Date.now() + 30_000;

    while (Date.now() < deadline) {
      const waitMs = Date.now() < fastPhaseEnd ? 3000 : 10_000;
      try {
        const resp = await fetch(url, { headers: { 'Authorization': `Bearer ${apiKey}` } });
        if (!resp.ok) {
          const detail = await resp.text().catch(() => '');
          console.error(`[tts] query HTTP ${resp.status}: ${detail.slice(0, 200)}; retry in ${waitMs}ms`);
          await new Promise(r => setTimeout(r, waitMs));
          continue;
        }
        const json = await resp.json();
        const status = json?.status || json?.base_resp?.status_msg || '';
        const baseStatus = json?.base_resp?.status_code ?? 0;
        if (baseStatus !== 0 && baseStatus !== undefined && baseStatus !== null) {
          console.error(`[tts] query base_resp=${baseStatus} msg=${json?.base_resp?.status_msg}; retry in ${waitMs}ms`);
          await new Promise(r => setTimeout(r, waitMs));
          continue;
        }
        if (status === 'Success' || status === 'success') {
          const fileId = json.file_id;
          if (!fileId) throw new Error(`MiniMax success but no file_id: ${JSON.stringify(json).slice(0, 200)}`);
          return { fileId, raw: json };
        }
        if (status === 'Failed' || status === 'failed') {
          throw new Error(`MiniMax TTS failed: ${JSON.stringify(json).slice(0, 200)}`);
        }
        console.log(`[tts] state=${status || '?'} taskId=${taskId}`);
      } catch (e) {
        if (/MiniMax TTS failed/.test(e.message)) throw e;
        console.error(`[tts] query attempt: ${e.message}; retry in ${waitMs}ms`);
      }
      await new Promise(r => setTimeout(r, waitMs));
    }
    throw new Error(`MiniMax TTS timeout after ${Math.round(totalTimeoutMs / 1000)}s (taskId=${taskId})`);
  }

  async function downloadFile(fileId, outPath) {
    const url = `${base}/v1/files/retrieve_content?file_id=${encodeURIComponent(fileId)}`;
    const resp = await fetch(url, { headers: { 'Authorization': `Bearer ${apiKey}` } });
    if (!resp.ok) {
      const detail = await resp.text().catch(() => '');
      throw new Error(`MiniMax download HTTP ${resp.status}: ${detail.slice(0, 200)}`);
    }
    const ctype = resp.headers.get('content-type') || '';
    if (ctype.includes('application/json')) {
      // Some variants wrap download URL in JSON: { base_resp, file: { download_url, file_id } }
      const json = await resp.json();
      const dl = json?.file?.download_url || json?.download_url;
      if (!dl) throw new Error(`MiniMax download: no download_url in JSON: ${JSON.stringify(json).slice(0, 200)}`);
      const r2 = await fetch(dl);
      if (!r2.ok) throw new Error(`MiniMax download (redirect) HTTP ${r2.status}`);
      await pipeline(Readable.fromWeb(r2.body), createWriteStream(outPath));
      return dl;
    }
    await pipeline(Readable.fromWeb(resp.body), createWriteStream(outPath));
    return url;
  }

  console.log(`[tts] creating MiniMax task (model=${model}, voice=${voiceId}, chars=${fullText.length})`);
  const taskId = await createTask();
  console.log(`[tts] taskId=${taskId}; polling`);
  const { fileId, raw } = await poll(taskId);
  const outPath = join(workDir, 'narration.mp3');
  const audioUrl = await downloadFile(fileId, outPath);

  writeFileSync(join(workDir, 'narration_manifest.json'), JSON.stringify({
    provider: 'minimax', taskId, model, voice_id: voiceId,
    text_char_count: fullText.length, file_id: fileId,
    audio_url: audioUrl, mp3_path: outPath, result_raw: raw,
  }, null, 2));

  console.log(`[tts] narration.mp3 written (${fullText.length} chars, taskId=${taskId}, file_id=${fileId})`);
}

try {
  if (provider === 'minimax') await runMiniMax();
  else if (provider === 'kie') await runKie();
  else { console.error(`[tts] unknown provider: ${provider}`); process.exit(2); }
  process.exit(0);
} catch (e) {
  console.error(`[tts] FAIL: ${e.message}`);
  process.exit(1);
}
