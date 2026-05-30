#!/usr/bin/env node
// Usage: node generate_script.mjs <work_dir>

import { readFileSync, writeFileSync, existsSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';
import { buildScript } from './lib/script-builder.mjs';
import { ClaudeClient } from './lib/claude-client.mjs';
import { buildKindnessCommentaryUserPayload } from './lib/kindness-narration-payload.mjs';
import { extractReversalAnchors, computeVideoDuration } from './lib/kindness-reversal-anchors.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));
const workDir = process.argv[2];
if (!workDir) { console.error('Usage: node generate_script.mjs <work_dir>'); process.exit(2); }

const scenesPath = join(workDir, 'scenes.json');
const taskPath = join(workDir, 'task.json');
if (!existsSync(taskPath)) { console.error(`Missing ${taskPath}`); process.exit(2); }
// scenes.json is only required for the commentary-remix path
const task = JSON.parse(readFileSync(taskPath, 'utf8'));

const apiKey = process.env.ANTHROPIC_API_KEY;
if (!apiKey) { console.error('ANTHROPIC_API_KEY not set'); process.exit(2); }
const model = process.env.CLAUDE_SCRIPT_MODEL || 'claude-sonnet-4-6';
const endpoint = process.env.CLAUDE_ENDPOINT || 'https://api.kie.ai/claude/v1/messages';
const authMode = process.env.CLAUDE_AUTH_MODE || 'bearer';
const anthropicVersion = process.env.ANTHROPIC_VERSION || '2023-06-01';

const client = new ClaudeClient({ apiKey, model, endpoint, authMode, anthropicVersion });

const isKindnessCommentary = task.track === 'kindness-reversal-commentary';

if (isKindnessCommentary) {
  // ── kindness-reversal-commentary path ─────────────────────────────────────
  const trackDir = process.env.SKILLS_DIR
    ? join(process.env.SKILLS_DIR, `tracks/${task.track}`)
    : join(__dirname, `../../../skills/tracks/${task.track}`);

  const promptPath = join(trackDir, 'narration_prompt.md');
  if (!existsSync(promptPath)) {
    console.error(`[script] Missing narration_prompt.md at ${promptPath}`);
    process.exit(2);
  }
  const systemPrompt = readFileSync(promptPath, 'utf8');

  const reversalAnchors = extractReversalAnchors(task.jimeng_prompts);
  const videoDurationSec = computeVideoDuration(task.jimeng_prompts);

  const doubaoPath = join(workDir, 'doubao_analysis.json');
  const doubaoAnalysis = existsSync(doubaoPath)
    ? JSON.parse(readFileSync(doubaoPath, 'utf8'))
    : null;

  const title = (task.synopsis || '').split('\n')[0].slice(0, 100) || 'Untitled';

  const userPayload = buildKindnessCommentaryUserPayload({
    duration_sec: videoDurationSec,
    title,
    story_document: task.story_document || '',
    reversal_anchors: reversalAnchors,
    doubao_analysis: doubaoAnalysis,
  });

  console.log(`[script] kindness-commentary track=${task.track} duration=${videoDurationSec}s anchors=${reversalAnchors.length}`);

  let responseText;
  try {
    // ClaudeClient method is generateScript({systemPrompt, userPayload}), not send().
    // Returns the assistant text content directly.
    responseText = await client.generateScript({ systemPrompt, userPayload });
  } catch (e) {
    console.error(`[script] Claude call failed: ${e.message}`);
    process.exit(1);
  }

  // Strip markdown fences if Claude wrapped the JSON in ```json...```
  let cleaned = String(responseText || '').trim();
  cleaned = cleaned.replace(/^```(?:json)?\s*/i, '').replace(/\s*```\s*$/, '').trim();

  let scriptJson;
  try {
    scriptJson = JSON.parse(cleaned);
  } catch (e) {
    console.error('[script] JSON parse failed:', e.message, 'response:', cleaned.slice(0, 500));
    process.exit(3);
  }

  writeFileSync(join(workDir, 'script.json'), JSON.stringify(scriptJson, null, 2));
  console.log(`[script] wrote ${Array.isArray(scriptJson) ? scriptJson.length : '?'} segments to script.json`);
  process.exit(0);

} else {
  // ── existing commentary-remix path (preserve verbatim) ────────────────────
  if (!existsSync(scenesPath)) { console.error(`Missing ${scenesPath}`); process.exit(2); }
  const scenes = JSON.parse(readFileSync(scenesPath, 'utf8'));

  const trackDir = process.env.SKILLS_DIR
    ? join(process.env.SKILLS_DIR, 'tracks/commentary')
    : join(__dirname, '../../../skills/tracks/commentary');
  // pov 配置 — task 对象由 worker_commentary.sh 从 VPS 拉下来
  const povMode = task?.video_metadata?.commentary_params?.pov_mode || 'third_person';
  const protagonist = task?.pov_details?.protagonist || null;
  const selectedVoiceId = task?.pov_details?.selected_voice_id || null;

  // 根据 pov_mode 选 prompt 文件
  const promptFile = povMode === 'first_person' ? 'narration_prompt_1p.md' : 'narration_prompt.md';
  const promptPath = join(trackDir, promptFile);
  const templatesPath = join(trackDir, 'cta_templates.json');
  const templates = JSON.parse(readFileSync(templatesPath, 'utf8'));

  // Reviewer correction (from commentary_params.correction) is injected into
  // the user payload so Claude can treat it as authoritative ground truth when
  // the previous Phase A misread the video.
  const correction = process.env.COMMENTARY_CORRECTION || null;
  if (correction) {
    console.log(`[script] reviewer correction provided (${correction.length} chars)`);
  }
  try {
    console.log(`[script] pov_mode=${povMode} protagonist=${protagonist?.name || 'none'} voice=${selectedVoiceId || 'default'}`);
    const script = await buildScript({
      taskId: task.task_id || task.id,
      scenes, templates, promptPath,
      claudeClient: client,
      // Per-task CTA override (COMMENTARY_CTA_TEMPLATE_ID) — if empty, fall back
      // to rotator via pickCtaTemplate.
      forceCtaId: process.env.COMMENTARY_CTA_TEMPLATE_ID || null,
      correction,
      povMode,
      protagonist,
      selectedVoiceId,
    });
    writeFileSync(join(workDir, 'script.json'), JSON.stringify(script, null, 2));
    console.log(`[script] OK template=${script.cta.template_id} words=${JSON.stringify(script).length}`);
    process.exit(0);
  } catch (e) {
    console.error(`[script] FAIL: ${e.message}`);
    process.exit(1);
  }
}
