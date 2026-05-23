// review-server/lib/gemini.js
// 视频/图片分析的高层封装 — 基于 provider 抽象层

import { createWriteStream, unlinkSync, existsSync, mkdirSync, readFileSync } from 'fs';
import { Readable } from 'stream';
import { randomUUID } from 'crypto';
import { join } from 'path';
import { getProvider, supportsFileApi, getDefaultModel } from './providers/index.js';

const TMP_DIR = '/tmp/video-analyzer';
const MAX_BYTES = 100 * 1024 * 1024; // 100MB

const YOUTUBE_HOSTS = [/youtube\.com/, /youtu\.be/];

export function isYouTubeUrl(url) {
  try {
    const u = new URL(url);
    return YOUTUBE_HOSTS.some(r => r.test(u.hostname));
  } catch {
    return false;
  }
}

function ensureTmpDir() {
  if (!existsSync(TMP_DIR)) mkdirSync(TMP_DIR, { recursive: true });
}

export async function downloadVideo(url) {
  ensureTmpDir();
  const tmpPath = join(TMP_DIR, `analyze-${randomUUID()}.mp4`);

  const resp = await fetch(url, {
    headers: { 'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)' },
    signal: AbortSignal.timeout(60_000),
  });
  if (!resp.ok) throw new Error(`Download failed: ${resp.status} ${resp.statusText}`);

  const body = Readable.fromWeb(resp.body);
  const ws = createWriteStream(tmpPath);
  let bytes = 0;

  for await (const chunk of body) {
    bytes += chunk.length;
    if (bytes > MAX_BYTES) {
      ws.end();
      break;
    }
    ws.write(chunk);
  }
  ws.end();

  await new Promise((resolve, reject) => {
    ws.on('finish', resolve);
    ws.on('error', reject);
  });

  return tmpPath;
}

export function cleanupTmp(filePath) {
  try {
    if (filePath && existsSync(filePath)) unlinkSync(filePath);
  } catch { /* ignore */ }
}

