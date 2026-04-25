#!/usr/bin/env node
// scripts/worker/material-ingest/analyze.mjs
//
// Worker 端视频分析: 直接调 APImart Gemini 代理 (复用 review-server 的 provider 配置).
// 不通过 review-server 转发, worker 跑在 macking 上, 本地有 mp4 文件, 直接 base64 inline 给
// APImart, 省 VPS 带宽 + 不需要 review-server 临时存文件.
//
// 用法:
//   analyze.mjs <mp4-absolute-path>
//
// Stdout: JSON 字符串 (Gemini 分析结构化输出, schema 见下方 VIDEO_PROMPT)
// 非 0 exit code = 失败 (stderr 描述原因)
//
// 必需 env:
//   APIMART_API_KEY      默认 provider 的 key (跟 review-server 共用)
// 可选 env:
//   GEMINI_ANALYZE_MODEL 模型名, 默认 gemini-3-flash-preview-nothinking
//   APIMART_BASE_URL     APImart endpoint, 默认 https://api.apimart.ai/v1beta

import { readFileSync, statSync } from 'node:fs';

// 跟 review-server/lib/gemini.js 的 VIDEO_PROMPT 字面一致.
// 改 prompt 时两边必须同步, 否则 chrome-extension 和 worker 会跑出不一样的分析.
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

const filePath = process.argv[2];
if (!filePath) {
  console.error('Usage: analyze.mjs <mp4-absolute-path>');
  process.exit(1);
}

const apiKey = process.env.APIMART_API_KEY || process.env.DEFAULT_PROVIDER_API_KEY;
if (!apiKey) {
  console.error('APIMART_API_KEY (or DEFAULT_PROVIDER_API_KEY) env var required');
  process.exit(1);
}
const model = process.env.GEMINI_ANALYZE_MODEL || 'gemini-3-flash-preview-nothinking';
const baseUrl = (process.env.APIMART_BASE_URL || 'https://api.apimart.ai/v1beta').replace(/\/+$/, '');

let stat;
try { stat = statSync(filePath); }
catch (e) {
  console.error(`Cannot stat file: ${filePath} (${e.message})`);
  process.exit(2);
}

// APImart inline data 限制 20MB. 抖音/youtube short 一般 < 30MB, 大于此值需要先压缩或换 Files API.
const MAX_BYTES = 20 * 1024 * 1024;
if (stat.size > MAX_BYTES) {
  console.error(`File too large: ${(stat.size / 1024 / 1024).toFixed(1)} MB > 20 MB (APImart inline limit)`);
  process.exit(3);
}
if (stat.size === 0) {
  console.error('File is empty');
  process.exit(4);
}

const buffer = readFileSync(filePath);
const base64 = buffer.toString('base64');

const contents = [{
  role: 'user',
  parts: [
    { inlineData: { mimeType: 'video/mp4', data: base64 } },
    { text: VIDEO_PROMPT },
  ],
}];

const url = `${baseUrl}/models/${model}:generateContent`;

let resp;
try {
  resp = await fetch(url, {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${apiKey}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ contents }),
    signal: AbortSignal.timeout(300_000), // 5min cap, 视频分析可能慢
  });
} catch (e) {
  console.error(`APImart fetch error: ${e.message}`);
  process.exit(5);
}

if (!resp.ok) {
  const errText = await resp.text().catch(() => '<unreadable>');
  console.error(`APImart HTTP ${resp.status}: ${errText.slice(0, 500)}`);
  process.exit(6);
}

let data;
try { data = await resp.json(); }
catch (e) {
  console.error(`Failed to parse APImart response as JSON: ${e.message}`);
  process.exit(7);
}

const text = data?.candidates?.[0]?.content?.parts?.[0]?.text || '';
if (!text) {
  console.error(`No text in APImart response. Raw: ${JSON.stringify(data).slice(0, 500)}`);
  process.exit(8);
}

// Gemini 经常把 JSON 包在 ```json ... ``` 里, 提取大括号块
let parsed;
try {
  const jsonMatch = text.match(/\{[\s\S]*\}/);
  parsed = jsonMatch ? JSON.parse(jsonMatch[0]) : JSON.parse(text);
} catch (e) {
  console.error(`Failed to parse JSON from Gemini response (${e.message}). Raw text: ${text.slice(0, 500)}`);
  process.exit(9);
}

// 注入 _model / _prompt_version meta, 让后端 insertAnalysis 记到 DB 不再走 hardcode 兜底
parsed._model = model;
parsed._prompt_version = 'v1';

// 输出 JSON 给 main.sh, jq --argjson 接得住
process.stdout.write(JSON.stringify(parsed));
