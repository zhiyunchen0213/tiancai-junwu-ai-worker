import { readFileSync } from 'fs';
import { pickCtaTemplate } from './cta-rotator.mjs';

function countWords(s) { return (String(s).trim().match(/\S+/g) || []).length; }

export function computeCtaPositionRatio(script) {
  const before = countWords(script.hook)
    + script.events.reduce((n, e) => n + countWords(e), 0)
    + countWords(script.tease);
  const total = before + countWords(script.cta?.text || '') + countWords(script.reveal);
  return total === 0 ? 0 : before / total;
}

function parseClaudeResponse(raw) {
  let text = String(raw).trim();
  const fence = text.match(/```(?:json)?\s*([\s\S]*?)\s*```/);
  if (fence) text = fence[1];
  const match = text.match(/\{[\s\S]*\}/);
  if (!match) throw new Error('script-builder: Claude returned no JSON');
  try { return JSON.parse(match[0]); }
  catch (e) { throw new Error(`script-builder: invalid JSON: ${e.message}`); }
}

function validateShape(script, templates) {
  const errors = [];
  if (!script.hook || typeof script.hook !== 'string') errors.push('hook missing');
  if (!Array.isArray(script.events) || script.events.length < 3) errors.push('events must be >=3 strings');
  if (!script.tease) errors.push('tease missing');
  if (!script.cta || !script.cta.template_id || !script.cta.text) errors.push('cta missing');
  else {
    const templateIds = new Set(templates.map(t => t.id));
    if (!templateIds.has(script.cta.template_id)) {
      errors.push(`cta.template_id "${script.cta.template_id}" not in templates`);
    }
  }
  if (!script.reveal) errors.push('reveal missing');
  if (errors.length) throw new Error('script-builder shape error: ' + errors.join('; '));
}

export async function buildScript({ taskId, scenes, templates, promptPath, claudeClient, forceCtaId = null }) {
  const systemPrompt = readFileSync(promptPath, 'utf8');
  // forceCtaId (per-task override from commentary_params.cta_template_id) skips
  // the hash-based rotator and locks onto the requested template. If the id is
  // unknown, fall back to rotator rather than the first template so batches
  // keep their natural rotation.
  let chosenCta;
  if (forceCtaId) {
    const match = templates.find((t) => t.id === forceCtaId);
    if (match) {
      chosenCta = match;
    } else {
      console.warn(`[script-builder] forceCtaId="${forceCtaId}" not in templates; falling back to rotator`);
      chosenCta = pickCtaTemplate(taskId, templates);
    }
  } else {
    chosenCta = pickCtaTemplate(taskId, templates);
  }

  const userPayload = {
    video_duration_sec: scenes.video_duration_sec,
    scenes: scenes.scenes,
    cta_templates_available: [{
      id: chosenCta.id,
      text: chosenCta.text,
    }],
    instructions: `You MUST use the CTA template with template_id="${chosenCta.id}" exactly as provided in cta_templates_available. Copy its text verbatim into cta.text.`,
  };

  let lastErr;
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const raw = await claudeClient.generateScript({ systemPrompt, userPayload });
      const parsed = parseClaudeResponse(raw);
      validateShape(parsed, templates);
      const ratio = computeCtaPositionRatio(parsed);
      // Note: ...parsed already passes through optional fields like `translations`
      return {
        ...parsed,
        metadata: {
          cta_position_ratio: ratio,
          cta_template_id: parsed.cta.template_id,
          warnings: [],
          scene_count: scenes.scenes.length,
          video_duration_sec: scenes.video_duration_sec,
        },
      };
    } catch (e) {
      lastErr = e;
      if (attempt === 0) continue;
      throw e;
    }
  }
  throw lastErr;
}
