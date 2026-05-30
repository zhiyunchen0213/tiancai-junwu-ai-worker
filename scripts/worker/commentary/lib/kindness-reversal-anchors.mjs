/**
 * kindness-reversal-anchors.mjs
 *
 * Pure helpers for the kindness-reversal commentary sub-track.
 * Used by generate_script.mjs to compute total video duration and locate
 * reversal moments from `jimeng_prompts` (markdown text with embedded
 * `<!-- jimeng-config { ... } -->` JSON block — same format used by
 * review-server/lib/atrefs-refs-consistency-guard.js parseJimengConfig).
 *
 * jimeng-config JSON shape:
 *   {
 *     "name": "...",
 *     "ratio": "9:16",
 *     "batches": [
 *       { "prompt": "...", "scene": "...", "duration": 12, "refs": [...], "atRefs": [...] },
 *       ...
 *     ]
 *   }
 *
 * No external dependencies.
 */

const REVERSAL_KEYWORDS = ['扔', '砸', '揭晓', '反转', '抛', '丢进', '出现'];

/**
 * Parse the `<!-- jimeng-config ... -->` block from jimeng_prompts markdown text.
 * Returns { batches: [...] } object or null on missing/invalid.
 * Matches the regex used by review-server/lib/atrefs-refs-consistency-guard.js
 * parseJimengConfig (no `\n` requirement around the comment markers per 2026-05-26 治本).
 */
function parseJimengConfig(jimengPromptsRaw) {
  if (!jimengPromptsRaw || typeof jimengPromptsRaw !== 'string') return null;
  const m = jimengPromptsRaw.match(/<!--\s*jimeng-config\s*([\s\S]*?)\s*-->/);
  if (!m) return null;
  try {
    const cfg = JSON.parse(m[1]);
    if (!cfg || !Array.isArray(cfg.batches)) return null;
    return cfg;
  } catch {
    return null;
  }
}

/**
 * Sum all batch.duration values from jimeng-config block.
 * @param {string|null} jimengPromptsRaw - markdown with embedded jimeng-config JSON
 * @returns {number} total seconds (0 on invalid input)
 */
export function computeVideoDuration(jimengPromptsRaw) {
  const cfg = parseJimengConfig(jimengPromptsRaw);
  if (!cfg) return 0;
  return cfg.batches.reduce((sum, batch) => sum + (Number(batch.duration) || 0), 0);
}

/**
 * Extract reversal-moment anchors from jimeng-config block.
 * Each batch's `prompt` text is scanned for REVERSAL_KEYWORDS. If a keyword
 * appears, the anchor is placed at the midpoint of that batch (no per-shot
 * timestamps available in this format — the prompt is one continuous chunk).
 * Description is a short snippet around the first keyword occurrence.
 *
 * @param {string|null} jimengPromptsRaw - markdown with embedded jimeng-config JSON
 * @returns {Array<{sec: number, description: string}>}
 */
export function extractReversalAnchors(jimengPromptsRaw) {
  const cfg = parseJimengConfig(jimengPromptsRaw);
  if (!cfg) return [];

  const anchors = [];
  let batchStartSec = 0;
  for (const batch of cfg.batches) {
    const prompt = String(batch.prompt || '');
    const duration = Number(batch.duration) || 0;
    // Find first keyword occurrence in the prompt — anchor at batch midpoint.
    for (const kw of REVERSAL_KEYWORDS) {
      const idx = prompt.indexOf(kw);
      if (idx === -1) continue;
      // Snippet: 30 chars before keyword to 50 chars after (covers Chinese context)
      const start = Math.max(0, idx - 30);
      const end = Math.min(prompt.length, idx + 50);
      const snippet = prompt.slice(start, end).replace(/\s+/g, ' ').trim();
      anchors.push({
        sec: Math.round((batchStartSec + duration / 2) * 10) / 10,
        description: snippet,
      });
      break;  // only the first reversal keyword per batch — avoid noise
    }
    batchStartSec += duration;
  }
  return anchors;
}
