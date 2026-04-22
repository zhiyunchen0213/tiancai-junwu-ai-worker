import { createHash } from 'crypto';

/**
 * Pick a CTA template deterministically from taskId.
 * Same taskId => same template (stable, survives retries).
 *
 * Accepts object-arg form: { taskId, templates, povMode, forceCtaId }
 *   - templates: flat array (legacy → treated as third_person)
 *                OR grouped object { third_person: [...], first_person: [...] }
 *   - povMode: 'third_person' (default) | 'first_person'
 *   - forceCtaId: optional, locks onto specific template_id (or legacy id)
 */
export function pickCtaTemplate({ taskId, templates, povMode = 'third_person', forceCtaId = null } = {}) {
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