const VIDEO_PROMPT = `你是一名顶级的 AI 视频工程专家与资深电影摄影师。你的任务是通过反向推导视频，输出结构化的分析结果。

执行核心准则：
- 客观拆解：严禁主观臆断
- 细节导向：拒绝空泛（如"好看"），必须描述具体材质、光型或运镜参数
- 镜头语言用专业术语（等效焦距、Dolly In、Rembrandt lighting、Teal & Orange 等）
- **切镜识别**：精确识别原视频实际切点（毫秒级），不允许把不同动作 / 不同景别合并成一段。如果原视频是快剪 viral 短片（连续 < 3s 切镜超过 3 次），按真实切点出 N 个独立 shot，N 不设上限。
- **覆盖完整时长**：shots 数组必须从 0 秒覆盖到 video_duration_sec 末尾，**禁止只分析前几十秒就停**。如果视频很长（3 分钟以上）shot 数会很多，可以适度精简每个 shot 的描述长度（保持核心信息），但不允许跳过后半段或提前 close JSON。

请用中文分析这个视频，严格按以下 JSON 格式输出，不要输出任何其他内容：

{
  "overview": "用 2-4 句话概括视频的完整故事",
  "characters": [
    { "name": "角色的描述性名称（如'黑围裙咖啡师'）", "appearance": "外貌、穿着、发型、肤质、服装材质等视觉特征", "role": "在故事中扮演的角色（主角/配角/路人）" }
  ],
  "shots": [
    {
      "shot_index": <integer, 1 起编号>,
      "start_sec": <float, 保留 2 位小数>,
      "end_sec": <float, 保留 2 位小数>,
      "description": "画面内容描述（主体 + 动作 + 环境）",
      "camera": "镜头语言：景别 + 运镜 + 等效焦距",
      "lighting": "灯光色彩：光型 + 色调",
      "scene": "场景环境描述",
      "emotion_tags": ["从下方 5 维度情感标签清单中选 0-3 个 (中文字符串) — 如果本镜头不属于任何维度就返回空数组 []"]
    }
  ],
  "dialogue": [
    { "start_sec": <float>, "end_sec": <float>, "speaker": "...", "text": "...", "translation": "..." }
  ],
  "metadata": { "genre": "...", "mood": "...", "style": "...", "language": "..." },
  "mandatory_props": ["核心剧情道具列表 — 没有它故事不成立的物件，如'监狱玻璃隔断'、'囚犯的小蛋糕'、'生日蜡烛'"],
  "ambient_props": ["应景饰品列表 — 增强氛围但非剧情核心的物件，如'派对帽'、'背景气球'。下游不会把它们当强约束传递。"],
  "video_duration_sec": <float, 视频总时长>
}

要求：
- shots 粒度：精确识别真实切点，不允许把"全景建立 + 主角动作 + 反应镜头"合并成一段
- shots 数量不设上限（viral 短片可能 9 镜以上）
- shots 必须覆盖完整 video_duration_sec（最后一个 shot 的 end_sec 必须等于或非常接近 video_duration_sec，**不允许只分析前 30-60 秒就停**）
- 运镜描述要具体（不要只写"镜头移动"）
- 角色名用描述性称呼，不要用"角色1""角色2"
- mandatory_props vs ambient_props 区分要严格：派对帽这种"增强氛围但故事不依赖它"的物品必须在 ambient_props，不在 mandatory_props
- dialogue 要求：纯 BGM 无对白返回 []，按 start_sec 排序，text 是原语言，translation 是中文

## emotion_tags 5 维度情感标签清单（混剪解说赛道用 — 给每个 shot 选 0-3 个最贴切的）

判断标准：这个 shot 在混剪视频里能当**什么角色**用？大多数 shot 只能当主线诱饵或情感插播之一，少数 shot 是揭晓画面。

1. **suspense_type — 主线诱饵类**（适合做混剪悬念开场）：
   - "异常移动"（物体在不该动的地方动：雪下蠕动 / 衣服里有东西 / 包包鼓包）
   - "危险逼近"（即将出事：猫走横梁 / 婴儿爬向悬崖）
   - "戏剧夸张行为"（拟人化反常：猫拉黑主人 / 狗用手机）
   - "奇迹时刻"（真实突破：婴儿第一步 / 残障突破 / 临场翻盘）
   - "双重误会"（场景自带"看似不正经"联想：陌生男女进厕所 / 老板娘后院）

2. **cutaway_pet — 萌宠插播类**（30 秒视频中段做 CTA 诱饵）：
   - "忧郁猫" / "撒娇小猫" / "企鹅幼崽" / "奔跑小狗" / "舔咬手指"

3. **cutaway_maternal — 母爱插播类**（中段 CTA 升级版）：
   - "跳舞青年献母亲" / "残疾母亲喂奶" / "雨中拥抱" / "海滩亲子" / "老母亲特写"

4. **cutaway_rescue — 救助公益类**（中段强情绪 CTA，海外用）：
   - "被困动物" / "残疾幼崽" / "流泪动物" / "天使 CG"

5. **reveal_type — 揭晓类**（混剪结尾用）：
   - "虚惊一场"（误会解除）/ "奇迹升华"（真突破）/ "喜剧落地"（真发生但好笑）/ "双重澄清"（NSFW 联想→正经原因）

如果某个 shot 不属于上述任何维度（如纯过场 / 字幕卡），emotion_tags 返回空数组 []. 维度名 (\`suspense_type\` / \`cutaway_pet\` 等) 不要写进数组, 只填具体的中文标签字符串.

- 只输出 JSON`;

const IMAGE_PROMPT = `你是一个专业图像分析师和文生图提示词工程师。请用中文分析这张图片，严格按以下 JSON 格式输出，不要输出任何其他内容：

{
  "description": "详细描述图片内容",
  "style": "视觉风格",
  "characters": [{ "name": "描述性名称", "appearance": "外貌穿着", "role": "角色定位" }],
  "composition": "构图分析",
  "reverse_prompt": "反推的英文文生图提示词"
}

要求：
- description 和 composition 用中文
- reverse_prompt 用英文
- 只输出 JSON`;

