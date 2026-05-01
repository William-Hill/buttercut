# Resolve Scripting API Audit (Sprint 1, Phase 3 prerequisite)

**Status:** awaiting probe run · **Issue:** #3 · **Blocks:** #4 (Phase 3 apply script)

## Background

Phase 3 plans a per-cut Python script that consumes `<name>.recipe.json` and applies its directives to the imported timeline. Six capabilities sit on the critical path:

1. **Speed ramps** — `TimelineItem` retime curve
2. **Clip color tags** — `TimelineItem.SetClipColor`
3. **Markers** — `TimelineItem.AddMarker`
4. **PowerGrades** — apply a saved grade by name across all clips
5. **Render presets** — load a saved preset and set it as current
6. **Transitions** — insert dip-to-color / cross-dissolve between clips

Some of these are well-supported on free Resolve. Others (transitions, PowerGrade-by-name) are documented gaps. This memo establishes verdicts before we commit Phase 3 scope.

## Method

1. Drop `scripts/resolve_api_audit.py` into Resolve's Edit scripts directory:
   - macOS: `~/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Edit/`
   - Windows: `%APPDATA%\Blackmagic Design\DaVinci Resolve\Support\Fusion\Scripts\Edit\`
   - Linux: `~/.local/share/DaVinciResolve/Fusion/Scripts/Edit/`
2. Open Resolve, open any project with at least one clip on V1 of the current timeline.
3. Open `Workspace > Console` (so the matrix prints somewhere visible).
4. Run `Workspace > Scripts > Edit > resolve_api_audit`.
5. Probe writes `~/buttercut_resolve_audit.json` and prints a feature matrix to the console.

The probe is non-destructive: it adds and removes one disposable marker, sets and restores the first clip's color tag, and otherwise only reads.

## Expected priors (from public Resolve scripting docs)

These are the working assumptions going into the probe — to be confirmed or overturned by the run.

| Capability      | Expected      | Reasoning |
|-----------------|---------------|-----------|
| `speed_ramps`   | Limited       | `GetClipProperty("Speed")` is documented; retime curve points are not a first-class API on free. Constant speed change is straightforward; multi-point ramps may require workarounds. |
| `color_tags`    | Yes           | `SetClipColor` / `ClearClipColor` documented and stable across versions. |
| `markers`       | Yes           | `AddMarker(frame, color, name, note, duration)` documented and stable. |
| `powergrade`    | Limited       | No direct `ApplyPowerGradeByName()`. Accessible via `Gallery.GetGalleryStillAlbums()` → walk stills → apply. Workable but indirect; album naming matters. |
| `render_preset` | Yes           | `LoadRenderPreset(name)` and `SetCurrentRenderMode()` documented. `GetRenderPresetList()` enumerates. |
| `transitions`   | No (likely)   | The Resolve scripting API has historically lacked any public method to insert a transition between clips. The probe enumerates `*transition*` attributes on `project` / `timeline` / `TimelineItem` — if none surface, this is confirmed. |

## Verdict matrix (TODO — fill after running the probe)

Paste the rows from `~/buttercut_resolve_audit.json` here once you've run the script.

| Capability      | API present | Probe result | Notes |
|-----------------|-------------|--------------|-------|
| `speed_ramps`   | TBD         | TBD          | TBD   |
| `color_tags`    | TBD         | TBD          | TBD   |
| `markers`       | TBD         | TBD          | TBD   |
| `powergrade`    | TBD         | TBD          | TBD   |
| `render_preset` | TBD         | TBD          | TBD   |
| `transitions`   | TBD         | TBD          | TBD   |

Probe environment:
- Resolve product: TBD
- Resolve version: TBD
- Free or Studio: TBD

## Phase 3 implications (TODO — finalize after verdict matrix)

Two branches depending on the `transitions` verdict.

**If transitions are scriptable:**
- Phase 3 keeps the originally planned scope: speed ramps + color tags + markers + render preset + PowerGrade (best-effort) + transitions.
- Recipe schema unchanged.

**If transitions are not scriptable on free Resolve:**
- Phase 3 ships everything *except* transitions. The recipe.json still carries the directives — they just won't be applied automatically.
- The apply script logs a one-line note per transition: "Phase 4 (FCPXML 1.10) or manual: <type> between clip N and N+1".
- Phase 4 (FCPXML 1.10 backend, currently optional) becomes the realistic path for transitions, since Resolve's FCPXML import is more permissive than Resolve's xmeml import.

**For PowerGrade specifically** — even if the gallery-still walk is technically possible, the implementation cost may exceed the value. A documented one-click manual step ("right-click hero clip → Apply Grade > GymBlueOrange-v1") is acceptable for Phase 3 if the gallery API path turns out brittle. Decision deferred to verdict review.

## Next steps

1. Run the probe; paste results into the verdict matrix.
2. Settle the transitions branch above.
3. Open #4 (Phase 3 apply script) with finalized scope based on this memo.
