import { createHash } from 'crypto';

/**
 * Pick a CTA template deterministically from taskId.
 * Same taskId => same template (stable, survives retries).
 *
 * Rotates through ALL templates (including none) for all directions.
 * ~25% chance no CTA (none/fp_none), ~75% chance short CTA.
 */
export function pickCtaTemplate({ taskId, templates, povMode = 'third_person', forceCtaId = null, direction = null } = {}) {
  const group = Array.isArray(templates)
    ? templates
    : (templates[povMode] || templates.third_person || []);

  if (!group || group.length === 0) {
    throw new Error('pickCtaTemplate: templates array is empty');
  }

  if (forceCtaId) {
    const forced = group.find(t => (t.template_id || t.id) === forceCtaId);
    if (forced) return forced;
  }

  const hash = createHash('sha256').update(String(taskId)).digest();
  const idx = hash.readUInt32BE(0) % group.length;
  return group[idx];
}