/**
 * 在原始 prompt 末尾追加用户反馈注入段（仅当 feedback 非空时）。
 * 字面文案必须与 chrome-extension/src/lib/gemini-browser.ts 的
 * buildPromptWithFeedback 保持一致 — 两端对同一视频应产出等价 prompt。
 */
function buildPromptWithFeedback(basePrompt, feedback) {
  if (!feedback || !String(feedback).trim()) return basePrompt;
  return `${basePrompt}

[用户反馈]
以下是用户对上一次分析结果的修正意见，请根据反馈重新分析视频，修正不准确的部分：

${String(feedback).trim()}

请注意：
- 以用户反馈为优先，修正与反馈冲突的部分
- 未被反馈指出的部分保持原样即可
- 仍然严格按相同 JSON 格式输出`;
}

/**
 * 视频流式分析 — 根据 provider 和 URL 类型自动选择路径
 */
export async function* analyzeVideoStream({ url, providerName, apiKey, model, feedback }) {
  const provider = getProvider(providerName);
  let tmpPath = null;

  try {
    const promptText = buildPromptWithFeedback(VIDEO_PROMPT, feedback);
    let parts;

    if (isYouTubeUrl(url)) {
      parts = [
        { fileData: { fileUri: url, mimeType: 'video/mp4' } },
        { text: promptText },
      ];
    } else if (supportsFileApi(providerName)) {
      tmpPath = await downloadVideo(url);
      const { uploadFile } = provider;
      const fileUri = await uploadFile({ apiKey, filePath: tmpPath, mimeType: 'video/mp4' });
      parts = [
        { fileData: { fileUri, mimeType: 'video/mp4' } },
        { text: promptText },
      ];
    } else {
      tmpPath = await downloadVideo(url);
      const buffer = readFileSync(tmpPath);
      if (buffer.length > 20 * 1024 * 1024) {
        throw new Error('视频超过 20MB，非 YouTube 视频在 APImart/Kie 上有大小限制，请改用官方 Gemini');
      }
      const base64 = buffer.toString('base64');
      parts = [
        { inlineData: { mimeType: 'video/mp4', data: base64 } },
        { text: promptText },
      ];
    }

    const contents = [{ role: 'user', parts }];

    for await (const chunk of provider.generateContentStream({ apiKey, model, contents })) {
      yield chunk;
    }
  } finally {
    cleanupTmp(tmpPath);
  }
}

/**
 * 远程视频 URL 分析 — Phase A YouTube URL 直传 fast path.
 *
 * Gemini 服务端用自己的网络拉 YouTube, 不走 GFW / 不读本地文件 / 不压缩.
 * 大视频 (>20MB inline cap) 优选这条, 节省 worker 下载等待 + 跳过 ffmpeg 压缩耗时.
 * Provider 必须支持 fileData URL (apimart-gemini / official-gemini 都支持).
 */
export async function analyzeRemoteVideoMarkdown({ fileUri, providerName, apiKey, model, prompt }) {
  const provider = getProvider(providerName);
  const contents = [{
    role: 'user',
    parts: [
      { fileData: { fileUri, mimeType: 'video/mp4' } },
      { text: prompt },
    ],
  }];
  let markdown = '';
  let usedModel = model;
  let tokenUsage = 0;
  for await (const chunk of provider.generateContentStream({ apiKey, model, contents })) {
    if (chunk.type === 'text') markdown += chunk.content;
    if (chunk.type === 'done') {
      usedModel = chunk.model || usedModel;
      tokenUsage = chunk.tokenUsage || tokenUsage;
    }
  }
  return { markdown, model: usedModel, tokenUsage };
}

/**
 * 本地视频文件分析 — 用于 Phase A worker 替代 Kimi CLI.
 *
 * 与 analyzeVideoStream 区别:
 * - 输入是 VPS 本地文件路径 (worker 已经上传过 source video), 不再 fetch
 * - 接收任意自定义 prompt (Kimi 风格 markdown 而不是 gemini.js 的 JSON 风格)
 * - 阻塞返回完整 markdown 字符串, 不流式 (worker 这个调用点等结果)
 * - 文件 >20MB 直接 throw (apimart-gemini 当前不支持 File API, 走 inline base64)
 */
