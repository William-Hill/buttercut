# Programmatic Fusion Fuse application via recipe + apply.py

Tracking: William-Hill/buttercut#23

## Summary

Extend the Resolve apply-script path to install and apply Fusion Fuses (Lua-based Resolve plugins) per clip, driven by recipe directives. Resolve-only feature — FCPXML cannot carry fuses.

This slots into the existing "FCPXML for assembly, recipe + apply.py for Resolve-specific niceties" split alongside speed ramps, color tags, markers, render presets, and PowerGrades.

## Decisions

| Question | Decision |
| --- | --- |
| Verification strategy | Lua lint in CI + manual `ruby .claude/scripts/verify_fuses.rb <fixture.mov>` smoke gated before release |
| Fuse library location | In-tree at `fuses/` |
| Activation | Explicit user request only (no roughcut auto-suggest in v1) |
| First-install UX | apply.py copies fuses; if `AddTool` returns None, prompt the user to restart Resolve once and re-run |
| v1 fuse set | ChromaPulse, VHSGlitch, FilmGrain, LightLeak, ZoomPunch |

## Fuse package layout

```text
fuses/
  ChromaPulse/
    ChromaPulse.fuse        # Lua source
    manifest.json           # name, version, description, params [{name, type, default, range}]
    reference.png           # documentation screenshot (not a test fixture)
  VHSGlitch/
  FilmGrain/
  LightLeak/
  ZoomPunch/
```

`manifest.json` shape:

```json
{
  "name": "ChromaPulse",
  "version": "1.0.0",
  "description": "Chromatic aberration that pulses on a beat or marker.",
  "tested_on_resolve": "20.2.3",
  "params": [
    { "name": "intensity", "type": "number", "default": 0.4, "range": [0.0, 1.0] },
    { "name": "speed", "type": "number", "default": 1.0, "range": [0.1, 4.0] }
  ]
}
```

Hard rule for v1: every shipped fuse is implemented compositionally (MediaIn → built-in Fusion nodes → MediaOut), not as per-pixel Lua. Pure Lua per-pixel is too slow at 4K.

## Recipe schema

Bump `SCHEMA_VERSION` from 1 to 2. Existing v1 recipes continue to validate (the new field is optional). v2 recipes with no `fusion_effects` are functionally identical to v1.

Per-clip extension:

```json
{
  "index": 3,
  "source_file": "...",
  "fusion_effects": [
    { "fuse": "ChromaPulse", "params": { "intensity": 0.4 } }
  ]
}
```

Validation rules in `Recipe`:

- `fusion_effects` is optional; when present, must be an array of hashes.
- Each entry's `fuse` must match a registered fuse in the in-tree library (loaded by `FuseLibrary` at recipe construction).
- Each entry's `params` keys must be a subset of the manifest's declared params; values must satisfy declared type and range. Unknown keys raise.
- Order within the array is preserved — apply.py wires fuses in array order between MediaIn and MediaOut.

## Ruby components

**`lib/buttercut/fuse_library.rb`** (new) — single class.

- Class method entry point: `FuseLibrary.load(root: "fuses")` returns a frozen registry.
- Reads each `fuses/*/manifest.json`, indexes by `name`.
- Public: `lookup(name)`, `validate_params!(name, params)`, `each` (for callers that need to enumerate).
- Raises `ArgumentError` on duplicate names, malformed manifests, or missing required manifest keys.
- One class per file, one public entry point, private helpers — per project Ruby style.

**`lib/buttercut/recipe.rb`** — extend.

- Bump `SCHEMA_VERSION` to 2.
- `validate_clip!` calls a new `validate_fusion_effects!(clip)` when the key is present.
- `validate_fusion_effects!` consults a `FuseLibrary` instance held on the recipe (default-loaded from in-tree `fuses/`; injectable for tests).
- `to_h` round-trips `fusion_effects` when present, omits when empty/absent.

**`.claude/skills/roughcut/recipe_from_roughcut.rb`** — pass `fusion_effects` through from the rough-cut YAML when present. No interpretation logic; the field is user-authored in v1.

**`.claude/skills/roughcut/generate_apply_script.rb`** — stamp two new constants into the generated apply.py:

- `FUSES_SOURCE_DIR` — absolute path to the in-tree `fuses/` directory (resolved from gem root at generate-time).
- `RESOLVE_FUSES_DIR` — `~/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Fuses/` (Mac) or platform equivalent. Generation-time only — the path is platform-specific so it's resolved when the script is generated, not at runtime.

## Python components (`apply_recipe.py` template)

Phase order in `Applier.apply()`:

