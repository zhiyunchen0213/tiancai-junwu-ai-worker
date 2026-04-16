#!/usr/bin/env node
// Usage: node generate_script.mjs <work_dir>

import { readFileSync, writeFileSync, existsSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';
import { buildScript } from './lib/script-builder.mjs';
import { ClaudeClient } from './lib/claude-client.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));
const workDir = process.argv[2];
if (!workDir) { console.error('Usage: node generate_script.mjs <work_dir>'); process.exit(2); }

const scenesPath = join(workDir, 'scenes.json');
const taskPath = join(workDir, 'task.json');
for (const p of [scenesPath, taskPath]) {
  if (!existsSync(p)) { console.error(`Missing ${p}`); process.exit(2); }
}
const scenes = JSON.parse(readFileSync(scenesPath, 'utf8'));
const task = JSON.parse(readFileSync(taskPath, 'utf8'));

const apiKey = process.env.ANTHROPIC_API_KEY;
if (!apiKey) { console.error('ANTHROPIC_API_KEY not set'); process.exit(2); }
const model = process.env.CLAUDE_SCRIPT_MODEL || 'claude-sonnet-4-6';
const endpoint = process.env.CLAUDE_ENDPOINT || 'https://api.kie.ai/claude/v1/messages';
const authMode = process.env.CLAUDE_AUTH_MODE || 'bearer';
const anthropicVersion = process.env.ANTHROPIC_VERSION || '2023-06-01';

const trackDir = process.env.SKILLS_DIR
  ? join(process.env.SKILLS_DIR, 'tracks/commentary')
  : join(__dirname, '../../../skills/tracks/commentary');
const promptPath = join(trackDir, 'narration_prompt.md');
const templatesPath = join(trackDir, 'cta_templates.json');
const templates = JSON.parse(readFileSync(templatesPath, 'utf8'));

const client = new ClaudeClient({ apiKey, model, endpoint, authMode, anthropicVersion });
// Reviewer correction (from commentary_params.correction) is injected into
// the user payload so Claude can treat it as authoritative ground truth when
// the previous Phase A misread the video.
const correction = process.env.COMMENTARY_CORRECTION || null;
if (correction) {
  console.log(`[script] reviewer correction provided (${correction.length} chars)`);
}
try {
  const script = await buildScript({
    taskId: task.task_id || task.id,
    scenes, templates, promptPath,
    claudeClient: client,
    // Per-task CTA override (COMMENTARY_CTA_TEMPLATE_ID) — if empty, fall back
    // to rotator via pickCtaTemplate.
    forceCtaId: process.env.COMMENTARY_CTA_TEMPLATE_ID || null,
    correction,
  });
  writeFileSync(join(workDir, 'script.json'), JSON.stringify(script, null, 2));
  console.log(`[script] OK template=${script.cta.template_id} words=${JSON.stringify(script).length}`);
  process.exit(0);
} catch (e) {
  console.error(`[script] FAIL: ${e.message}`);
  process.exit(1);
}
