import { readFileSync } from 'fs';
import { pickCtaTemplate } from './cta-rotator.mjs';

// Re-export so consumers can import pickCtaTemplate from script-builder.mjs
export { pickCtaTemplate } from './cta-rotator.mjs';

function countWords(s) { return (String(s).trim().match(/\S+/g) || []).length; }

export function computeCtaPositionRatio(script) {
  const before = countWords(script.hook)
    + script.events.reduce((n, e) => n + countWords(e), 0)
    + countWords(script.tease);
  const total = before + countWords(script.cta?.text || '') + countWords(script.reveal);
  return total === 0 ? 0 : before / total;
}

function parseClaudeResponse(raw) {
  // ClaudeClient returns Anthropic shape { content: [{ type: 'text', text: '...' }] }
  // or plain string (legacy stub). Normalise to string first.
  let text;
  if (raw && typeof raw === 'object' && Array.isArray(raw.content)) {
    const textBlock = raw.content.find(b => b.type === 'text');
    text = textBlock ? String(textBlock.text) : '';
  } else {
    text = String(raw);
  }
  text = text.trim();
  const fence = text.match(/```(?:json)?\s*([\s\S]*?)\s*```/);
  if (fence) text = fence[1];
  const match = text.match(/\{[\s\S]*\}/);
  if (!match) throw new Error('script-builder: Claude returned no JSON');
  try { return JSON.parse(match[0]); }
  catch (e) { throw new Error(`script-builder: invalid JSON: ${e.message}`); }
}

/**
 * Resolve the flat template array for a given povMode from the templates value
 * (which may be a flat legacy array or a grouped { third_person, first_person } object).
 */
function resolveTemplateGroup(templates, povMode) {
  if (Array.isArray(templates)) return templates;
  return templates[povMode] || templates.third_person || [];
}

function validateShape(script, templates, povMode = 'third_person') {
  const errors = [];
  if (!script.hook || typeof script.hook !== 'string') errors.push('hook missing');
  if (!Array.isArray(script.events) || script.events.length < 3) errors.push('events must be >=3 strings');
  if (!script.tease) errors.push('tease missing');
  if (!script.cta || !script.cta.template_id || !script.cta.text) errors.push('cta missing');
  else {
    const group = resolveTemplateGroup(templates, povMode);
    const templateIds = new Set(group.map(t => t.template_id || t.id));
    if (!templateIds.has(script.cta.template_id)) {
      errors.push(`cta.template_id "${script.cta.template_id}" not in templates`);
    }
  }
  if (!script.reveal) errors.push('reveal missing');
  if (errors.length) throw new Error('script-builder shape error: ' + errors.join('; '));
}

/**
 * Build a narration script by calling Claude with scene context.
 *
 * @param {object} opts
 * @param {string}  opts.taskId
 * @param {object}  opts.scenes          - { video_duration_sec, scenes: [...] }
 * @param {object|Array} opts.templates  - grouped { third_person, first_person } or legacy flat array
 * @param {string}  opts.promptPath      - path to narration_prompt.md
 * @param {object}  opts.claudeClient    - has generateScript({ systemPrompt, userPayload })
 * @param {string}  [opts.forceCtaId]    - lock to specific CTA template_id
 * @param {string}  [opts.correction]    - reviewer correction hint
 * @param {string}  [opts.povMode]       - 'third_person' (default) | 'first_person'
 * @param {object}  [opts.protagonist]   - required when povMode='first_person'; { name, ... }
 * @param {string}  [opts.selectedVoiceId] - voice_id to inject into parsed.protagonist.voice_id
 */
export async function buildScript({
  taskId,
  scenes,
  templates,
  promptPath,
  claudeClient,
  forceCtaId = null,
  correction = null,
  povMode = 'third_person',
  protagonist = null,
  selectedVoiceId = null,
}) {
  // Validate first_person prerequisites
  if (povMode === 'first_person' && !protagonist?.name) {
    throw new Error('script-builder: protagonist.name is required when povMode is first_person');
  }

  const systemPrompt = readFileSync(promptPath, 'utf8');

  // forceCtaId (per-task override from commentary_params.cta_template_id) skips
  // the hash-based rotator and locks onto the requested template. If the id is
  // unknown, fall back to rotator rather than the first template so batches
  // keep their natural rotation.
  let chosenCta;
  if (forceCtaId) {
    const group = resolveTemplateGroup(templates, povMode);
    const match = group.find((t) => (t.template_id || t.id) === forceCtaId);
    if (match) {
      chosenCta = match;
    } else {
      console.warn(`[script-builder] forceCtaId="${forceCtaId}" not in templates; falling back to rotator`);
      chosenCta = pickCtaTemplate({ taskId, templates, povMode });
    }
  } else {
    chosenCta = pickCtaTemplate({ taskId, templates, povMode });
  }

  const ctaTemplateId = chosenCta.template_id || chosenCta.id;

  const userPayload = {
    video_duration_sec: scenes.video_duration_sec,
    scenes: scenes.scenes,
    pov_mode: povMode,
    cta_templates_available: [{
      template_id: ctaTemplateId,
      text: chosenCta.text,
    }],
    instructions: `You MUST use the CTA template with template_id="${ctaTemplateId}" exactly as provided in cta_templates_available. Copy its text verbatim into cta.text.`,
    // reviewer_correction (optional): human reviewer's authoritative hint about
    // what the previous attempt got wrong. See narration_prompt.md for how to
    // treat it.
    ...(correction && String(correction).trim() ? { reviewer_correction: String(correction).trim() } : {}),
    // protagonist context for first_person mode
    ...(povMode === 'first_person' && protagonist ? { protagonist } : {}),
  };

  let lastErr;
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const raw = await claudeClient.generateScript({ systemPrompt, userPayload });
      const parsed = parseClaudeResponse(raw);
      validateShape(parsed, templates, povMode);
      const ratio = computeCtaPositionRatio(parsed);

      // Inject selectedVoiceId into protagonist for first_person mode
      if (povMode === 'first_person' && parsed.protagonist) {
        parsed.protagonist.voice_id = selectedVoiceId || null;
      }

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
