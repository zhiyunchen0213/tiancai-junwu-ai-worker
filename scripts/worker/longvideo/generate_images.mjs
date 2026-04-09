#!/usr/bin/env node
/**
 * Long Video Worker — Scene Image Generation (Apimart)
 * Usage: node generate_images.mjs <work_dir>
 * Input: work_dir/segments.json
 * Output: work_dir/images/ directory with per-segment images
 *         work_dir/image_manifest.json
 *
 * Env: APIMART_API_KEY
 */

import { readFileSync, writeFileSync, mkdirSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';
import { pipeline } from 'stream/promises';
import { createWriteStream } from 'fs';
import { Readable } from 'stream';

const __dirname = dirname(fileURLToPath(import.meta.url));
const workDir = process.argv[2];
if (!workDir) { console.error('Usage: node generate_images.mjs <work_dir>'); process.exit(1); }

const API_KEY = process.env.APIMART_API_KEY || process.env.YUNWU_API_KEY;
if (!API_KEY) { console.error('APIMART_API_KEY not set'); process.exit(1); }

const segments = JSON.parse(readFileSync(join(workDir, 'segments.json'), 'utf8'));
const imageDir = join(workDir, 'images');
mkdirSync(imageDir, { recursive: true });

const BASE_URL = 'https://api.apimart.ai';
const MODEL = 'gemini-3.1-flash-image-preview';
const POLL_INTERVAL = 3000;
const MAX_POLL_TIME = 240000; // 4 min per image

async function submitGeneration(prompt) {
  const resp = await fetch(`${BASE_URL}/v1/images/generations`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${API_KEY}` },
    body: JSON.stringify({ model: MODEL, prompt, n: 1, resolution: '1K' }),
    signal: AbortSignal.timeout(60000),
  });
  if (!resp.ok) throw new Error(`Apimart submit ${resp.status}: ${(await resp.text()).slice(0, 200)}`);
  const result = await resp.json();
  const taskId = result?.data?.[0]?.task_id;
  if (!taskId) throw new Error(`No task_id: ${JSON.stringify(result).slice(0, 200)}`);
  return taskId;
}

async function pollResult(taskId) {
  const start = Date.now();
  while (Date.now() - start < MAX_POLL_TIME) {
    const resp = await fetch(`${BASE_URL}/v1/tasks/${taskId}`, {
      headers: { 'Authorization': `Bearer ${API_KEY}` },
      signal: AbortSignal.timeout(30000),
    });
    if (!resp.ok) throw new Error(`Poll ${resp.status}`);
    const data = await resp.json();
    if (data.status === 'completed' && data.data?.images?.[0]?.url) {
      return data.data.images[0].url;
    }
    if (data.status === 'failed') throw new Error(`Generation failed: ${data.error || 'unknown'}`);
    await new Promise(r => setTimeout(r, POLL_INTERVAL));
  }
  throw new Error('Poll timeout');
}

async function downloadImage(url, outputPath) {
  const resp = await fetch(url, { signal: AbortSignal.timeout(60000) });
  if (!resp.ok) throw new Error(`Download ${resp.status}`);
  await pipeline(Readable.fromWeb(resp.body), createWriteStream(outputPath));
}

// Only generate for static_visual segments (skip digital_human)
const visualSegments = segments.filter(s => s.segment_type === 'static_visual');
console.log(`[Images] Generating ${visualSegments.length} scene images...`);

const manifest = [];

for (const seg of visualSegments) {
  const outputPath = join(imageDir, `scene_${String(seg.index).padStart(3, '0')}.jpg`);
  try {
    const taskId = await submitGeneration(seg.visual_prompt);
    console.log(`[Images] Segment ${seg.index} submitted (task: ${taskId})`);
    const imageUrl = await pollResult(taskId);
    await downloadImage(imageUrl, outputPath);
    manifest.push({ index: seg.index, path: outputPath, status: 'ok' });
    console.log(`[Images] Segment ${seg.index} ✓`);
  } catch (err) {
    console.error(`[Images] Segment ${seg.index} failed: ${err.message}`);
    manifest.push({ index: seg.index, path: null, error: err.message, status: 'failed' });
  }
  // Brief pause between submissions
  await new Promise(r => setTimeout(r, 1000));
}

writeFileSync(join(workDir, 'image_manifest.json'), JSON.stringify(manifest, null, 2), 'utf8');
const success = manifest.filter(m => m.status === 'ok').length;
console.log(`[Images] Done: ${success}/${visualSegments.length} images generated`);

if (success === 0) {
  console.error('[Images] No images generated');
  process.exit(1);
}
