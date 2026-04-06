#!/usr/bin/env node
/**
 * Long Video Worker — TTS Generation (ElevenLabs)
 * Usage: node tts_generate.mjs <work_dir>
 * Input: work_dir/segments.json, work_dir/project.json
 * Output: work_dir/audio/ directory with per-segment .mp3 files
 *         work_dir/audio_manifest.json (durations + paths)
 *
 * Env: ELEVENLABS_API_KEY, ELEVENLABS_VOICE_ID (override track default)
 */

import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';
import { pipeline } from 'stream/promises';
import { createWriteStream } from 'fs';
import { Readable } from 'stream';

const __dirname = dirname(fileURLToPath(import.meta.url));
const workDir = process.argv[2];
if (!workDir) { console.error('Usage: node tts_generate.mjs <work_dir>'); process.exit(1); }

const API_KEY = process.env.ELEVENLABS_API_KEY;
if (!API_KEY) { console.error('ELEVENLABS_API_KEY not set'); process.exit(1); }

const segments = JSON.parse(readFileSync(join(workDir, 'segments.json'), 'utf8'));
const project = JSON.parse(readFileSync(join(workDir, 'project.json'), 'utf8'));

// Resolve voice_id from track config or env
const trackId = project.track_id;
const skillsDir = process.env.LV_SKILLS_DIR || join(__dirname, '..', '..', '..', 'skills', 'tracks-longvideo');
const trackYaml = existsSync(join(skillsDir, trackId, 'track.yaml'))
  ? readFileSync(join(skillsDir, trackId, 'track.yaml'), 'utf8') : '';
const voiceId = process.env.ELEVENLABS_VOICE_ID
  || trackYaml.match(/voice_id:\s*(\S+)/)?.[1]
  || 'pNInz6obpgDQGcFmaJgB'; // default: Adam

const audioDir = join(workDir, 'audio');
mkdirSync(audioDir, { recursive: true });

const BASE_URL = 'https://api.elevenlabs.io/v1';
const manifest = [];

async function generateTTS(text, outputPath, index) {
  const resp = await fetch(`${BASE_URL}/text-to-speech/${voiceId}`, {
    method: 'POST',
    headers: {
      'xi-api-key': API_KEY,
      'Content-Type': 'application/json',
      'Accept': 'audio/mpeg',
    },
    body: JSON.stringify({
      text,
      model_id: 'eleven_multilingual_v2',
      voice_settings: { stability: 0.5, similarity_boost: 0.75 },
    }),
  });

  if (!resp.ok) {
    const err = await resp.text().catch(() => '');
    throw new Error(`ElevenLabs ${resp.status}: ${err.slice(0, 200)}`);
  }

  await pipeline(Readable.fromWeb(resp.body), createWriteStream(outputPath));
  console.log(`[TTS] Segment ${index}: ${text.slice(0, 50)}... → ${outputPath}`);
}

// Estimate audio duration from text (rough: 150 words per minute)
function estimateDuration(text) {
  const words = text.split(/\s+/).length;
  return Math.max(3, Math.round(words / 150 * 60));
}

console.log(`[TTS] Generating audio for ${segments.length} segments (voice: ${voiceId})`);

for (let i = 0; i < segments.length; i++) {
  const seg = segments[i];
  const outputPath = join(audioDir, `segment_${String(i).padStart(3, '0')}.mp3`);

  // Rate limit: 2 requests per second (ElevenLabs free tier limit)
  if (i > 0) await new Promise(r => setTimeout(r, 600));

  try {
    await generateTTS(seg.text, outputPath, i);
    manifest.push({
      index: i,
      path: outputPath,
      text: seg.text,
      duration_estimate: estimateDuration(seg.text),
      segment_type: seg.segment_type,
    });
  } catch (err) {
    console.error(`[TTS] Segment ${i} failed: ${err.message}`);
    // Non-fatal: skip this segment, mark in manifest
    manifest.push({
      index: i,
      path: null,
      error: err.message,
      segment_type: seg.segment_type,
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
