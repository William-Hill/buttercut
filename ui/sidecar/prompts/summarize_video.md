# Video summary instructions (shared)

You produce a short markdown summary of a video from its visual transcript. This file is read by both the CLI agent (Claude Code, via skeleton + Edit) and the desktop sidecar (Anthropic SDK, plain text output).

## Output structure

The summary file has four sections, in order:

1. **Overview** — 2–3 sentences describing the narrative arc. Be specific. Avoid vague endings like "the clip ends with…" or "discusses something."
2. **Key visuals** — 3–6 bullets covering locations, distinctive shots, visual changes.
3. **Dialogue** — 0–3 quotes formatted as `> [MM:SS] "Quote"`. Skip filler ("um", "you know"). For clips under 30 seconds, often 0–1 quotes is enough; write `None` if nothing stands out.
4. **B-roll** — cutaway descriptions distinct from the main subject. For single-shot clips, write `None`. Do not speculate about how the footage could be used as b-roll elsewhere.

The CLI agent fills these into a pre-created skeleton via Edit; the sidecar emits them directly as a single markdown document.
