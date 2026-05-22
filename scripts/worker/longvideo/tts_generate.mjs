#!/usr/bin/env node
/**
 * Long Video Worker — TTS Generation (Doubao seed-tts-2.0-expressive)
 *
 * Usage: node tts_generate.mjs <work_dir>
 * Input:  work_dir/segments.json, work_dir/project.json
 * Output: work_dir/audio/segment_NNN.mp3 + work_dir/audio_manifest.json
 *
 * Provider: 豆包 WS 双向流式 (跟 commentary tts_narration 共用 lib/doubao-tts.mjs).
 * Per-segment: 每段独立 WS 连接, 跟现状 ElevenLabs-per-segment HTTP 行为一致.
 *
 * Env:
 *   VOLC_TTS_API_KEY            (required)
 *   LONGVIDEO_TTS_VOICE_ID      (override per-task / track.yaml)
 *   LONGVIDEO_TTS_SUB_MODEL     'standard' | 'expressive', 默认 'expressive'
 *
 * voice_id 优先级: env > track.yaml voice.voice_id > 默认 Dacey.
 */

import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';
import { execFileSync } from 'child_process';
import { runDoubaoTts, DoubaoTtsError } from '../lib/doubao-tts.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));
const workDir = process.argv[2];
if (!workDir) { console.error('Usage: node tts_generate.mjs <work_dir>'); process.exit(1); }

if (!process.env.VOLC_TTS_API_KEY) {
  console.error('VOLC_TTS_API_KEY not set');
  process.exit(1);
}

const segments = JSON.parse(readFileSync(join(workDir, 'segments.json'), 'utf8'));
const project = JSON.parse(readFileSync(join(workDir, 'project.json'), 'utf8'));

const trackId = project.track_id;
const skillsDir = process.env.LV_SKILLS_DIR || join(__dirname, '..', '..', '..', 'skills', 'tracks-longvideo');
const trackYamlPath = join(skillsDir, trackId, 'track.yaml');
const trackYaml = existsSync(trackYamlPath) ? readFileSync(trackYamlPath, 'utf8') : '';

// voice_id 优先级: env > track.yaml > 默认 Dacey
const voiceId = process.env.LONGVIDEO_TTS_VOICE_ID
  || trackYaml.match(/voice_id:\s*(\S+)/)?.[1]
  || 'en_female_dacey_uranus_bigtts';

const subModel = process.env.LONGVIDEO_TTS_SUB_MODEL
  || trackYaml.match(/sub_model:\s*(\S+)/)?.[1]
  || 'expressive';

const audioDir = join(workDir, 'audio');
mkdirSync(audioDir, { recursive: true });

const manifest = [];
console.log(`[TTS] Generating audio for ${segments.length} segments (voice=${voiceId}, sub_model=${subModel})`);

function probeDuration(filePath) {
  try {
    const out = execFileSync('ffprobe', [
      '-v', 'error',
      '-show_entries', 'format=duration',
      '-of', 'default=nw=1:nk=1',
      filePath,
    ], { encoding: 'utf8', timeout: 10_000 }).trim();
    const n = Number(out);
    return Number.isFinite(n) && n > 0 ? Math.round(n * 100) / 100 : null;
  } catch (e) {
    console.warn(`[TTS] ffprobe failed for ${filePath}: ${e.message}`);
    return null;
  }
}

async function generateSegment(seg, index, outputPath) {
  const tts = await runDoubaoTts({ text: seg.text, voiceId, subModel });
  writeFileSync(outputPath, tts.audioBuffer);
  console.log(`[TTS] segment ${index}: ${seg.text.slice(0, 40)}... → ${outputPath} (${tts.durationS}s)`);
  return tts;
}

for (let i = 0; i < segments.length; i++) {
  const seg = segments[i];
  const outputPath = join(audioDir, `segment_${String(i).padStart(3, '0')}.mp3`);

  // rate limit: 200ms 间隔. 跟豆包 semaphore (worker max=2) 配合不打满.
  if (i > 0) await new Promise(r => setTimeout(r, 200));

  try {
    const tts = await generateSegment(seg, i, outputPath);
    const durationS = tts.durationS ?? probeDuration(outputPath);
    manifest.push({
      index: i,
      path: outputPath,
      text: seg.text,
      duration_s: durationS,
      subtitle_words: tts.subtitleWords,
      sub_model: `seed-tts-2.0-${tts.subModel}`,
      segment_type: seg.segment_type,
      logid: tts.logId,
    });
  } catch (e) {
    console.error(`[TTS] segment ${i} FAIL: ${e.message}${e.logid ? ` logid=${e.logid}` : ''}`);
    manifest.push({
      index: i,
      path: null,
      error: e.message,
      segment_type: seg.segment_type,
      error_kind: e instanceof DoubaoTtsError ? e.kind : 'unknown',
      retryable: e instanceof DoubaoTtsError ? e.retryable : true,
    });
  }
}

writeFileSync(join(workDir, 'audio_manifest.json'), JSON.stringify(manifest, null, 2), 'utf8');
const success = manifest.filter(m => m.path).length;
console.log(`[TTS] Done: ${success}/${segments.length} segments generated`);

if (success === 0) {
  console.error('[TTS] No segments generated successfully');
  process.exit(1);
}
