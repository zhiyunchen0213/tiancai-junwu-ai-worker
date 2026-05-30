# kindness-reversal-commentary skill track

Sub-track for converting published 真善美 (`kindness-reversal`) short videos into
third-person 天才说书人 narrated commentary videos.

## Files

- `narration_prompt.md` — system prompt for narration script generation (Claude messages)
- `metadata_rewrite_prompt.md` — system prompt for YouTube metadata differentiation
- `cta_templates.json` — CTA snippet pool used by narration generator

## Loaded by

- `scripts/worker/commentary/generate_script.mjs` (when `task.track === 'kindness-reversal-commentary'`)
- `review-server/lib/kindness-commentary-metadata-generator.js` (Task 13)

## Design intent

See `docs/superpowers/specs/2026-05-30-kindness-commentary-mvp-design.md` § 8.

## Voice persona

天才说书人 · 画面叙事型 (third-person, scene-narration first). Validated via 3-round
dry-run iteration in 2026-05-30 brainstorm.

## Updating prompts

These prompts will be tuned based on real generation quality after MVP smoke runs.
Keep version notes in commits when changing.
