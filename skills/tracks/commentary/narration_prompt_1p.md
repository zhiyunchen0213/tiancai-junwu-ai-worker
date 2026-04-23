# Commentary · 第一视角（First-Person POV）

You are writing a 5-section YouTube Shorts commentary script where the PROTAGONIST narrates in first person (`I / me / my`). Output must be a single valid JSON object (no markdown fences, no trailing text).

## Hard Rules

1. **Five sections**, in order: `hook`, `events`, `tease`, `cta`, `reveal`.
2. **Language**: `hook`, `events`, `tease`, `cta`, `reveal` text fields are **pure English, zero Chinese characters**. Chinese only in `translations.*` mirror objects.
3. **First person**: the narrator IS the protagonist, referring to self as `I / me / my`. Do not use third person for the protagonist.
4. **Tense (mixed / historical present)**:
   - `hook` — **past tense mandatory**, **no contractions** (use `I was`, not `I'm`).
   - `events` — mix past and historical present. **Minimum 2 present-tense action verbs** across the events block (e.g., `she walks in`, `he freezes`).
   - `tease` — past or present, as long as it ends with a suspense hook aimed at the viewer.
   - `cta` — copy the chosen template text verbatim (see CTA section).
   - `reveal` — **past tense mandatory**, **no contractions**, emotional hint only, do not over-explain.
5. **Fourth-wall policy (fully broken in CTA, broken-allowed in tease, NO breaking in hook/events/reveal)**:
   - CTA directly addresses `you` (viewer).
   - Tease may include phrases like `"You won't believe ..."`.
   - Hook / events / reveal must stay in-world — protagonist reliving events, not addressing anyone.
6. **CTA**: choose exactly one template from the `first_person` group (IDs starting with `fp_`). Copy `text` VERBATIM. Do not modify wording.
7. **Word budgets**:
   - hook: 15-25 words
   - events: 5-10 sentences, 12-20 words each
   - tease: 1 sentence
   - cta: whatever the template says
   - reveal: 15-25 words
8. **No banned adjectives**: don't use `amazing`, `incredible`, `unbelievable` as standalone hype words.
9. **Sentence rhythm**: vary sentence length. Don't write 5 sentences of identical 12-word length.
10. **Grounded in protagonist**: use the PROTAGONIST context (appearance, role_tagline, emotion_arc) to anchor concrete sensory details. E.g., if protagonist wears a leather jacket, you may say `"I felt my jacket zipper catch on the doorframe"` — do NOT fabricate details that contradict the provided appearance.

## Inputs

You will receive JSON:

```json
{
  "scenes": [ { "t_start": 0, "t_end": 3, "description": "..." } ],
  "protagonist": {
    "name": "John",
    "gender": "male",
    "age_band": "30-49",
    "appearance": "30 岁白人男，皮夹克棕发",
    "role_tagline": "酒吧门口撞人的男主",
    "emotion_arc": "愤怒 → 后悔 → 释然"
  },
  "correction": "可选：审核员修正（优先级高于 scenes 里的描述）",
  "cta_templates": [
    { "template_id": "fp_angels_devils", "text": "I was the devil ..." }
  ],
  "chosen_cta_template_id": "fp_...",
  "cta_position_ratio": 0.70
}
```

## Output Format

```json
{
  "pov_mode": "first_person",
  "protagonist": { "name": "John", "voice_id": null },
  "hook": "...",
  "events": ["...", "...", "..."],
  "tease": "...",
  "cta": { "template_id": "fp_...", "text": "..." },
  "reveal": "...",
  "translations": {
    "hook": "...",
    "events": ["...", "...", "..."],
    "tease": "...",
    "cta": "...",
    "reveal": "..."
  }
}
```

- `protagonist.voice_id` stays `null` — it's filled in by the worker with the reviewer's selection.
- `translations.events.length` MUST equal `events.length`.

## Emotion Arc Usage

The `emotion_arc` field (e.g., `"愤怒 → 后悔 → 释然"`) tells you the protagonist's emotional trajectory. Use it to shape tone across sections:

- Early events: emotion start (anger)
- Mid events: emotion pivot (regret)
- Reveal: emotion end (release)

Do not state emotions explicitly ("I was angry"). Show them in word choice, rhythm, and physical detail.

## Reviewer Correction

If `correction` is non-empty, treat it as authoritative ground truth that overrides any conflicting interpretation from `scenes`. Preserve scene details that don't conflict.
