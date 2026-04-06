#!/usr/bin/env node
/**
 * Long Video Worker — Script Generation
 * Usage: node generate_script.mjs <work_dir>
 * Input: work_dir/subtitles.txt, work_dir/project.json
 * Output: work_dir/master_script.txt
 */

import { readFileSync, writeFileSync, existsSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';
import { callClaude } from './lib/claude.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));
const workDir = process.argv[2];
if (!workDir) { console.error('Usage: node generate_script.mjs <work_dir>'); process.exit(1); }

// Read inputs
const project = JSON.parse(readFileSync(join(workDir, 'project.json'), 'utf8'));
const trackId = project.track_id;

// Resolve track files
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

const dna = readTrackFile('dna.md');
const scriptPrompt = readTrackFile('scriptwriting_prompt.md');

// Source material
const subtitlesPath = join(workDir, 'subtitles.txt');
const sourceMaterial = existsSync(subtitlesPath)
  ? readFileSync(subtitlesPath, 'utf8')
  : project.topic_text || '(No source material provided)';

// Extra DNA and comment insights from project
const extraDna = project.extra_dna_json || '';
const commentInsights = project.comments_insights_json || '';

// Assemble Claude prompt
const prompt = `You are a professional scriptwriter for English YouTube long-form videos.

=== TRACK DNA (base style to emulate) ===
${dna}

${extraDna ? `=== PER-VIDEO DNA (additional benchmark traits) ===\n${extraDna}\n` : ''}
${commentInsights ? `=== AUDIENCE INSIGHTS (pain points from comments) ===\n${commentInsights}\n` : ''}
=== SCRIPTWRITING INSTRUCTIONS ===
${scriptPrompt}

=== SOURCE MATERIAL ===
${sourceMaterial.slice(0, 30000)}

=== YOUR TASK ===
Write a complete 8-12 minute narration script (1500-2000 words) based on the source material above.
Follow the DNA style, address audience pain points, and follow the scriptwriting instructions exactly.
Output ONLY the script text, nothing else.`;

console.log(`[generate_script] Calling Claude (prompt: ${prompt.length} chars)...`);
const script = await callClaude(prompt);

writeFileSync(join(workDir, 'master_script.txt'), script, 'utf8');
console.log(`[generate_script] Script generated: ${script.split(/\s+/).length} words`);
