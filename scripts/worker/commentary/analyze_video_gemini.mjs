#!/usr/bin/env node
// Usage: node analyze_video_gemini.mjs <work_dir>
// Input:  work_dir/source.json { video_url | local_mp4_path }
// Output: work_dir/scenes.json

import { readFileSync, writeFileSync, existsSync } from 'fs';
import { join } from 'path';
import { analyzeVideoScenes } from '../../../review-server/lib/gemini.js';

const workDir = process.argv[2];
if (!workDir) { console.error('Usage: node analyze_video_gemini.mjs <work_dir>'); process.exit(2); }

const sourcePath = join(workDir, 'source.json');
if (!existsSync(sourcePath)) { console.error(`Missing ${sourcePath}`); process.exit(2); }
const src = JSON.parse(readFileSync(sourcePath, 'utf8'));

// Read task.json to determine pov_mode (copied to workDir by phase_a.sh).
const taskPath = join(workDir, 'task.json');
const task = existsSync(taskPath) ? JSON.parse(readFileSync(taskPath, 'utf8')) : {};
const povMode = task?.video_metadata?.commentary_params?.pov_mode
             || task?.commentary_params?.pov_mode
             || 'third_person';
const identifyCharacters = povMode === 'first_person';

const apiKey = process.env.GEMINI_API_KEY;
if (!apiKey) { console.error('GEMINI_API_KEY not set'); process.exit(2); }
const model = process.env.GEMINI_VIDEO_MODEL || 'gemini-3-flash-preview-nothinking';
const providerName = process.env.GEMINI_PROVIDER || 'apimart';

// Local uploads (uploaded:// or file://) use localPath; real URLs use url.
const isLocal = !src.video_url
  || src.video_url.startsWith('uploaded://')
  || src.video_url.startsWith('file://');
// Reviewer correction (set by export_params.sh from video_metadata.commentary_params.correction)
// is fed to Gemini so it biases toward the reviewer's interpretation when describing scenes.
const correction = process.env.COMMENTARY_CORRECTION || null;
const analyzeArgs = isLocal
  ? { localPath: src.local_mp4_path, providerName, apiKey, model, correction, identifyCharacters }
  : { url: src.video_url, providerName, apiKey, model, correction, identifyCharacters };

let lastErr;
for (let attempt = 0; attempt < 3; attempt++) {
  try {
    const result = await analyzeVideoScenes(analyzeArgs);
    writeFileSync(join(workDir, 'scenes.json'), JSON.stringify(result, null, 2));
    console.log(`[analyze] scenes=${result.scenes.length} duration=${result.video_duration_sec}s`);
    process.exit(0);
  } catch (e) {
    lastErr = e;
    const wait = 2000 * Math.pow(2, attempt);
    console.error(`[analyze] attempt ${attempt + 1} failed: ${e.message}; retry in ${wait}ms`);
    await new Promise(r => setTimeout(r, wait));
  }
}
console.error(`[analyze] FAIL after 3 attempts: ${lastErr?.message}`);
process.exit(1);
