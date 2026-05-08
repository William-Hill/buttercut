# B-Roll Director — Design (Issue #30)

**Status:** Approved 2026-05-07
**Issue:** [#30 — Hyperframes: b-roll director skill](https://github.com/William-Hill/buttercut/issues/30)
**Epic:** [#26 — Hyperframes integration for AI-generated b-roll](https://github.com/William-Hill/buttercut/issues/26)

## Goal

Author the editorial brain of the Hyperframes pipeline: given an existing rough cut and the transcripts/summaries of the videos it references, decide *where graphics belong, what they say, and how they sit in the frame*, and emit a `<roughcut>.broll.yaml` that the existing render skill (#28) and roughcut integration (#33) can consume.

## Why

The vertical slice for Hyperframes already runs end-to-end when the manifest is hand-written: `BrollManifest` schema (PR #25), `render-broll` skill (#28), theme block (#27), and roughcut integration (#33) all shipped. What's missing is the only step a human shouldn't have to do — picking moments, picking templates, and writing the manifest. This spec fills that gap.

## Scope decisions (settled in brainstorming)

1. **Per-rough-cut, cut-relative timing.** Director runs *after* a rough cut exists. `start`/`end` in the manifest are seconds into the rough cut, matching the schema as shipped. (Rejected: per-video candidate pool with later remap; per-video at analysis time. Both add machinery for a benefit — cross-cut reuse — we don't yet need.)
2. **Two surfaces, one prompt.** A new `broll-director` skill *and* a UI button shipped together. Both load the exact same agent prompt file so behavior cannot drift. (Rejected: skill-only with UI as a follow-up — the prompt is the asset, building both surfaces at once forces a clean shared prompt.)
3. **Template discovery from filesystem.** Director auto-discovers templates by listing `hyperframes/compositions/*/README.md` and feeding the READMEs into its prompt as the source of truth for each template's `content` shape. New templates land in #29 without director changes.
4. **Density and threshold are caller inputs, not library.yaml plumbing.** #30 takes `density` (low/medium/high → 2/4/8 graphics-per-minute budget) and `score_threshold` (default 0.5) as args. #31 will later add the `broll:` block in library.yaml that sets defaults; the director's interface doesn't change.
5. **Re-running overwrites.** A second director run on a rough cut that already has a manifest replaces it, with a one-line warning. Existing rendered MP4s in `broll/` are not deleted (entry ids change on re-run, so old files become orphans the user can clean up).
6. **UI button stops at manifest write.** Click → manifest. Render and re-export are #34's territory (late-render workflow). The button surfaces "12 b-roll graphics ready to render" and that's it.

## Architecture

```text
.claude/skills/broll-director/
  SKILL.md                           # parent dispatch brief
  agent_prompt.md                    # canonical director prompt (single source of truth)

ui/sidecar/lib/buttercut_ui_sidecar/
  broll_director_controller.rb       # mirrors RoughcutController; loads .claude/skills/broll-director/agent_prompt.md directly

ui/src/routes/library/
  AddBrollButton.tsx                 # renders inside BriefComposer's done sheet
  BriefComposer.tsx                  # mounts AddBrollButton next to the existing artifact buttons

lib/buttercut/
  broll_director_inputs.rb           # pure-Ruby gathering of inputs from disk (used by both surfaces)
  broll_director_postprocess.rb      # pure-Ruby scoring/threshold/density pruning + id assignment

spec/buttercut/
  broll_director_inputs_spec.rb
  broll_director_postprocess_spec.rb

ui/sidecar/spec/lib/buttercut_ui_sidecar/
  broll_director_controller_spec.rb  # exercises the full controller pipeline against a stubbed model response

spec/fixtures/broll_director/
  sample_library/                    # minimal library with one rough cut + transcripts
```

The Ruby helpers under `lib/buttercut/` are deliberately pure functions (no LLM, no I/O beyond reading inputs the caller passes paths for). Both the skill driver and the sidecar controller use them. The LLM call is the only piece that lives separately in each surface.

### Single source of truth: the prompt

`.claude/skills/broll-director/agent_prompt.md` is canonical. The sidecar controller reads it at job start (resolving the path via the repo root that `RoughcutController` already computes), so any prompt change ships to both surfaces without coordination. We do not maintain two copies.

## Inputs (gathered by the caller, passed to the model)

The caller — skill parent or sidecar controller — gathers these from disk and passes them inline:

- `library_name` (string)
- `roughcut_stem` (filename stem, no extension)
- `roughcut` (parsed YAML of the rough cut: ordered clips with `source_video`, `in`, `out`)
- `theme` (the `theme:` block from library.yaml)
- For each unique `source_video` referenced by the rough cut:
  - `audio_transcript` (parsed JSON)
  - `visual_transcript` (parsed JSON)
  - `summary` (markdown string)
- `available_templates` — array of `{ name: string, readme_md: string }` discovered by listing `hyperframes/compositions/*/README.md`
- `density` — `"low" | "medium" | "high"` (default `"medium"`)
- `score_threshold` — float in `0.0..1.0` (default `0.5`)

Density mapping (hardcoded in this spec; #31 will move it to library.yaml):

| density | graphics per minute |
|---------|---------------------|
| low     | 2                   |
| medium  | 4                   |
| high    | 8                   |

## Director behavior

The model is asked to return a JSON array of candidate entries. Each candidate has:

```jsonc
{
  "source_video": "tutorial_01.mov",
  "source_start": 42.10,        // seconds into the SOURCE video
  "source_end":   47.80,
  "template": "code-callout",
  "placement": "overlay",       // overlay | cutaway | pip
  "content": { "command": "git rebase -i HEAD~3" },
  "score": 0.84,                // 0..1
  "rationale": "introduces `git rebase -i`, terminal visible, structural beat"
}
```

The model is given the rough cut so it knows what spans are actually in the cut, and it's asked to only emit candidates that fall inside a clip. The director prompt instructs it to:

1. Walk each clip in the rough cut. For each clip, scope to the transcript window covering `[in, out]` of the corresponding `source_video`.
2. Identify candidates from that window: terms introduced verbally, named commands/files/functions, lists, structural beats ("step 1"), stats, quotes, comparisons.
3. Pick the best matching template from `available_templates` (skip the candidate if no template fits).
4. Fill the template's `content` payload from transcript words. (Code-string normalization beyond what the model produces naturally is #32's job.)
5. Pick `placement` from the visual transcript context covering that span: terminal/IDE visible → `overlay`; talking head only → `cutaway`; mixed/PiP-friendly → `pip`.
6. Score `(novelty + emphasis + structural_role) / 3` in `0..1`.

Caller-side post-processing (in `broll_director_postprocess.rb`):

7. Drop any candidate with `score < score_threshold`.
8. Map `source_start`/`source_end` → rough-cut-relative `start`/`end` using the clip's offset in the cut and its source `in` point. Clamp to the clip's bounds.
9. Apply density budget: bin candidates by rough-cut-time minute; within each minute, keep top-N by score where N is the per-minute budget.
10. Assign sequential ids (`br-0001`, `br-0002`, …) in time order.
11. Set `rendered: null`, `notes: ""` on every entry. Set manifest `roughcut:` to `roughcut_stem`, `library:` to `library_name`, `version: 2`.
12. Validate via `ButterCut::BrollManifest.from_hash`. Abort with a readable error if invalid (do not write a partial manifest).
13. Write to `libraries/<library>/roughcuts/<roughcut_stem>.broll.yaml`. If a manifest already exists at that path, log a one-line warning naming the prior entry count, then overwrite.

## Surfaces

### Skill (`broll-director`)

`SKILL.md` (parent brief):
- Lists prerequisites: rough cut YAML exists; every `source_video` referenced by it has `transcript`, `visual_transcript`, and `summary` populated in library.yaml. Aborts with a clear message if not.
- Dispatches **one** sub-agent per invocation (the work doesn't parallelize across videos cleanly when the goal is a single coherent manifest).
- Inlines `agent_prompt.md` into the sub-agent prompt; passes inputs as listed above.
- After the sub-agent returns, runs the post-processing pipeline and writes the manifest. Prints: `Wrote N entries to libraries/<lib>/roughcuts/<stem>.broll.yaml (density=<d>)`.

`agent_prompt.md`:
- Self-contained. Describes the director's job, the candidate JSON shape, the template list (passed inline), placement rules, and scoring rubric.
- Returns a JSON array. No file I/O — the parent does all writes.

### UI button

- New sidecar op: `start_broll_director` (Tauri `invoke`, JSON-RPC-style dispatch in `buttercut_ui_sidecar.rb`).
- `BrollDirectorController`:
  - Same shape as `RoughcutController`: real `JobRegistry`, notifier, phase events (`gather`, `model`, `write`).
  - Reads `agent_prompt.md` as system instructions, calls the Anthropic API with the same inputs the skill passes.
  - Validates `roughcut_stem` is a basename before any path joining (rejects `../`, slashes, empty).
  - Streams phase events to the UI over the `sidecar-event:{jobId}` channel.
  - Runs the same post-processing pipeline (`BrollDirectorPostprocess`) and writes the manifest.
- `AddBrollButton.tsx` mounted inside `BriefComposer.tsx`:
  - Renders next to the existing artifact buttons in the rough-cut "done" sheet.
  - Disabled while its own director job is running.
  - On `broll_job_done`, shows entry count + the implicit "rendering is next".
  - Stops at manifest write — no render trigger, no XML re-export.

## Acceptance (from issue #30)

- [x] Output validates against PR #25 schema → enforced by `BrollManifest.from_hash` before write
- [x] Sub-agent contract: no library.yaml reads/writes → parent gathers everything; sub-agent receives only inline values
- [x] Smoke test on a sample tutorial transcript produces non-empty, well-typed manifest → fixture under `spec/fixtures/broll_director/sample_library/` + spec that runs post-processing on a canned model response

Plus:

- [x] UI button on each finished rough cut row produces the same manifest as the skill for the same inputs (shared prompt + shared post-processing)
- [x] Re-running overwrites with a warning; existing renders untouched

## Out of scope for #30

- Late-render workflow / non-destructive swap-in-place (#34)
- `broll:` block in library.yaml + migration (#31)
- Code-string normalization with self-correction loop (#32)
- New templates beyond `code-callout` (#29) — director will only emit `code-callout` entries today; that's correct
- Auto-running director after rough cut completion (the UI button is explicit; auto-chaining is #34's call)

## Tests

- `spec/buttercut/broll_director_inputs_spec.rb` — gathering helpers: rough-cut clip enumeration, transcript-window slicing per clip, path-traversal rejection
- `spec/buttercut/broll_director_postprocess_spec.rb` — pure functions: threshold filtering, density bucket pruning, id assignment, manifest assembly, validation hand-off, density / score_threshold input validation
- `ui/sidecar/spec/lib/buttercut_ui_sidecar/broll_director_controller_spec.rb` — exercises the full controller pipeline end-to-end against a stubbed model response (uses the real `JobRegistry`); also covers `roughcut_stem` traversal rejection
- Smoke: a fixture rough cut + canned model response (JSON file) → post-processing produces a schema-valid manifest with the expected entry count
- No automated test for the React button (consistent with how the rest of the React UI ships today)

## Risks / open questions

- **Model returns malformed JSON.** Wrap parse + validation in a single retry: if the first response fails to parse or validate, send the validation error back to the model and ask for a corrected JSON. Give up after one retry and surface the error.
- **No template fits a strong candidate.** Acceptable — the candidate is dropped. With only `code-callout` available today, the director will mostly emit code callouts. As #29 lands, coverage broadens automatically (no director change).
- **Sidecar prompt path coupling.** Sidecar reads `.claude/skills/broll-director/agent_prompt.md` directly. If repo layout shifts, both surfaces break together — which is the desired failure mode.
