# Sprint 1 — Editorial Automation

**Status:** planning · **Branch:** `sprint/editorial-automation` (to create) · **Target:** ~2 weeks · **Date:** 2026-04-30

## Goal

Extend ButterCut so a rough cut isn't just a cuts-only timeline — it ships with an **editorial recipe** that can be applied to the imported timeline to produce an ~80%-finished edit hands-free. Speed ramps, transitions, color, markers, render presets — automated.

The remaining 20% (music, art-direction color taste, titles) stays in the editor's hands because those are creative judgement calls.

## Background — why

Today ButterCut emits XML and the editor (DaVinci Resolve / Premiere / FCP) imports it as straight cuts. Everything else — speed ramps on slams, color grading, transitions, sound cue placement — is manual. We've prototyped a markdown/HTML edit guide that documents these choices, but it still requires the human to apply each one.

The recipe + apply-script architecture closes that loop. ButterCut already knows *which* clips to ramp/grade because the editorial reasoning happened in the roughcut agent — we just lose that reasoning at the XML boundary. This sprint persists it.

## Out of scope

- Automatic music selection or sound-design generation.
- Color grading taste decisions (we apply a saved PowerGrade; we don't generate one).
- Premiere Pro / Final Cut Pro automation. Resolve only this sprint — Premiere has a separate scripting model (UXP/ExtendScript) and FCP X has a different XML round-trip. Both follow-on sprints.
- Headless ffmpeg rendering. NLE-driven only.

## Architecture

```text
ButterCut roughcut skill
  ├── highlight-reel_<ts>.yaml         (existing)
  ├── highlight-reel_<ts>.xml          (existing — Resolve xmeml v5)
  ├── highlight-reel_<ts>.recipe.json  (NEW — per-clip directives)
  ├── highlight-reel_<ts>_apply.py     (NEW — Resolve Python, drop into Scripts/Edit/)
  └── highlight-reel_<ts>_edit_guide.html (existing prototype, formalized)
```

The user imports the XML in Resolve (one-click), then runs `Workspace > Scripts > Edit > Apply <name>` and the recipe is applied to the timeline they just imported.

## Phases

### Phase 1 — Recipe schema (1–2 days)

- `lib/buttercut/recipe.rb` — Ruby class that builds the recipe alongside the XML.
- Schema (JSON):
  ```json
  {
    "version": 1,
    "library": "march-30-workout",
    "timeline": "highlight-reel_20260430_184655",
    "render_preset": { "format": "mp4", "codec": "h264", "resolution": "1080p", "bitrate_kbps": 25000 },
    "powergrade": { "name": "GymBlueOrange-v1", "apply_to": "all" },
    "clips": [
      {
        "index": 3,
        "source_file": "medicine-ball-slams.mp4",
        "speed_ramps": [
          { "at": 1.5, "speed": 200, "ease": "ease-out" },
          { "at": 2.5, "speed": 100, "ease": "ease-in" }
        ],
        "color_tag": "Orange",
        "markers": [{ "at": 1.8, "name": "impact", "color": "Red" }]
      }
    ],
    "transitions": [
      { "between": [3, 4], "type": "dip_to_color", "color": "black", "duration_frames": 4 },
      { "between": [11, 12], "type": "dip_to_color", "color": "white", "duration_frames": 4 }
    ],
    "title_card": {
      "at_clip": 12,
      "text": "{{user_handle}}",
      "fade_in_at": 0.5,
      "fade_in_frames": 6
    }
  }
  ```
- **Acceptance:** unit test in `spec/recipe_spec.rb` round-trips the schema; invalid inputs raise.

### Phase 2 — Roughcut agent emits recipe (2–3 days)

- Update `.claude/skills/roughcut/agent_instructions.md` to instruct the agent to produce recipe directives during clip selection (not as a post-pass) — the editorial reasoning ("ramp this slam to 200%", "dip to white before the hero") is already happening in the agent's head; capture it.
- Wire `lib/buttercut/recipe.rb` into the roughcut export so YAML→XML+recipe is one operation.
- **Acceptance:** running the roughcut skill produces all four artifacts (yaml, xml, recipe.json, edit_guide.html). The `march-30-workout` library is the regression fixture.

### Phase 3 — Resolve apply script (3–4 days)

- `.claude/skills/roughcut/templates/apply_recipe.py` — template Python that reads `<name>.recipe.json` next to itself.
- Generate `<name>_apply.py` per cut by stamping the template with the recipe path.
- Capabilities (in priority order):
  1. Speed ramps via `clip.GetClipProperty("Speed")` and retime curve API.
  2. Clip color tags via `SetClipColor()`.
  3. Markers via `clip.AddMarker()`.
  4. Apply saved PowerGrade by name (apply via `MediaPool.AppendToTimeline` workaround if direct API unavailable).
  5. Render preset via `Project.LoadRenderPreset()` / `SetCurrentRenderMode`.
  6. Transitions: best-effort — Resolve API for transitions is limited; may have to skip and document as manual.
- **Acceptance:** drop the `march-30-workout` rough-cut XML into a fresh Resolve project, import, run the apply script, observe ramps + color tags + markers + render preset applied.

### Phase 4 — Optional: FCPXML 1.10 backend (3 days, deferred if Phase 3 takes long)

- `lib/buttercut/fcpx.rb` already exists (FCPXML 1.8). Bump to 1.10 and emit `<timeMap>` for speed ramps, `<filter-video>` references for transitions/color.
- Resolve's FCPXML import is more permissive than its xmeml import — many recipe directives may "just work" without the apply script, giving fallback path.
- **Acceptance:** same regression library imports into Resolve via FCPXML 1.10 with at least speed ramps preserved (transitions and color may not survive — document what does).

### Phase 5 — Demo + cleanup (1 day)

- End-to-end demo recording: open Resolve, import march-30-workout XML, run apply script, render. Capture timing.
- Update CLAUDE.md "Workflow Steps" to reflect the new artifact set.
- Bump version, update CHANGELOG.

## Verification / demo

The success bar: take the `march-30-workout` library, run the roughcut skill, import + apply in Resolve, render. The output should be a 30-second cut with:
- All speed ramps applied (200% slam, 150% jump-rope insert, 60% hero closer)
- A consistent color grade across all clips (the saved PowerGrade)
- Markers at sound-cue points so the editor only has to drop SFX onto markers
- Render preset loaded for 1080p YouTube

Manual finishing: pick music, drop SFX onto markers, write title card text, render.

## Open questions

1. Resolve scripting API has gaps for transitions and certain effect parameters. Phase 3 needs early spike to confirm what's actually scriptable on the free Resolve version vs Studio. **Action:** day-1 spike script that probes the API; report findings before committing the phase plan.
2. PowerGrades are project-local. Do we ship a default `GymBlueOrange-v1.drx` in `templates/`? Or require the user to create their own and reference by name?
3. Where do we store the `<name>_apply.py` template? Inside the skill folder feels right, but Resolve script discovery is path-based — we may need to write the generated script directly into `~/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Edit/`. Need to handle both "ship next to roughcut" and "install for Resolve" paths.

## Branch / worktree setup

```bash
cd /path/to/buttercut
git checkout -b sprint/editorial-automation
# or use a worktree to keep main clean for ad-hoc edits:
git worktree add ../buttercut-sprint-01 sprint/editorial-automation
```
