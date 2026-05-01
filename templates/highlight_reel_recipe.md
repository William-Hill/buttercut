# Highlight Reel Recipe

A reusable formula for ~30-second cinematic highlight reels (workouts, sports, action). When asked for a "highlight reel" or "hype edit", ButterCut should follow this structure.

## Target spec

- **Duration:** 28–35 seconds (default 30s).
- **Cut count:** 10–14 clips.
- **Average shot length:** 1.5–2.5s, with one held closing beat (3–5s).
- **Energy curve:** opener → rapid alternating peaks → micro-rest beat → climax → calm hero hold.

## Editorial structure

1. **Opener (2–3s)** — wide kinetic shot establishing motion and tone. Best if it shows the subject in their element. Slight speed ramp from slow to normal works well.
2. **Energy block A (8–10s, 4 clips)** — rapid alternation between two contrasting actions/textures (strength vs. striking, lifting vs. cardio, etc.). Each shot 1.5–2.5s. Cut on beat.
3. **Breath beat (2s, 1 clip)** — quieter detail shot to give the eye a rest. Side profile, close-up, reflection — anything calmer than the surrounding pace.
4. **Energy block B (6–8s, 3–4 clips)** — return to high energy with new angles. Mix in at least one through-something composition (rack, bag, glass, foreground bokeh).
5. **Build (2–3s, 1–2 clips)** — fast inserts, optionally sped up to 150–200%. Compresses time before the closer.
6. **Hero closer (3–5s)** — single held shot. Subject centered or in a strong stance, often looking at camera. Speed ramps down to 60–80% in the final beat. Color/look pushed strongest here.

## Selection priorities

- **Variety over completeness** — show 6–8 different exercises rather than every one.
- **Strongest stylistic frames win** — through-rack, through-bag, foreground bokeh, rear/mirror angles all beat clean wide shots.
- **End with the hero** — if any clip has a posed/portrait moment, save it for last.
- **Skip mistakes** — re-racking, fumbles, breaks. Cut around them.

## Pacing rules

- No two adjacent clips from the same source file unless intentional rhythm.
- Vary shot scale: never put two wides or two tight shots back-to-back.
- Vary direction of motion: if clip N is moving left-to-right, clip N+1 should not.
- Cuts should land on downbeats when scored to music (this is the editor's job in Resolve, not ButterCut's — but plan in/out points around 2-beat increments at ~100 BPM = ~1.2s).

## Closing-beat cinematic moves (for the editor in post)

- Subtle slow-down (60–80%) over the final 0.5–1s.
- Glow effect on highlights (Resolve: ResolveFX Stylize > Glow, low strength).
- Color: deepest teal shadows, warm skin highlights.
- Title card or signature can fade in during the slowdown.

## Inputs ButterCut needs

When invoking the roughcut skill with this recipe:

- `library_name` — required.
- `target_duration` — default 30s, range 28–35s.
- `vibe` — optional descriptor ("cinematic", "energetic", "dark trap", "Y2K-glitch"). Drives clip selection bias.
- `closer_clip` — optional explicit pick for the hero shot. If omitted, ButterCut chooses from clips marked as having posed/portrait moments.
- `exclude_moments` — optional list of "(file, time-range)" tuples to skip (e.g. known fumbles).

## Output expectations

- ButterCut produces the cuts-only YAML + XML.
- A companion `_edit_guide.md` SHOULD be generated alongside the cut, with shot-by-shot post-production direction (color, ramps, transitions, SFX) for the editor to apply manually in their NLE.
