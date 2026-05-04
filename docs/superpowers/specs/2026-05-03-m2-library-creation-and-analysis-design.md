# M2 — Library Creation + Analysis from the UI

**Status:** Design approved 2026-05-03
**Tracks:** umbrella [#14](https://github.com/William-Hill/buttercut/issues/14)
**Depends on:** M0 (PR [#15](https://github.com/William-Hill/buttercut/pull/15), merged), M1 (PR [#17](https://github.com/William-Hill/buttercut/pull/17), merged)
**Branch:** `ui-m2-library-creation-and-analysis`

## Goal

A user with no terminal experience can: drag a folder of videos onto ButterCut, name a project, pick a language, and watch the three-stage analysis pipeline (transcribe → analyze → summarize) run to completion with per-file, per-stage progress and streaming artifact previews. When it's done, the new library opens in the M1 footage browser.

This milestone removes the last terminal dependency from onboarding — everything before it required `claude` in a shell to drive the skills.

## Architectural shift

M0 and M1 used the sidecar as a thin adapter — read YAML, run `ffmpeg` for thumbnails, return JSON. M2 promotes the sidecar to **owner of the analysis pipeline**. It now does work that previously belonged to a Claude Code parent agent: dispatching subprocesses, calling the Anthropic SDK, writing artifact files, updating `library.yaml`. The CLI workflow is unchanged — Claude Code is still its parent. The two parents share prompt content (extracted into shared `.md` files) and share the artifact-writing helper scripts. Two parents, one source of truth.

## Decisions log (from brainstorming)

| Q | Decision |
|---|---|
| Streaming-progress IPC | A — JSON-RPC notifications (no `id`) emitted by the sidecar; Rust reader forwards as Tauri events. |
| Where the pipeline runs | 1 — Sidecar uses the Anthropic Ruby SDK directly for analyze + summarize + (optional) refinement; subprocesses for whisperx + ffmpeg. Prompt content extracted into shared files. |
| API key storage (M2) | Plain text in `libraries/settings.yaml` (gitignored), with `ANTHROPIC_API_KEY` env override. Keychain deferred. |
| API key validation | Validate on save with one cheap Messages call; surface bad keys immediately. |
| Cancellation | Hard stop. Kill child PIDs, abort SDK calls, drain workers. Frontend shows "Canceling…" for the 1–2s drain. |
| Concurrency caps | Hard-coded constants matching SKILL.md (transcribe=2, analyze=8, summarize=10). No global rate limiter. No settings UI. |
| New Project surface | Dedicated window (not modal). Becomes the progress window after kickoff. |
| Auto-backup after analysis | Out of scope. CLI flow does this; deferred to a later milestone. |

## Architecture

```text
┌──────────────────────────────┐    invoke()    ┌─────────────────────┐    JSON-RPC over stdio    ┌──────────────────────────────┐
│  React (New Project window)  │ ──────────────▶│  Rust (Tauri core)  │ ────── requests ─────────▶│  Ruby sidecar                │
│                              │                │                     │                           │  + Anthropic Ruby SDK        │
│  listen("sidecar-event:JOB") │ ◀── responses ─│  reader task        │ ◀──── responses + ────────│  + whisperx / ffmpeg subproc │
│                              │ ◀── tauri evt ─│  + emit("…")        │      notifications        │  + worker pools (2/8/10)     │
└──────────────────────────────┘                └─────────────────────┘                           └──────────────────────────────┘
```

### IPC: JSON-RPC notifications → Tauri events

JSON-RPC 2.0 already specifies notifications: a payload without an `id` is server-pushed and never expects a response. M0's reader (`ui/src-tauri/src/sidecar.rs`) currently deserializes lines into `Response { id: Option<u64>, … }` and silently drops `id == None` lines. M2 changes that branch:

1. Try to deserialize each non-empty line as `Response` first.
2. If `id` is `None`, fall back to deserializing as `Notification { method: String, params: Value }`.
3. On a successful notification parse, emit a Tauri event scoped to the job: `app.emit(&format!("sidecar-event:{}", params.job_id), params)`.

The existing request/response path is unchanged. The reader holds an `AppHandle` (passed in via `init`) so it can emit events.

**Frontend** subscribes after calling `start_analysis(...)`:

```ts
const { job_id } = await invoke<{job_id: string}>("start_analysis", { ... });
const unlisten = await listen<JobEvent>(`sidecar-event:${job_id}`, (e) => {
  reducer.dispatch(e.payload);
});
```

`unlisten()` is called when the window closes or analysis completes.

### Event schema

All events carry `{ job_id, ts }` plus the fields below. Sidecar emits them; frontend reduces them into per-clip per-stage state.

| Method | Params | When |
|---|---|---|
| `job_started` | `library, video_count, total_duration_seconds` | Immediately after `start_analysis` returns. |
| `file_queued` | `video, stage` | Worker pool accepts a unit but a slot isn't free. |
| `file_started` | `video, stage` | Worker picks up the unit. |
| `file_progress` | `video, stage, message?, percent?` | Optional, e.g. whisperx percent or "extracting frames". UI may render or ignore. |
| `artifact_ready` | `video, stage, artifact_path` | Artifact file is written and `library.yaml` updated. UI fetches via `get_clip_transcripts`. |
| `file_failed` | `video, stage, error_kind, message, log_path?` | Stage failed; details in error and optional captured-stderr log. |
| `file_done` | `video, stage` | Stage complete (always immediately follows `artifact_ready` for that stage). |
| `job_done` | `succeeded_count, failed_count` | All units drained. |
| `job_canceled` | `succeeded_count, failed_count` | Hard-stop drain finished. |

### New RPC surface (request/response)

| Method | Params | Returns | Notes |
|---|---|---|---|
| `inspect_video_paths` | `{paths: string[]}` | `{accepted: [{path, duration_seconds, size_bytes}], rejected: [{path, reason}]}` | Pure-stdlib + ffprobe shell-out. Validates each path is a video the pipeline can handle. Reasons: `not_found`, `not_video`, `unreadable`, `zero_duration`. |
| `create_library` | `{name, language, language_code, refinement, video_paths: string[]}` | `{name}` (canonical, slugified) | Atomically creates `libraries/<slug>/` + `transcripts/`, `summaries/`, writes `library.yaml` from template with all videos populated and empty artifact fields. Rolls back the directory on partial failure. Errors with `library_exists` if `<slug>` already present. |
| `start_analysis` | `{library}` | `{job_id}` | Validates the API key is present; returns `missing_api_key` RPC error otherwise. Otherwise enqueues every video × stage that doesn't already have its artifact. Returns immediately. |
| `cancel_job` | `{job_id}` | `{}` | Idempotent. Triggers hard-stop drain. Real "this job is fully canceled" signal arrives later as a `job_canceled` event. |
| `retry_unit` | `{job_id, video, stage}` | `{}` | Re-enqueues a single failed stage for one video. Errors with `unknown_job` if the job has already been finalized; in that case the UI should call `start_analysis` again to resume. |
| `set_api_key` | `{key}` | `{ok: true}` | Validates the key with one cheap Messages call (e.g. a 1-token "ping" to Haiku); on success persists to `libraries/settings.yaml`. On failure returns `invalid_api_key` with the upstream error message. |
| `has_api_key` | `{}` | `{configured: bool}` | True if env or `libraries/settings.yaml` provides one. UI uses this to decide whether to show the API-key modal preemptively (it doesn't gate startup, but the modal can be shown alongside Step ⑤ if not configured). |

All responses use the same JSON-RPC envelope as M0/M1.

### Sidecar internal structure

```text
ui/sidecar/
├── buttercut_ui_sidecar.rb        # entry point (existing) — adds dispatch for new methods + notification helper
├── lib/buttercut_ui_sidecar/
│   ├── limits.rb                  # TRANSCRIBE_PARALLELISM=2, ANALYZE_PARALLELISM=8, SUMMARIZE_PARALLELISM=10
│   ├── settings_store.rb          # reads/writes libraries/settings.yaml; layered with ENV
│   ├── library_creator.rb         # create_library RPC; uses templates/library_template.yaml
│   ├── video_inspector.rb         # inspect_video_paths RPC; ffprobe shell-out
│   ├── analysis_job.rb            # one-per-job orchestrator: cancel_token, child PIDs, worker pools
│   ├── job_registry.rb            # in-memory job_id → AnalysisJob; survives only while sidecar runs
│   ├── stages/
│   │   ├── transcribe.rb          # whisperx subprocess + prepare_audio_script + optional refinement
│   │   ├── analyze.rb             # ffmpeg frame extract + Anthropic vision call → visual_*.json
│   │   └── summarize.rb           # visual_script_extractor + Anthropic Haiku call → summary_*.md
│   ├── anthropic_client.rb        # thin wrapper around the SDK; per-call abort handle, retry on 429
│   └── notifier.rb                # emits jsonrpc notifications on the shared stdout (mutex-guarded)
└── prompts/
    ├── analyze_video.md           # extracted creative content (referenced by both sidecar + agent_prompt.md)
    └── summarize_video.md         # extracted creative content
```

The CLI's `agent_prompt.md` files are rewritten to *include* the prompts from `prompts/` rather than repeat them. Single source of truth for prompt text.

**Note on `prompts/` location.** They live under `ui/sidecar/prompts/` for the same reason `lib/` does — they're sidecar implementation. The CLI `agent_prompt.md` files reference them via relative path. If the relative-path coupling proves awkward in implementation, move them to `.claude/skills/<skill>/<name>_prompt.md` and have the sidecar resolve via the repo root. Implementation call.

### Worker pools

Each stage has a fixed-size pool (`Concurrent::FixedThreadPool` from `concurrent-ruby`). A `WorkUnit` is one video × one stage. The job's lifecycle:

1. `start_analysis` builds the unit list: for each video missing `transcript`, push a transcribe unit; for each missing `visual_transcript` and **with audio transcript already present or queued**, transcribe→analyze chains; same for summarize. We don't pre-enqueue analyze units for videos that haven't transcribed yet — instead, when a transcribe unit finishes, its `file_done` handler enqueues the dependent analyze unit. Same chain analyze→summarize.
2. Each worker, before doing any work: check `cancel_token`. If flipped, return without emitting `file_started`.
3. Worker registers any spawned child PIDs and any in-flight Anthropic request handles with the `AnalysisJob` so cancellation can reach them.
4. Worker writes its artifact to `<path>.tmp`, then atomic-renames to the final filename. On any error or cancel mid-write, the `.tmp` is removed by the reaper.
5. Worker takes a brief mutex on the library's yaml file, updates the relevant field, releases. Concurrent writers across stages can collide on the same file — the mutex (one per library) serializes them.

### Cancellation: hard stop

`cancel_job(job_id)`:

1. Flip the job's `cancel_token`.
2. Iterate the job's child-PID registry: SIGTERM each, then SIGKILL after 2s if still alive.
3. Iterate in-flight Anthropic request handles: call abort.
4. Worker pools shutdown (no new units accepted; in-flight workers see the token flip and bail before their next blocking call).
5. Sweep `*.tmp` files in the library's `transcripts/` and `summaries/` directories.
6. Emit `job_canceled` with succeeded/failed counts.

The frontend hard-stop UX (per the design discussion): "Cancel" button → confirm modal → call `cancel_job` → window header shows "Canceling…" until `job_canceled` arrives → final "Canceled · N of M complete" state with a "Resume analysis" button (which just re-runs `start_analysis` on the same library — the pipeline already skips finished artifacts).

### API key handling

- **Source of truth** at startup: `ENV["ANTHROPIC_API_KEY"]` first, then `libraries/settings.yaml`'s `anthropic_api_key:` field. The sidecar holds the resolved value in memory; if neither is set, it stays `nil`.
- **No app-launch gate.** Projects screen and M1 footage browser don't need a key.
- **First-failure modal.** When the New Project window's Step ⑤ "Start analysis" runs, the frontend calls `has_api_key` first; if not configured, show the API-key modal *before* `start_analysis`. If `start_analysis` itself returns `missing_api_key` (e.g. race or env unset between calls), same modal.
- **Modal:** copy + paste field + "Save." Save calls `set_api_key`, which validates with one Haiku ping. On success, modal closes and the original action proceeds. On failure, the modal stays open with the upstream error.
- **Mid-job 401:** surfaces as a `file_failed` event with `error_kind: "auth"`. The job stops accepting new units (drains in-flight); UI offers the same modal to re-key + a "Resume" action.

### Concurrency caps

Per-stage pool sizes from `limits.rb`. Stages run sequentially per video; pools are independent. Natural pipelining: while later videos are still transcribing, earlier ones are summarizing.

No global rate limiter. The Anthropic SDK retries on 429 with backoff; cap=10 on Haiku and cap=8 on the vision model are well under typical per-account limits for M2's volumes (dozens of clips per library).

## UI

### Entry: New Project tile

The Projects window grid (M0) gains a "+ New Project" tile in the same card style as existing libraries but with a tungsten-amber dashed border and a centered glyph. Click → opens a new window via a new Tauri command `open_new_project_window()` (parallel to M0's `open_library_window`).

### New Project window — setup phase

Five linear steps in a single window. Breadcrumb at top:

```text
① Pick footage  →  ② Name  →  ③ Language  →  ④ Refinement  →  ⑤ Analyze
```

Active step is large; previous steps muted with back arrow; future steps faintly outlined.

#### Step ① — Pick footage

Full-pane dropzone (dashed amber border, 60% of pane height). Subtitle: "Drop a folder or video files here." Below: "or **Choose folder…** / **Choose files…**" buttons → `@tauri-apps/plugin-dialog` `open({ directory: true })` / `open({ multiple: true })`.

Drag/drop wired via Tauri's window-level `onDragDropEvent`, which delivers absolute file paths (not webview `File` objects). Folders are flattened recursively, top-level only — we don't descend into subdirectories. Files are passed through `inspect_video_paths`. UI renders accepted clips as a list (filename + duration); rejected clips collapse into "N skipped" with a disclosure. Drop more to append; per-row X to remove.

**Continue** disabled when accepted is empty.

#### Step ② — Name

Single text input, autofocused. Live preview of the slug below the input. On every keystroke, call `list_libraries` and check for collision against the slug. Collision → red hint, **Continue** replaced with "Choose a different name." Slugging algorithm matches the CLI flow: lowercase, spaces→dashes, strip non-alphanumeric/dash.

#### Step ③ — Language

Three option cards: **English** (default selected), **Spanish**, **Other…**. "Other…" reveals a text field + a faint disclosure "What's a language code?" with a one-line explanation and a link to ISO 639-1. Save both human name (e.g. "English") and code (e.g. `en`).

#### Step ④ — Refinement

Two cards. Heading text quotes the CLI flow exactly: *"Can I proofread the transcripts after they're generated? I'll use the video's context to fix mistakes."* Cards: **Yes — Recommended** ("Use Claude to refine video understanding") and **No.** Default Yes.

#### Step ⑤ — Confirm + Analyze

Summary card listing project name (slug), N videos with total duration, language, refinement on/off. Below it: API-key state — if not configured, shows a banner "ButterCut needs your Anthropic API key" with a "Set up" button that opens the modal pre-flight (so the user can paste the key before clicking Start). Primary footer button: **Start analysis**.

Click flow:
1. If `has_api_key` is false, open API-key modal first; on save proceed.
2. Call `create_library`. If it errors (`library_exists`, etc.), show the error inline and let the user go back.
3. Call `start_analysis` → receive `job_id` → swap pane to progress view.

### New Project window — progress phase

Replaces the setup pane in the same window. Header: project name (large), Cancel button (right). Body:

**Top summary strip.** Progress bar showing `done / total` clips (where "done" = all three stages complete). Subtitle: "N of M clips ready · K minutes elapsed." Failed count shown in red if any.

**Per-clip rows.** Filename (mono) + three stage chips (transcribe / analyze / summarize):

| State | Glyph | Color |
|---|---|---|
| not started | `○` | dim grey |
| queued | `⏳` | dim amber |
| in progress | `◐` | tungsten amber, slow pulse |
| done | `✓` | tungsten amber, solid |
| failed | `✗` | red, clickable |

**Row expansion.** Click a row → expands to show the artifact streaming in. The frontend listens for `artifact_ready` events for that clip and immediately fetches the artifact via the existing M1 RPC `get_clip_transcripts(library, video)`:

- transcribe done: first ~6 lines of audio transcript text + "View full transcript" disclosure.
- analyze done: condensed list of visual descriptions, one line per segment.
- summarize done: rendered markdown of `summary_*.md`.
- transcribe in progress: shows whisperx percentage from `file_progress` events if available; otherwise just the pulsing chip.

**Failure rendering.** On `file_failed`, the row auto-expands to show:

```text
✗ analyze stage failed
   IMG_4423.mov · 2025-05-03 14:22

   ffmpeg exited with code 1:
     [error] could not seek to 00:00:02 — file may be truncated

   [Retry analyze]   [Skip this file]   [Show full log]
```

- **Retry analyze**: re-enqueues just that stage for that video. New `retry_unit(job_id, video, stage)` RPC.
- **Skip this file**: marks failed for the job. Job continues with remaining units.
- **Show full log**: opens a modal with the full captured stderr (sidecar saves stage stderr to `tmp/<job_id>/<video>.<stage>.log` while running).

### Cancel UX

Cancel button in window header → confirm modal "Cancel analysis? Files already analyzed will be kept." → `cancel_job` → header switches to "Canceling…" with a small spinner → on `job_canceled`, header shows "Canceled · N of M complete" with primary button **Resume analysis** and secondary **Open Library**. Resume re-issues `start_analysis` on the same library; the pipeline naturally skips already-completed stages (their artifacts and yaml entries are present).

### Done UX

On `job_done`: header shows "Analysis complete · N clips" (and if any failed, "· N failed" in red). Failed rows remain visible with retry options. Primary footer button **Open Library** → opens the M1 footage browser via `open_library_window` and closes the New Project window.

### API-key modal

Single modal usable from two entry points (Step ⑤ pre-flight, mid-job auth failure):

- Title: "Connect your Anthropic API key"
- Body: short copy explaining ButterCut uses Claude to analyze footage, with a link to console.anthropic.com.
- Input: password-style text field for the key.
- Buttons: **Save** (primary), **Cancel**.
- On Save: spinner + "Validating…" → call `set_api_key`. Success: modal closes. Failure: error line below input shows the upstream message; modal stays open.

## Out of scope (re-confirmed)

- Auto-backup after analysis (CLI does this; deferred to later milestone).
- Editing the project after kickoff (rename, add/remove clips).
- Pausing analysis (cancel + resume-as-restart only).
- Settings UI for the API key (modal only).
- Migration UI for legacy library.yaml schemas. (CLAUDE.md migrations should still be run by the CLI Claude before opening a UI window. M2 doesn't add migration UX — but does verify on `create_library` that the template emitted is current.)
- Per-stage retry from the Projects screen. Retry is only available from the in-progress / final-state New Project window.
- Mid-job add-files. Adding more clips is a future milestone (or just create another library).
- Subdirectory recursion when a folder is dropped. Top-level files only in M2.

## Acceptance criteria

- [ ] Projects screen shows a "+ New Project" tile that opens the New Project window.
- [ ] Step ①: drop a folder of mixed video + non-video files. Accepted clips appear with durations; non-video files appear in the "N skipped" disclosure.
- [ ] Step ①: native folder picker and native multi-file picker both populate the accepted list.
- [ ] Step ②: typing a name shows the live slug below the input. Typing a name that collides with an existing library disables Continue with a clear message.
- [ ] Step ③: selecting Other… reveals an ISO-code text field; the resulting library.yaml has the human name as `language` and the code is used by transcribe.
- [ ] Step ④: refinement choice persists to library.yaml `transcript_refinement`.
- [ ] Step ⑤ with no API key configured: pre-flight banner + Set-up button; the modal validates the key with a Haiku ping and rejects bogus keys with the upstream error.
- [ ] `create_library` produces a directory + library.yaml that the CLI workflow can pick up unchanged (round-trip with the existing `transcribe-audio` skill should work).
- [ ] During analysis, every clip shows three stage chips. Each chip transitions through queued → in progress → done in real time, driven by JSON-RPC notifications.
- [ ] Expanding a row mid-transcribe shows whisperx progress; expanding after transcribe done shows the first lines of the transcript text fetched via `get_clip_transcripts`.
- [ ] Forcibly causing a stage failure (rename a video file mid-job, set a bad API key, etc.) renders a specific failure card with stderr, and Retry / Skip / Show full log all work.
- [ ] Hitting Cancel during an active job kills child whisperx/ffmpeg processes within ~2s and emits `job_canceled`. The library on disk has artifacts for everything that finished and no `.tmp` files left behind.
- [ ] Resume analysis after a cancel re-runs only the un-completed stages.
- [ ] Done state's **Open Library** button opens the M1 footage browser populated with the new library.
- [ ] No regressions: M0 Projects screen still works; M1 Library window still works; CLI workflow (transcribe / analyze / summarize / roughcut skills) still works against a library that the UI created.
- [ ] `cargo check`, `pnpm build`, `bundle exec rspec` (existing failures aside), and a sidecar smoke test for each new RPC all pass.

## Test plan

- Smoke each new sidecar method via piped JSON: `inspect_video_paths`, `create_library`, `set_api_key`, `has_api_key`, `start_analysis`, `cancel_job`, `retry_unit`.
- Manual happy path against a small fixture library (3–4 short clips) end-to-end: setup → kickoff → done → Open Library.
- Cancel mid-transcribe (slow whisperx run) and verify processes die, no orphan `.tmp` files, library is consistent.
- Cancel mid-summarize (after several artifacts have already landed) and verify the partial library is fully usable in M1.
- Force a failure in each stage independently and verify the row UX:
  - transcribe: rename the source file just before whisperx runs.
  - analyze: corrupt the audio transcript JSON.
  - summarize: temporarily set a bad model name in `anthropic_client.rb`.
- API-key flows: empty state, bad key, mid-job revocation (replace settings file mid-run).
- Two New Project windows simultaneously creating two libraries — verify no shared state, both progress views update independently, cancel one doesn't affect the other.
- CLI round-trip: create a library via the UI, then run the `roughcut` skill against it from a terminal to confirm the schema matches.

## Open implementation questions (not blockers for this design)

- Exact `concurrent-ruby` or `Thread`-based pool implementation. Either works; pick whichever has lighter dependency footprint when implementing.
- Whether to extract prompts under `ui/sidecar/prompts/` or `.claude/skills/<skill>/`. Implementation-time decision based on what's less awkward to reference from both parents.
- Vision model choice for analyze: probably `claude-sonnet-4-6` for vision quality; settle in plan stage with a quick A/B against the existing CLI output.
- Capturing whisperx percentage: whisperx prints to stderr in a non-machine-friendly format. Either parse loosely for `file_progress` percent or just emit a generic "transcribing…" pulse and skip the percent. Decide in plan.
