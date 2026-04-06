#!/usr/bin/env node
/**
 * Long Video Worker — Title, Cover & BGM Prompt Generation
 * Usage: node generate_titles_cover.mjs <work_dir>
 * Input: work_dir/master_script.txt, work_dir/project.json
 * Output: work_dir/titles_cover.json
 */

import { readFileSync, writeFileSync, existsSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';
import { callClaudeJSON } from './lib/claude.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));
const workDir = process.argv[2];
if (!workDir) { console.error('Usage: node generate_titles_cover.mjs <work_dir>'); process.exit(1); }

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

const coverPrompt = readTrackFile('cover_title_prompt.md');

const prompt = `You are a YouTube content strategist.

=== INSTRUCTIONS ===
${coverPrompt}

=== SCRIPT SUMMARY ===
${masterScript.slice(0, 5000)}

=== YOUR TASK ===
Generate YouTube metadata. Output ONLY valid JSON with this structure:
{
  "titles": [
    {"title": "Title under 60 chars", "description": "2-3 sentence description"},
    {"title": "...", "description": "..."},
    {"title": "...", "description": "..."}
  ],
  "cover_visual_desc": "Detailed prompt for generating the thumbnail image",
  "suno_prompt": "Music style/mood/tempo description for Suno AI"
}`;

console.log(`[titles_cover] Calling Claude...`);
const result = await callClaudeJSON(prompt);

if (!result.titles || !Array.isArray(result.titles)) {
  console.error('[titles_cover] Invalid response structure');
  process.exit(1);
}

writeFileSync(join(workDir, 'titles_cover.json'), JSON.stringify(result, null, 2), 'utf8');
console.log(`[titles_cover] Generated ${result.titles.length} title candidates`);
