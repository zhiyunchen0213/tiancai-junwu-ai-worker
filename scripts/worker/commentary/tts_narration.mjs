#!/usr/bin/env node
// Usage: node tts_narration.mjs <work_dir>
// Input:  work_dir/script.json + work_dir/task.json + skills/tracks/commentary/track.yaml
// Output: work_dir/narration.mp3, work_dir/narration_manifest.json
//
// Provider: Kie async job pipeline (elevenlabs/text-to-dialogue-v3)
//   1. POST  ${KIE_API_URL}/api/v1/jobs/createTask   → { code, data: { taskId } }
//   2. Poll  ${KIE_API_URL}/api/v1/jobs/recordInfo?taskId=...
//      - state === waiting | queuing | generating → keep polling
//      - state === success                        → parse resultJson → resultUrls[0]
//      - state === fail                           → throw failCode/failMsg
//   3. Download audio URL → work_dir/narration.mp3
//
// Env:
//   KIE_API_KEY (primary) | ELEVENLABS_API_KEY (fallback)
//   KIE_API_URL (default https://api.kie.ai)
//   COMMENTARY_TTS_VOICE_ID (primary per-task override) | COMMENTARY_VOICE (legacy name)
//   COMMENTARY_STABILITY (0-1)
//   COMMENTARY_LANGUAGE_CODE (optional language hint)
//   COMMENTARY_TTS_TIMEOUT_SEC (default 600)

import { readFileSync, writeFileSync, createWriteStream, existsSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';
import { pipeline } from 'stream/promises';
import { Readable } from 'stream';

const __dirname = dirname(fileURLToPath(import.meta.url));
const workDir = process.argv[2];
if (!workDir) { console.error('Usage: node tts_narration.mjs <work_dir>'); process.exit(2); }

const apiKey = process.env.KIE_API_KEY || process.env.ELEVENLABS_API_KEY;
if (!apiKey) { console.error('KIE_API_KEY or ELEVENLABS_API_KEY not set'); process.exit(2); }

const kieBase = (process.env.KIE_API_URL || 'https://api.kie.ai').replace(/\/+$/, '');
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

// voice_id 优先级：script.protagonist.voice_id (第一视角) > env > commentary_params.voice > track default > Brian
const voiceId = script?.protagonist?.voice_id
             || process.env.COMMENTARY_TTS_VOICE_ID
             || process.env.COMMENTARY_VOICE
             || taskCp.voice
             || (track.tts && track.tts.voice_id)
             || 'Brian';
console.log(`[tts] voice_id=${voiceId}`);

// Stability: COMMENTARY_STABILITY (0-1) > track.yaml tts.stability > 0.5
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
const stability = resolveStability();

// Optional language hint for Kie TTS
const languageCode = (process.env.COMMENTARY_LANGUAGE_CODE || '').trim();

const fullText = [
  script.hook,
  ...(Array.isArray(script.events) ? script.events : []),
  script.tease,
  script.cta && script.cta.text,
  script.reveal,
].filter(Boolean).join(' ');

const MAX_CHARS = 5000;
if (fullText.length > MAX_CHARS) {
  console.error(`[tts] script too long: ${fullText.length} chars (Kie limit ${MAX_CHARS})`);
  process.exit(1);
}

async function createKieTask() {
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

async function pollRecordInfo(taskId) {
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

async function downloadAudio(audioUrl, outPath) {
  const resp = await fetch(audioUrl);
  if (!resp.ok) {
    const detail = await resp.text().catch(() => '');
    throw new Error(`download audio HTTP ${resp.status}: ${detail.slice(0, 200)}`);
  }
  await pipeline(Readable.fromWeb(resp.body), createWriteStream(outPath));
}

try {
  console.log(`[tts] creating Kie task (voice=${voiceId}, stability=${stability}${languageCode ? `, lang=${languageCode}` : ''}, chars=${fullText.length})`);
  const taskId = await createKieTask();
  console.log(`[tts] taskId=${taskId}; polling`);
  const { audioUrl, parsed } = await pollRecordInfo(taskId);
  const outPath = join(workDir, 'narration.mp3');
  await downloadAudio(audioUrl, outPath);

  writeFileSync(join(workDir, 'narration_manifest.json'), JSON.stringify({
    provider: 'kie',
    taskId,
    voice_id: voiceId,
    stability,
    language_code: languageCode || null,
    text_char_count: fullText.length,
    audio_url: audioUrl,
    mp3_path: outPath,
    result_raw: parsed,
  }, null, 2));

  console.log(`[tts] narration.mp3 written (${fullText.length} chars, taskId=${taskId})`);
  process.exit(0);
} catch (e) {
  console.error(`[tts] FAIL: ${e.message}`);
  process.exit(1);
}