export async function analyzeLocalVideoMarkdown({ filePath, providerName, apiKey, model, prompt }) {
  if (!existsSync(filePath)) {
    throw new Error(`Source video not found: ${filePath}`);
  }
  const provider = getProvider(providerName);
  const buffer = readFileSync(filePath);
  if (buffer.length > 20 * 1024 * 1024) {
    throw new Error(`视频 ${(buffer.length / 1048576).toFixed(1)}MB 超过 20MB inline 限制`);
  }
  const contents = [{
    role: 'user',
    parts: [
      { inlineData: { mimeType: 'video/mp4', data: buffer.toString('base64') } },
      { text: prompt },
    ],
  }];
  let markdown = '';
  let usedModel = model;
  let tokenUsage = 0;
  for await (const chunk of provider.generateContentStream({ apiKey, model, contents })) {
    if (chunk.type === 'text') markdown += chunk.content;
    if (chunk.type === 'done') {
      usedModel = chunk.model || usedModel;
      tokenUsage = chunk.tokenUsage || tokenUsage;
    }
  }
  return { markdown, model: usedModel, tokenUsage, sizeBytes: buffer.length };
}

/** 图片分析 */
export async function analyzeImage({ url, providerName, apiKey, model, feedback }) {
  const provider = getProvider(providerName);

  const resp = await fetch(url, {
    headers: { 'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)' },
    signal: AbortSignal.timeout(30_000),
  });
  if (!resp.ok) throw new Error(`Image fetch failed: ${resp.status}`);

  const contentType = resp.headers.get('content-type') || 'image/jpeg';
  const buffer = Buffer.from(await resp.arrayBuffer());
  const base64 = buffer.toString('base64');

  const contents = [{
    role: 'user',
    parts: [
      { inlineData: { mimeType: contentType, data: base64 } },
      { text: buildPromptWithFeedback(IMAGE_PROMPT, feedback) },
    ],
  }];

  const { text, model: usedModel, tokenUsage } = await provider.generateContent({ apiKey, model, contents });

  let parsed;
  try {
    const jsonMatch = text.match(/\{[\s\S]*\}/);
    parsed = jsonMatch ? JSON.parse(jsonMatch[0]) : JSON.parse(text);
  } catch {
    throw new Error('Gemini returned invalid JSON for image analysis');
  }

  return { result: parsed, model: usedModel, tokenUsage };
}

const SCENES_PROMPT_BASE = `You are a video analyst. Watch the video and extract a chronological list of scenes with wall-clock timestamps.

Output a pure JSON object with this exact shape (no markdown, no prose):

{
  "video_duration_sec": <float, total length of the video in seconds>,
  "scenes": [
    { "t_start": <float>, "t_end": <float>, "description": "<one plain-English sentence describing what visibly happens in this span>" }
  ]
}

Rules:
- Scenes must be contiguous and non-overlapping, covering the entire video.
- Each scene is 1.5 to 5 seconds long. Longer if nothing changes.
- Descriptions are in English, present tense, concrete visual actions. No emotions, no interpretation.
- Include any dialogue subtitles or on-screen text verbatim in the description using quotes.
- No more than 30 scenes total.

Output ONLY the JSON.`;

const CHARACTER_ID_PROMPT_BLOCK = `
In addition to scenes, identify up to 5 candidate NARRATIVE PROTAGONISTS — characters whose perspective could be used for a first-person commentary script.

For each candidate, include:
- name (English or transliteration, avoid Chinese)
- gender: "male" | "female" | "neutral"
- age_band: "<30" | "30-49" | "50+"
- appearance: one short sentence (clothing, ethnicity, hair, notable features)
- role_tagline: one short Chinese sentence describing their story role (e.g., "酒吧门口撞人的男主")
- emotion_arc: short arrow chain in Chinese (e.g., "愤怒 → 后悔 → 释然")
- recommended_protagonist: true for exactly ONE candidate (the strongest narrative carrier)

Also set:
- no_clear_protagonist: true if the video has no clear narrative protagonist (e.g., pure landscape, animal-only, object display). When true, character_candidates MUST be [].

Add these to the output JSON as top-level fields alongside scenes. The extended JSON shape is:

{
  "video_duration_sec": <float>,
  "scenes": [ ... ],
  "character_candidates": [
    {
      "name": "<string>",
      "gender": "male" | "female" | "neutral",
      "age_band": "<30" | "30-49" | "50+",
      "appearance": "<one sentence>",
      "role_tagline": "<一句中文>",
      "emotion_arc": "<情绪链>",
      "recommended_protagonist": true | false
    }
  ],
  "no_clear_protagonist": true | false
}`;

