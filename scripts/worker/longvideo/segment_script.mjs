#!/usr/bin/env node
/**
 * Long Video Worker — Script Segmentation
 * Usage: node segment_script.mjs <work_dir>
 * Input: work_dir/master_script.txt, work_dir/project.json
 * Output: work_dir/segments.json
 */

import { readFileSync, writeFileSync, existsSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';
import { callClaudeJSON } from './lib/claude.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));
const workDir = process.argv[2];
if (!workDir) { console.error('Usage: node segment_script.mjs <work_dir>'); process.exit(1); }

const project = JSON.parse(readFileSync(join(workDir, 'project.json'), 'utf8'));
const trackId = project.track_id;
const masterScript = readFileSync(join(workDir, 'master_script.txt'), 'utf8');

const skillsDir = process.env.LV_SKILLS_DIR || join(__dirname, '..', '..', '..', 'skills', 'tracks-longvideo');
const trackDir = join(skillsDir, trackId);
const baseDir = join(skillsDir, '_base');

function readTrackFile(name) {
  const trackPath = join(trackDir, name);
  if (existsSync(trackPath)) return readFileSync(trackPath, 'utf8');
  const basePath = join(baseDir, name.replace('.md', '_base.md'));
  if (existsSync(basePath)) return readFileSync(basePath, 'utf8');
  return '';
}

const segPrompt = readTrackFile('segmentation_prompt.md');

const prompt = `You are a video director breaking a narration script into visual segments.

=== SEGMENTATION INSTRUCTIONS ===
${segPrompt}

=== NARRATION SCRIPT ===
${masterScript}

=== YOUR TASK ===
Break this script into 20-35 visual segments. Output a JSON array where each element has:
- "index": number (starting from 0)
- "text": the narration text for this segment
- "visual_prompt": detailed image generation prompt
- "duration_hint": estimated seconds (10-30)
- "segment_type": "digital_human" for the opening, "static_visual" for the rest

Output ONLY valid JSON (an array), no markdown fences, no explanation.`;

console.log(`[segment_script] Calling Claude (script: ${masterScript.split(/\s+/).length} words)...`);
const segments = await callClaudeJSON(prompt);

if (!Array.isArray(segments)) {
  console.error('[segment_script] Claude did not return an array');
  process.exit(1);
}

writeFileSync(join(workDir, 'segments.json'), JSON.stringify(segments, null, 2), 'utf8');
console.log(`[segment_script] ${segments.length} segments generated`);
