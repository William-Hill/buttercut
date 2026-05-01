# Resolve Scripting API Audit (Sprint 1, Phase 3 prerequisite)

**Status:** complete (probe run 2026-05-01 on Resolve 20.2.3.6 free) · **Issue:** #3 · **Blocks:** #4 (Phase 3 apply script)

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

## Verdict matrix

Probe environment:
- Resolve product: **DaVinci Resolve** (free)
- Resolve version: **20.2.3.6**
- Probe run: 2026-05-01

| Capability      | API present | Probe result | Notes |
|-----------------|-------------|--------------|-------|
| `speed_ramps`   | yes         | **error → limited** | `item.GetClipProperty("Speed")` raised `TypeError: 'NoneType' object is not callable` on `TimelineItem`. `GetClipProperty` is reliably available on `MediaPoolItem` (reach it via `TimelineItem.GetMediaPoolItem()`); multi-point retime curves still not in the public API. |
| `color_tags`    | yes         | **yes**             | `SetClipColor` round-trip succeeded; restoration verified. |
| `markers`       | yes         | **yes**             | `AddMarker(frame=1, "Red", ...)` returned True; cleanup succeeded. |
| `powergrade`    | yes         | **limited**         | Gallery + `GetGalleryStillAlbums` + `GetCurrentStillAlbum` all present; one album returned with `None` label. No direct `ApplyPowerGradeByName` — must walk stills. |
| `render_preset` | yes         | **yes**             | `LoadRenderPreset` + `SetCurrentRenderMode` both present and callable. 24 saved presets visible. |
| `transitions`   | no          | **no**              | No `*transition*` attributes on `Project`, `Timeline`, or `TimelineItem`. Confirms the long-standing gap. |

## Phase 3 implications

Transitions are confirmed **not scriptable** on Resolve 20.2.3 free. Phase 3 takes the second branch:

**Phase 3 scope (locked):**

| Recipe directive | Phase 3 path |
|------------------|--------------|
| Speed ramps (constant) | Apply via `MediaPoolItem.SetClipProperty("Speed", value)`, reached through `TimelineItem.GetMediaPoolItem()`. Single-value only — multi-point ramps in `recipe.speed_ramps` collapse to the highest non-100% value with a logged warning. |
| Speed ramps (multi-point) | Not applied. Logged note per clip: `"Multi-point ramp on clip N — apply manually in Resolve retime curve."` Recipe still carries the points for Phase 4 / future. |
| Color tags | `TimelineItem.SetClipColor(tag)` — full support. |
| Markers | `TimelineItem.AddMarker(frame, color, name, note, duration)` — full support. |
| PowerGrade | Best-effort: walk `Gallery.GetGalleryStillAlbums()` for a still whose label matches `recipe.powergrade.name`, apply via still selection. If lookup fails, log `"PowerGrade '<name>' not found — apply manually."` and continue. |
| Render preset | `Project.LoadRenderPreset(name)` + `Project.SetCurrentRenderMode()` — full support. |
| Transitions | **Not applied.** Logged per transition: `"Phase 4 (FCPXML 1.10) or manual: <type> between clip N and N+1."` Recipe still carries the directives. |
| Title card | Not applied (no scripted text generator API surfaced). Logged as manual. |

**Phase 4 (FCPXML 1.10) becomes recommended, not optional** — it's the realistic path for transitions on Resolve. Speed ramps may also survive better through the FCPXML round-trip than through the apply script.

**One follow-up against the probe itself:** the `speed_ramps` `TypeError` confirms `TimelineItem.GetClipProperty` is unreliable in 20.2.3. Phase 3's apply script must reach `Speed` via `MediaPoolItem`. The probe could be tightened in a future iteration to test that path directly — not blocking Phase 3.

## Next steps

1. Open #4 (Phase 3 apply script) with the locked scope above.
2. Promote #5 (Phase 4 / FCPXML 1.10) from optional to recommended.
