#!/usr/bin/env node
// scripts/worker/commentary/tts_narration.mjs
//
// Usage: node tts_narration.mjs <work_dir>
// Input:  work_dir/script.json + work_dir/task.json + skills/tracks/commentary/track.yaml
// Output: work_dir/narration.mp3, work_dir/narration_manifest.json
//
// Provider: 豆包 WS 双向流式 (seed-tts-2.0-expressive 默认).
//
// Env:
//   VOLC_TTS_API_KEY            (required)
//   COMMENTARY_TTS_VOICE_ID     (override per-task)
//   COMMENTARY_TTS_SUB_MODEL    'standard' | 'expressive', 默认 'expressive'
//   COMMENTARY_LANGUAGE_CODE    explicit_language hint (可选)
//   COMMENTARY_TTS_TIMEOUT_SEC  默认 120 (豆包 ~5-10s, 120s 是 safety net)

import { readFileSync, writeFileSync, existsSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';
import { runDoubaoTts, DoubaoTtsError } from '../lib/doubao-tts.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));

const workDir = process.argv[2];
if (!workDir) { console.error('Usage: node tts_narration.mjs <work_dir>'); process.exit(2); }

if (!process.env.VOLC_TTS_API_KEY) {
  console.error('VOLC_TTS_API_KEY not set');
  process.exit(2);
}

const totalTimeoutMs = (parseInt(process.env.COMMENTARY_TTS_TIMEOUT_SEC || '120', 10) || 120) * 1000;

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

const trackDir = process.env.SKILLS_DIR
  ? join(process.env.SKILLS_DIR, 'tracks/commentary')
  : join(__dirname, '../../../skills/tracks/commentary');

// Minimal YAML parser for tts config (key: value lines only)
function parseYaml(content) {
  const obj = {};
  const lines = content.split('\n');
  let currentKey = null;
  function cleanValue(raw) {
    let v = raw.replace(/\s+#.*$/, '').trim();
    if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) v = v.slice(1, -1);
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
      if (match) { currentKey = match[1]; obj[currentKey] = cleanValue(match[2]); }
    }
  }
  return obj;
}

const track = parseYaml(readFileSync(join(trackDir, 'track.yaml'), 'utf8'));

// voice_id 优先级: script.protagonist.voice_id (第一视角) > env > taskCp.voice > track.yaml > 默认 Dacey
const voiceId = script?.protagonist?.voice_id
  || process.env.COMMENTARY_TTS_VOICE_ID
  || taskCp.voice
  || (track.tts && track.tts.voice_id)
  || 'en_female_dacey_uranus_bigtts';

const subModel = process.env.COMMENTARY_TTS_SUB_MODEL
  || (track.tts && track.tts.sub_model)
  || 'expressive';

const languageCode = (process.env.COMMENTARY_LANGUAGE_CODE || '').trim() || undefined;

console.log(`[tts] voice_id=${voiceId} sub_model=${subModel}${languageCode ? ` lang=${languageCode}` : ''}`);

// kindness-reversal-commentary script.json is an array of {start_sec, end_sec, text}
// segments (Task 10 generate_script.mjs kindness branch). commentary-remix script.json
// is an object with {hook, events[], tease, cta, reveal} fields. Detect by shape and
// concat narration text either way.
const fullText = Array.isArray(script)
  ? script.map(seg => (seg && typeof seg.text === 'string') ? seg.text : '')
      .filter(t => t && t.trim()).join(' ')
  : [
      script.hook,
      ...(Array.isArray(script.events) ? script.events : []),
      script.tease,
      script.cta && script.cta.text,
      script.reveal,
    ].filter(Boolean).join(' ');

// 豆包文档没明说 single session text length 上限, 但 expressive 模型对短句友好,
// 长段 commentary (~5000 字) 实测可单次合成. 这里保留宽松 hard cap 防爆.
const HARD_MAX_CHARS = 10000;
if (fullText.length > HARD_MAX_CHARS) {
  console.error(`[tts] script too long: ${fullText.length} chars (hard cap ${HARD_MAX_CHARS})`);
  process.exit(1);
}

async function runWithRetry() {
  let lastErr;
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      return await Promise.race([
        runDoubaoTts({
          text: fullText,
          voiceId,
          subModel,
          explicitLanguage: languageCode,
        }),
        new Promise((_, reject) => setTimeout(() => reject(new Error(`timeout ${totalTimeoutMs}ms`)), totalTimeoutMs)),
      ]);
    } catch (e) {
      lastErr = e;
      if (e instanceof DoubaoTtsError && !e.retryable) {
        console.error(`[tts] non-retryable: ${e.message}`);
        throw e;
      }
      const wait = 3000 * Math.pow(2, attempt);
      console.error(`[tts] attempt ${attempt + 1} failed: ${e.message}; retry in ${wait}ms`);
      await new Promise(r => setTimeout(r, wait));
    }
  }
  throw lastErr;
}

try {
  console.log(`[tts] running doubao TTS (chars=${fullText.length})`);
  const tts = await runWithRetry();

  const outPath = join(workDir, 'narration.mp3');
  writeFileSync(outPath, tts.audioBuffer);

  writeFileSync(join(workDir, 'narration_manifest.json'), JSON.stringify({
    provider: 'doubao',
    sub_model: `seed-tts-2.0-${subModel}`,
    voice_id: voiceId,
    text_char_count: fullText.length,
    billable_chars: tts.usage?.billableChars ?? null,
    mp3_path: outPath,
    duration_s: tts.durationS,
    subtitle_words: tts.subtitleWords,
    logid: tts.logId,
  }, null, 2));

  console.log(`[tts] narration.mp3 written (${tts.audioBuffer.length} bytes, ${tts.durationS}s, logid=${tts.logId})`);
  process.exit(0);
} catch (e) {
  console.error(`[tts] FAIL: ${e.message}${e.logid ? ` logid=${e.logid}` : ''}`);
  process.exit(1);
}