// Build the full SCENES_PROMPT with optional character identification block
function buildScenesPrompt({ identifyCharacters = false } = {}) {
  if (identifyCharacters) {
    return SCENES_PROMPT_BASE + '\n' + CHARACTER_ID_PROMPT_BLOCK;
  }
  return SCENES_PROMPT_BASE;
}

// Keep backward-compatible alias
const SCENES_PROMPT = SCENES_PROMPT_BASE;

/**
 * Extract time-stamped scenes for narration.
 * @param {object} opts
 * @param {string} [opts.url]
 * @param {string} [opts.localPath]
 * @param {string} opts.providerName
 * @param {string} opts.apiKey
 * @param {string} [opts.model]
 * @param {string} [opts.correction]
 * @param {boolean} [opts.identifyCharacters=false] — when true, appends character protagonist
 *   identification instructions to the prompt and parses character_candidates /
 *   no_clear_protagonist from the response.
 */
export async function analyzeVideoScenes({ url, localPath, providerName, apiKey, model, correction, identifyCharacters = false }) {
  const provider = getProvider(providerName);
  const resolvedModel = model || getDefaultModel(providerName);
  let tmpPath = null;

  // Build the base prompt, optionally with character identification instructions.
  const basePrompt = buildScenesPrompt({ identifyCharacters });

  // If a reviewer supplied a correction (e.g. "the previous read got the
  // relationships wrong — they're siblings, not strangers"), append it to the
  // prompt so Gemini biases toward that interpretation when describing scenes.
  const promptText = correction && correction.trim()
    ? `${basePrompt}\n\n## Reviewer correction (authoritative)\n\nA human reviewer flagged the previous analysis as wrong. Use this correction as ground truth when describing scenes — don't restate the misread:\n\n${correction.trim()}`
    : basePrompt;

  try {
    let parts;
    if (localPath) {
      // User-uploaded local file — skip download, read from disk.
      if (supportsFileApi(providerName)) {
        const fileUri = await provider.uploadFile({ apiKey, filePath: localPath, mimeType: 'video/mp4' });
        parts = [{ fileData: { fileUri, mimeType: 'video/mp4' } }, { text: promptText }];
      } else {
        const buf = readFileSync(localPath);
        if (buf.length > 20 * 1024 * 1024) {
          throw new Error('Video >20MB requires a File-API provider (e.g. official Gemini)');
        }
        parts = [
          { inlineData: { mimeType: 'video/mp4', data: buf.toString('base64') } },
          { text: promptText },
        ];
      }
    } else if (isYouTubeUrl(url)) {
      parts = [
        { fileData: { fileUri: url, mimeType: 'video/mp4' } },
        { text: promptText },
      ];
    } else if (supportsFileApi(providerName)) {
      tmpPath = await downloadVideo(url);
      const fileUri = await provider.uploadFile({ apiKey, filePath: tmpPath, mimeType: 'video/mp4' });
      parts = [
        { fileData: { fileUri, mimeType: 'video/mp4' } },
        { text: promptText },
      ];
    } else {
      tmpPath = await downloadVideo(url);
      const buf = readFileSync(tmpPath);
      if (buf.length > 20 * 1024 * 1024) {
        throw new Error('Video too large for non-File-API provider; switch to official Gemini');
      }
      parts = [
        { inlineData: { mimeType: 'video/mp4', data: buf.toString('base64') } },
        { text: promptText },
      ];
    }

    const contents = [{ role: 'user', parts }];
    const { text, model: usedModel, tokenUsage } = await provider.generateContent({
      apiKey,
      model: resolvedModel,
      contents,
    });

    // Extract JSON (tolerate markdown fences)
    let json = text.trim();
    const fence = json.match(/```(?:json)?\s*([\s\S]*?)\s*```/);
    if (fence) json = fence[1];
    const objMatch = json.match(/\{[\s\S]*\}/);
    if (!objMatch) throw new Error('Gemini scenes parse error: no JSON object in response');
    let parsed;
    try {
      parsed = JSON.parse(objMatch[0]);
    } catch (e) {
      throw new Error(`Gemini scenes parse error: ${e.message}`);
    }

    if (!Array.isArray(parsed.scenes) || parsed.scenes.length === 0) {
      throw new Error('Gemini scenes parse error: scenes array missing or empty');
    }

    const result = {
      video_duration_sec: Number(parsed.video_duration_sec) || 0,
      scenes: parsed.scenes,
      model: usedModel,
      tokenUsage,
    };

    // Attach character identification fields when requested (or when Gemini
    // spontaneously includes them, as a defensive measure).
    if (identifyCharacters || parsed.character_candidates !== undefined) {
      result.character_candidates = Array.isArray(parsed.character_candidates)
        ? parsed.character_candidates
        : [];
      result.no_clear_protagonist = typeof parsed.no_clear_protagonist === 'boolean'
        ? parsed.no_clear_protagonist
        : false;
    }

    return result;
  } finally {
    cleanupTmp(tmpPath);
  }
}

