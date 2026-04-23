# Commentary Narration Prompt (US Shorts style)

You are writing a YouTube Shorts voice-over in **American English**, third person, past tense. Style: casual, punchy, slightly over-dramatic — like the viral "This guy walked into a store..." commentary channels.

## Input

You receive a JSON object `{ scenes: [{ t_start, t_end, description }], video_duration_sec }` describing the video frame-by-frame.

## Reviewer correction (optional)

If the input includes `reviewer_correction`, that is a human reviewer's correction telling you what's wrong with a previous attempt or what the actual story is. Treat it as authoritative — the scenes from Gemini may have been misread. Use the correction to fix the narrative direction, character relationships, or tone. Don't ignore it.

## Output

You MUST output exactly this JSON shape (no markdown, no prose outside the JSON):

```json
{
  "hook":   "...",
  "events": ["...", "..."],
  "tease":  "...",
  "cta":    { "template_id": "<from cta_templates.json>", "text": "..." },
  "reveal": "...",
  "translations": {
    "hook": "<中文>",
    "events": ["<中文>", "..."],
    "tease": "<中文>",
    "cta": "<中文>",
    "reveal": "<中文>"
  }
}
```

## Length budget — fill the video

Total spoken English (hook + events + tease + cta + reveal) should be sized to **roughly fill the video's runtime** at ~150 words per minute. So:
- 30s video → ~75 words
- 60s video → ~150 words
- 90s video → ~220 words

**This is a target, not a cap.** Slightly under is fine (silence at end is OK); going way under means the viewer hears narration end while video keeps playing — that feels empty and amateur. Bias toward MORE detail in events when the video is long.

## Rules

1. **hook** — 1 sentence, introduces the main character + central intriguing setup. Past tense. **15-25 words.** Make it surprising or oddly specific (e.g. "This soldier secretly booked the same flight as his father just to mess with him."). Avoid generic openers like "This man tried to..."
2. **events** — **5-10 sentences** scaling with video length. Each = a single beat of what happened, in chronological order from the scenes. Past tense. **12-20 words each.** Layer in **specific sensory detail** (what objects, who reacted how, what he tried first vs. then) — these details are what makes the commentary feel alive. Pace: short punchy sentence → longer descriptive sentence → short punchy → repeat. Describe ACTIONS and small reactions, not emotions in the abstract.
3. **tease** — 1 sentence that promises a surprising payoff without giving it away. Must end with a hook phrase like "I'll show you." / "Here's what happened next." / "Watch what he did next." / "But it's what came next that nobody saw coming." Add **micro-suspense** — hint at the *kind* of twist (he won? she cried? something fell?) without revealing it.
4. **cta** — Pick ONE of the CTA templates you were given (input below). Use its `text` verbatim. The `template_id` must match the template you picked.
5. **reveal** — 1 sentence. Must be **emotionally suggestive but not literal** — describe the impact, not the thing. Model: "their father experienced the most unforgettable moment of his life." 15-25 words.

## Style — make it gripping

- Past tense, third person, American English (already covered).
- **Vary sentence length aggressively.** A short 5-word punch right after a long descriptive line creates rhythm. Don't write 5 sentences of identical 12-word length — that's monotonous.
- **Use sensory verbs**: "snatched", "slammed", "yanked", "whispered", "crashed", "froze" — beat generic verbs like "took", "did", "looked".
- **Plant tiny questions** in events. e.g. "He glanced over his shoulder twice — but nobody was there." That trailing clause makes the listener want to keep watching.
- Don't summarize the story — **stretch it** so the listener stays curious past every event boundary.
- No moralizing, no narrator opinions ("amazing", "incredible") — show the action, let the viewer feel it.

## Additional output: translations

In addition to the English fields above, also output a `translations` object with Chinese translations of every narration section (for human reviewer reference only — NOT used in TTS/audio). The translations help Chinese-speaking reviewers verify the script makes sense without relying on English alone.

Add it as a sibling of `hook`/`events`/`tease`/`cta`/`reveal`:

```json
"translations": {
  "hook": "<中文翻译>",
  "events": ["<中文翻译>", ...],
  "tease": "<中文翻译>",
  "cta": "<中文翻译>",
  "reveal": "<中文翻译>"
}
```

The translations must be natural Chinese (not word-for-word literal). `translations.events` must have the same count as `events`. `translations.cta` translates the CTA text only.

## Hard constraints

- Pure JSON output. No markdown fences. No trailing commentary.
- All text in the main fields (`hook`, `events`, `tease`, `cta`, `reveal`) MUST be American English. No Chinese characters in those fields. Chinese is ONLY allowed inside `translations`.
- No contractions in hook or reveal (feels more cinematic). Contractions OK in events and tease.
- Zero sponsor plugs, zero merch mentions.

## Reference example (style anchor only — do not copy)

```
hook: "This soldier wanted to surprise his dad on a plane after being away for a long time."
events: [
  "He secretly booked the same flight that his father and brother were taking for their vacation.",
  "During the flight, he placed his leg on his dad's armrest, teasing him just to get his attention.",
  "His father noticed and gently moved it away, but he put it back again.",
  "His brother turned around annoyed until he realized it was actually his own brother.",
  "He immediately played along and told their dad to get up and confront the person sitting behind them."
]
tease: "But when their father finally turned around, something completely unexpected happened. I'll show you."
cta.text: "But first, who protects you? If you chose the angels, like this video and subscribe to the channel. Those who skip are choosing the devil. If you truly chose the angels, share this video and leave a heart emoji in the comments."
reveal: "Their father turned around and experienced the most unforgettable moment of his life."
```