1. **`_install_fuses`** — runs **first** (before `_apply_per_clip`) so referenced `.fuse` files exist on disk before any per-clip Fusion work. Walk `recipe["clips"]`, collect distinct `fuse` names referenced. For each, copy from `FUSES_SOURCE_DIR/<name>/<name>.fuse` to `RESOLVE_FUSES_DIR/<name>.fuse` if missing or content-different (compare by hash). Track `newly_installed` list. Idempotent.
2. **`_apply_per_clip`** — existing per-clip steps, including **`_apply_fusion_effects`** for clips with `fusion_effects`:
   - Detect an existing buttercut-managed comp (node name prefix `ButterCut_`) and skip re-application if all effects already present.
   - Otherwise: `item.AddFusionComp()` to get a `Comp`. For each effect in order, `Comp.AddTool(fuse_name)`; if `AddTool` returns None, append `(clip_idx, fuse_name)` to `needs_restart` and break out of this clip's loop.
   - Wire MediaIn → effect[0] → effect[1] → … → MediaOut by connecting `Input` to the previous tool's `Output`.
   - Set params via `Tool:SetInput(param_name, value)`.

3. **Reporting** — extend existing `counts` / `manual` / `warnings`:
   - `counts["fusion_effects"] = [applied, total]`
   - If `newly_installed` non-empty: print `[apply_recipe] installed fuses: <names>`
   - If `needs_restart` non-empty: print a clear restart-and-rerun message naming each affected clip and fuse.

Failure modes:

- Fuse file missing in source dir → `warnings`, skip.
- `AddFusionComp` returns None → `warnings`, skip clip.
- `SetInput` raises or returns False → `warnings`, continue with remaining params (don't abort the fuse).
- Param not in manifest → caught earlier in Ruby validation; should never reach Python.

## Verification

**CI: Lua lint**

- New `.luacheckrc` at repo root declares Fusion Lua globals (`Comp`, `Tool`, `MediaIn`, `MediaOut`, `RegisterFuse`, `InMask`, `Output`, etc.).
- New CI step: `luacheck fuses/**/*.fuse`.
- Catches: syntax errors, undefined identifiers, typos in API calls, unused vars.
- Does **not** catch: "does the fuse actually produce pixels," wrong param wiring, runtime errors.

**Manual gate: `ruby .claude/scripts/verify_fuses.rb <fixture.mov>`**

- Reads the fuse library, builds a synthetic recipe with one clip per registered fuse pointing at the fixture video.
- Generates a temp apply.py, prints instructions to the user: open fixture in Resolve, run the script, paste the output here.
- Pass criteria per fuse: `AddTool` returned truthy, comp present after run, no warnings for that fuse.
- Run before each release. Output captured in `tmp/verify_fuses_<timestamp>.log` and pasted into the release notes.
- Reference PNGs in `fuses/<name>/reference.png` are for human eyeball comparison only — no per-pixel diff in v1.

## Roughcut YAML extension

Optional `fusion_effects` array per clip in the rough-cut YAML, mirroring the recipe schema. The roughcut skill emits these only when explicitly requested by the user (e.g. "add ChromaPulse to clip 3").

```yaml
clips:
  - index: 3
    source_file: foo.mov
    in: 12.4
    out: 18.2
    fusion_effects:
      - fuse: ChromaPulse
        params:
          intensity: 0.4
```

## Out of scope (v1)

- Auto-suggesting fuses from the roughcut skill.
- Generating fuses on the fly per project.
- FCPXML / Premiere fuse support.
- Cross-clip transition fuses (single-clip effects only).
- DCTL / OpenCL kernel fuses (pure-Lua + node-graph compositional fuses only).
- Per-library local fuses (`libraries/[name]/fuses/`) — deferred follow-on.
- Per-pixel reference-image diffing in `verify_fuses`.

## Risks

- **Resolve API drift.** `Comp:AddTool` and node wiring are stable in 20.x but historically shift across major versions. Mitigation: pin `tested_on_resolve` in each manifest; surface in verify output; revisit on Resolve 21.
- **Pure-Lua perf.** Per-pixel Lua is unusably slow at high resolution. Hard rule: every v1 fuse is compositional. Documented for fuse #6 onward.
- **Recipe size growth.** Many params per fuse can balloon JSON. Cap at 3–5 params per fuse in v1; revisit if a fuse genuinely needs more.
- **First-run friction.** "Restart Resolve once" is a real interruption the first time a user encounters a new fuse. Apply.py messaging must be unambiguous about which fuses triggered the restart and that re-running is the resolution.

## Test plan

- RSpec for `FuseLibrary`: load valid library, reject duplicates, reject malformed manifests, lookup hit/miss, param validation (type, range, unknown keys).
- RSpec for `Recipe`: v2 round-trip with `fusion_effects`, validation of fuse name and params, v1 backwards compat (no `fusion_effects`).
- RSpec for `recipe_from_roughcut.rb`: passes `fusion_effects` through unchanged.
- Python unit tests for the new template helpers where feasible (the install-fuses copy logic is testable without Resolve).
- Manual: `ruby .claude/scripts/verify_fuses.rb <fixture.mov>` against a fixture in Resolve before merge.

## Rollout

Single PR closes #23. Tag `v0.7.0-fuses` after merge for users who want to opt in early. Update CHANGELOG.md noting the v1→v2 recipe schema bump (additive; v1 recipes still valid).
