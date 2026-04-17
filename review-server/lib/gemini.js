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

请用中文分析这个视频，严格按以下 JSON 格式输出，不要输出任何其他内容：

{
  "overview": "用 2-4 句话概括视频的完整故事（包括开头、发展、高潮、结尾）",
  "characters": [
    {
      "name": "角色的描述性名称（如'黑围裙咖啡师'）",
      "appearance": "外貌、穿着、发型、肤质、服装材质等视觉特征",
      "role": "在故事中扮演的角色（主角/配角/路人）"
    }
  ],
  "shots": [
    {
      "time": "起止时间（如 0:00-0:03）",
      "description": "画面内容描述（主体 + 动作 + 环境）",
      "camera": "镜头语言：景别（远景/全景/中景/近景/特写）+ 运镜（推/拉/摇/移/跟/固定/航拍/手持）+ 等效焦距（如 35mm / 85mm）",
      "lighting": "灯光色彩：光型（顺光/侧光/逆光/Rembrandt 等）+ 色调（如 Teal & Orange、高对比度）",
      "scene": "场景环境描述（地理位置/建筑风格/天气/前后景）"
    }
  ],
  "dialogue": [
    {
      "time": "起止时间（如 0:00-0:05）",
      "speaker": "说话人的描述性称呼（如'旁白'、'黑围裙咖啡师'、'画外音'），尽量跟 characters 里的 name 保持一致",
      "text": "原语言台词，忠实抄录，不要意译",
      "translation": "中文翻译。如果原语言就是中文则留空字符串"
    }
  ],
  "metadata": {
    "genre": "视频类型（剧情/舞蹈/搞笑/教程/Vlog 等）",
    "mood": "整体基调（温馨/紧张/搞笑/感人等）",
    "style": "渲染风格（真实摄影/胶片质感/3D 渲染 等，可用专业术语如 Kodak 5219 / UE5 render）",
    "language": "视频中使用的语言"
  }
}

要求：
- 分镜粒度约 2-5 秒一段，覆盖视频全部时长
- 运镜描述要具体（不要只写"镜头移动"，要写"缓慢向左摇摄 + 浅景深虚化前景"）
- 角色名用描述性称呼，不要用"角色1""角色2"
- dialogue 要求：
  - 如果视频完全无对白或只有纯 BGM，返回空数组 []
  - 听到的台词/旁白逐条列出，一句一条（不要合并多句）
  - speaker 用描述性名称（如"旁白"、"女主"、"黑围裙咖啡师"），尽量跟 characters 对应
  - text 是原语言（英文就写英文、日文就写日文），不要翻译
  - translation 是中文翻译；如果 text 已经是中文就留空字符串 ""
  - 画面上出现的硬字幕（比如 "#shorts"、弹幕、标题字）不算对白，不要写进来
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

const SCENES_PROMPT = `You are a video analyst. Watch the video and extract a chronological list of scenes with wall-clock timestamps.

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

/**
 * Extract time-stamped scenes for narration.
 */
export async function analyzeVideoScenes({ url, localPath, providerName, apiKey, model, correction }) {
  const provider = getProvider(providerName);
  const resolvedModel = model || getDefaultModel(providerName);
  let tmpPath = null;

  // If a reviewer supplied a correction (e.g. "the previous read got the
  // relationships wrong — they're siblings, not strangers"), append it to the
  // prompt so Gemini biases toward that interpretation when describing scenes.
  const promptText = correction && correction.trim()
    ? `${SCENES_PROMPT}\n\n## Reviewer correction (authoritative)\n\nA human reviewer flagged the previous analysis as wrong. Use this correction as ground truth when describing scenes — don't restate the misread:\n\n${correction.trim()}`
    : SCENES_PROMPT;

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

    return {
      video_duration_sec: Number(parsed.video_duration_sec) || 0,
      scenes: parsed.scenes,
      model: usedModel,
      tokenUsage,
    };
  } finally {
    cleanupTmp(tmpPath);
  }
}

export { getDefaultModel };
