import { createHash } from 'crypto';

/**
 * Pick a CTA template deterministically from taskId.
 * Same taskId => same template (stable, survives retries).
 */
export function pickCtaTemplate(taskId, templates) {
  if (!Array.isArray(templates) || templates.length === 0) {
    throw new Error('pickCtaTemplate: templates array is empty');
  }
  const hash = createHash('sha256').update(String(taskId)).digest();
  const idx = hash.readUInt32BE(0) % templates.length;
  return templates[idx];
}
