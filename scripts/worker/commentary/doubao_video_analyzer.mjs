#!/usr/bin/env node
// scripts/worker/commentary/doubao_video_analyzer.mjs
//
// Commentary Phase A: Doubao video analysis caller.
//
// Calls the VPS internal endpoint POST /api/v1/internal/doubao-video-analysis/:taskId
// and writes the result to doubao_analysis.json in the work dir.
//
// Non-fatal design: if the VPS endpoint returns an error (HTTP 4xx/5xx, network
// failure, or Doubao API failure), this script writes an empty analysis JSON and
// exits 0 so phase_a.sh can continue with story_document only.
// The narration generator (generate_script.mjs) reads doubao_analysis.json and
// gracefully handles empty arrays.
//
// Usage:
//   node doubao_video_analyzer.mjs <work_dir> <task_id>
//
// Required env:
//   REVIEW_SERVER_URL    - e.g. http://127.0.0.1:13000 (SSH tunnel)
//   DISPATCHER_TOKEN     - worker authentication token

import { writeFileSync } from 'node:fs';
import { join } from 'node:path';

const EMPTY_ANALYSIS = {
  shot_cadence: [],
  micro_expressions: [],
  deviations_from_script: [],
};

function writeEmpty(workDir, reason) {
  const out = { ...EMPTY_ANALYSIS, _skip_reason: reason };
  writeFileSync(join(workDir, 'doubao_analysis.json'), JSON.stringify(out, null, 2));
}

const workDir = process.argv[2];
const taskId = process.argv[3];

if (!workDir || !taskId) {
  console.error('[doubao-video-analysis] Usage: doubao_video_analyzer.mjs <work_dir> <task_id>');
  process.exit(2);
}

const baseUrl = process.env.REVIEW_SERVER_URL;
const token = process.env.DISPATCHER_TOKEN;

if (!baseUrl || !token) {
  console.error('[doubao-video-analysis] REVIEW_SERVER_URL + DISPATCHER_TOKEN required');
  process.exit(2);
}

console.log(`[doubao-video-analysis] ${taskId} → POST ${baseUrl}/api/v1/internal/doubao-video-analysis/${taskId}`);

let resp;
try {
  resp = await fetch(`${baseUrl}/api/v1/internal/doubao-video-analysis/${taskId}`, {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    // Signal: abort if VPS takes more than 5 minutes (Doubao VLM analysis can be slow)
    signal: AbortSignal.timeout(300_000),
  });
} catch (err) {
  // Network error or timeout — non-fatal, write empty
  console.error(`[doubao-video-analysis] ${taskId} network error: ${err.message}`);
  writeEmpty(workDir, `network_error:${err.message}`);
  process.exit(0);
}

if (!resp.ok) {
  const body = await resp.text().catch(() => '');
  console.error(`[doubao-video-analysis] ${taskId} HTTP ${resp.status}: ${body.slice(0, 200)}`);
  // Non-fatal: write empty analysis, let narration generator proceed with story_document only
  writeEmpty(workDir, `http_error:${resp.status}`);
  process.exit(0);
}

let data;
try {
  data = await resp.json();
} catch (err) {
  console.error(`[doubao-video-analysis] ${taskId} response parse error: ${err.message}`);
  writeEmpty(workDir, `parse_error:${err.message}`);
  process.exit(0);
}

// Normalise output — ensure three arrays are present
const result = {
  shot_cadence: Array.isArray(data.shot_cadence) ? data.shot_cadence : [],
  micro_expressions: Array.isArray(data.micro_expressions) ? data.micro_expressions : [],
  deviations_from_script: Array.isArray(data.deviations_from_script) ? data.deviations_from_script : [],
};

writeFileSync(join(workDir, 'doubao_analysis.json'), JSON.stringify(result, null, 2));
console.log(`[doubao-video-analysis] ${taskId} wrote doubao_analysis.json: shots=${result.shot_cadence.length} expressions=${result.micro_expressions.length} deviations=${result.deviations_from_script.length}`);