export { getDefaultModel };

/**
 * 本地视频文件分析 (doubao 版) — PoC 阶段跟 analyzeLocalVideoMarkdown 同函数签名,
 * 但 providerName 锁死 'doubao' + 多支持 fps 参数 + 返回 audio_tokens.
 *
 * 跟 Gemini 版的差别:
 * 1. 走 doubao chat/completions 不走 Gemini SSE
 * 2. fps 显式传 (默认 1, doubao spec)
 * 3. response 含 inputTokens / outputTokens / audioTokens 三维 (给 cost 算)
 * 4. 不支持 File API, 仅走 inline base64 (≤50MB, 跟 doubao spec 一致)
 *
 * @param {object} args
 * @param {string} args.filePath - VPS 本地 mp4 路径
 * @param {string} args.apiKey - 火山方舟 ARK_API_KEY (从 getActiveDoubaoKey 取)
 * @param {string} [args.model='doubao-seed-2-0-lite-260428']
 * @param {string} args.prompt - 复用 VIDEO_PROMPT 即可 (doubao 接受同一套 JSON 输出指令)
 * @param {number} [args.fps=1]
 * @returns {Promise<{markdown:string, model:string, tokenUsage:number, inputTokens:number, outputTokens:number, audioTokens:number|null, sizeBytes:number}>}
 */
export async function analyzeLocalVideoMarkdownDoubao({ filePath, apiKey, model, prompt, fps = 1 }) {
  if (!existsSync(filePath)) {
    throw new Error(`Source video not found: ${filePath}`);
  }
  const buffer = readFileSync(filePath);
  // doubao base64 inline cap 50MB (vs Gemini 20MB), 但 PoC 样本应远低于此
  if (buffer.length > 50 * 1024 * 1024) {
    throw new Error(`视频 ${(buffer.length / 1048576).toFixed(1)}MB 超过 doubao base64 inline 50MB 限制`);
  }
  // 走 provider 抽象层 'doubao' (lib/providers/index.js 已注册)
  const provider = getProvider('doubao');
  const contents = [{
    role: 'user',
    parts: [
      { inlineData: { mimeType: 'video/mp4', data: buffer.toString('base64') } },
      { text: prompt },
    ],
  }];
  // doubao 走非流式 (generateContent), 比 SSE 简单且 PoC 阻塞拿完整 markdown 够用
  const { text, model: usedModel, tokenUsage, inputTokens, outputTokens, audioTokens } =
    await provider.generateContent({ apiKey, model, contents, fps });
  return {
    markdown: text,
    model: usedModel,
    tokenUsage,
    inputTokens,
    outputTokens,
    audioTokens,
    sizeBytes: buffer.length,
  };
}
