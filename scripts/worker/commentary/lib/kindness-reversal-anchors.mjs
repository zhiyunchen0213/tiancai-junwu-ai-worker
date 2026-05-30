/**
 * kindness-reversal-anchors.mjs
 *
 * Pure helpers for the kindness-reversal commentary sub-track.
 * Used by generate_script.mjs to locate reversal moments and compute
 * total video duration from jimeng_prompts JSON.
 *
 * No external dependencies.
 */

const REVERSAL_KEYWORDS = ['扔', '砸', '揭晓', '反转', '抛', '丢进', '出现'];

function safeParse(raw) {
  if (!raw || typeof raw !== 'string') return null;
  try { return JSON.parse(raw); } catch { return null; }
}

/**
 * Sum all batch duration_sec values from jimeng_prompts JSON.
 * @param {string|null} jimengPromptsRaw - JSON string of batch array
 * @returns {number} total seconds (0 on invalid input)
 */
export function computeVideoDuration(jimengPromptsRaw) {
  const data = safeParse(jimengPromptsRaw);
  if (!Array.isArray(data)) return 0;
  return data.reduce((sum, batch) => sum + (Number(batch.duration_sec) || 0), 0);
}

/**
 * Extract reversal-moment anchors from jimeng_prompts JSON.
 * Scans shot descriptions for REVERSAL_KEYWORDS and returns
 * absolute timestamps (sec from video start) with descriptions.
 *
 * @param {string|null} jimengPromptsRaw - JSON string of batch array
 * @returns {Array<{sec: number, description: string}>}
 */
export function extractReversalAnchors(jimengPromptsRaw) {
  const data = safeParse(jimengPromptsRaw);
  if (!Array.isArray(data)) return [];

  const anchors = [];
  let batchStartSec = 0;
  for (const batch of data) {
    const shots = Array.isArray(batch.shots) ? batch.shots : [];
    for (const shot of shots) {
      const desc = String(shot.desc || '');
      if (!REVERSAL_KEYWORDS.some(kw => desc.includes(kw))) continue;
      const match = String(shot.time || '').match(/^(\d+(?:\.\d+)?)/);
      if (!match) continue;
      const relSec = parseFloat(match[1]);
      anchors.push({
        sec: batchStartSec + relSec,
        description: desc.slice(0, 80),
      });
    }
    batchStartSec += Number(batch.duration_sec) || 0;
  }
  return anchors;
}
