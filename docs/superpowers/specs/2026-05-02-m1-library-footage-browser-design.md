# M1 — Library Footage Browser

**Status:** Design approved 2026-05-02
**Tracks:** [#16](https://github.com/William-Hill/buttercut/issues/16) (umbrella: [#14](https://github.com/William-Hill/buttercut/issues/14))
**Depends on:** M0 (PR [#15](https://github.com/William-Hill/buttercut/pull/15), merged)
**Branch:** `ui-m1-library-footage-browser`

## Goal

The Library window — an empty placeholder in M0 — becomes a read-only footage browser. Open a library, see a grid of clips on the left, select one to load its summary + interleaved transcript + inline player on the right. Click a word in the audio transcript to scrub the player to that word's timestamp.

This is the highest-value passive feature in the desktop rollout: it lets users browse AI-analyzed footage in a UI instead of grepping JSON files.

## Test corpus reality

The only fully-analyzed library on disk (`march-30-workout`) is **silent gym footage**:

- 11 clips, each ~30–75 seconds.
- Audio transcripts have `segments: []` — no spoken words anywhere.
- Visual transcripts have ~3 rich segments per clip.
- No `summaries/` directory exists; library predates the per-video summary feature. Only library-level `footage_summary` is present.

**Implication:** M1 is designed for first-class empty states. Click-word-to-scrub is built but unverifiable against this corpus until a talky library is added; that path will be exercised in M2 or via a hand-added test fixture.

## Architecture

Same three tiers from M0 — React frontend → Rust Tauri shell → Ruby sidecar over JSON-RPC stdio. M1 adds three RPC methods and one Rust capability extension (assetProtocol scope). No new processes, no new IPC mechanism.

```text
┌─────────────────────────┐    invoke()     ┌─────────────────────┐    JSON-RPC over stdio    ┌────────────────────────┐
│  React (Library window) │ ───────────────▶│  Rust (Tauri core)  │ ─────────────────────────▶│  Ruby sidecar          │
│                         │ ◀───────────────│  + assetProtocol    │ ◀───────────────────────── │  + ffmpeg shell-out    │
└─────────────────────────┘                 └─────────────────────┘                            └────────────────────────┘
       │                                            │
       │  convertFileSrc(path) → http://asset.localhost/...
       └─────────────── direct media load ─────────────────▶ video files & thumbnails on disk
```

### Sidecar additions (three new methods)

All three are pure stdlib Ruby; only `get_or_generate_thumbnail` shells out (to ffmpeg). Errors return JSON-RPC error responses with useful messages; the frontend renders a per-field empty state rather than failing the whole pane.

| Method | Returns | Notes |
|---|---|---|
| `get_library(name)` | `{name, footage_summary, video_paths_root, videos: [{filename, path, duration_seconds, has_audio_transcript, has_visual_transcript, has_summary}]}` | One read of `library.yaml`. `filename` is the basename of `path` (used as the stable per-clip identifier passed to other methods). `has_*` flags derived from non-empty filename fields. `video_paths_root` is the longest common parent directory of all video paths — used to grant the assetProtocol scope. |
| `get_clip_transcripts(library, video)` | `{audio: <transcript json or null>, visual: <visual transcript json or null>, summary: <markdown string or null>}` | Reads up to three files. Missing files return `null`, not error. Schema-mismatch errors (corrupt JSON) return RPC error with the clip identified. |
| `get_or_generate_thumbnail(library, video)` | `{path: "/abs/path/to/thumbnail.jpg"}` | Cache at `libraries/<name>/thumbnails/<video-stem>.jpg`. On cache miss: shell out to `ffmpeg -ss 1 -i <path> -frames:v 1 -q:v 4 -y <out>`. On hit: just return path. |

### Rust shell additions

- **AssetProtocol** enabled in `tauri.conf.json` (`security.assetProtocol.enable: true`, scope initially empty).
- At app startup (in `setup()`), grant the libraries root recursively — this covers all per-library `thumbnails/` directories without needing per-library grants for them. Path is the same `BUTTERCUT_LIBRARIES_ROOT` already resolved for the sidecar.
- On Library window open, frontend calls a new Tauri command `allow_video_paths(root: String)` that calls `app.asset_protocol_scope().allow_directory(root, recursive=true)`. Scope is additive across libraries — opening a second library extends the allow-list, doesn't replace it. The command only validates that `root` is a non-empty absolute path; it does **not** verify the path was returned by a recent `get_library` call. Rationale: Tauri IPC is reachable only from the bundled frontend, so the threat model "compromised JS escalates to read arbitrary files" requires already-running attacker-controlled code in our own webview, at which point the validation provides no real defense. Revisit if the frontend is ever opened to third-party plugins.
- New plain `#[tauri::command]` wrappers for `get_library`, `get_clip_transcripts`, `get_or_generate_thumbnail` — same pattern as M0's `list_libraries` (delegate to `sidecar::call`).
- The CSP set in M0 needs `media-src` and `img-src` widened to allow `http://asset.localhost` (img-src already has `asset:` and `http://asset.localhost`; media-src defaults to `default-src` which currently lacks the asset host — fix by adding an explicit `media-src 'self' asset: http://asset.localhost`).

### Library data flow on window open

1. Library window opens with `?name=<lib>` in the hash route.
2. Frontend calls `get_library(name)` → receives video list + `footage_summary` + `video_paths_root`.
3. Frontend calls `allow_video_paths(video_paths_root)` to grant assetProtocol scope.
4. Frontend renders the clip grid; first clip auto-selected.
5. Selection change fires `get_clip_transcripts(library, video)`; pane re-renders.
6. Thumbnail requests fire lazily as cards become visible (IntersectionObserver) → `get_or_generate_thumbnail`, returned path passed through `convertFileSrc` for `<img src>`.
7. Player URL = `convertFileSrc(video.path)`.

## UI

### Window layout

Full-window two-pane split, no header chrome (the OS titlebar shows the project name).

```text
┌─────────────────────────────────┬─────────────────────────────────────────┐
│  Clip grid (left, ~340px wide)  │  Detail pane (right, fills remainder)   │
│  scrollable                     │  ─ stage zone (~40% height) ─           │
│                                 │   Player + footage_summary              │
│  ┌─────┐ ┌─────┐                │  ──────────────────────────────         │
│  │card │ │card │                │  ─ transcript zone (~60%, scrolls) ─    │
│  └─────┘ └─────┘                │   Interleaved visual/audio rows         │
│  ┌─────┐ ┌─────┐                │                                         │
│  │card │ │card │                │                                         │
│  └─────┘ └─────┘                │                                         │
└─────────────────────────────────┴─────────────────────────────────────────┘
```

### Clip card

Two-up grid, ~150px wide cards. Each card:

- 16:9 thumbnail (lazy-loaded via IntersectionObserver → `get_or_generate_thumbnail`).
- Filename (mono, truncated).
- Duration (mono, faint).
- Single analysis dot — amber if any of audio/visual/summary missing, dim-amber if all present, hairline grey if nothing analyzed.
- Selected state: tungsten amber border + raised surface.
- Loading placeholder: faint amber shimmer at the same aspect ratio.

### Detail pane — stage zone (~40%)

- Video player: HTML5 `<video controls preload="metadata" />` with `src = convertFileSrc(video.path)`. Native controls only in M1. Player held in a React `ref` so transcript clicks can write `video.currentTime`.
- Footage summary below the player: italic display face, faint, 3-line clamp with "show more" disclosure. Source: library-level `footage_summary`.

### Detail pane — transcript zone (~60%)

Interleaved rows, screenplay-style. Algorithm:

```text
for visual_segment in visual_transcript.segments:
    render visual row
    for audio_segment in audio_transcript.segments where audio.start ∈ [visual.start, visual.end):
        render audio row (indented under the visual row)
```

**Visual row:** `[mm:ss]` mono timestamp · italic visual description · faint `b-roll` chip if `b_roll: true`. Click anywhere → `video.currentTime = visual.start`.

**Audio row** (indented ~24px from the visual row): regular sans, individual word `<span>`s. Each word click → `video.currentTime = word.start`. Hover changes word to amber. If `words[]` is missing on a segment (older transcripts), fall back to plain text with click-to-`segment.start` only.

Visual segments with no overlapping audio render alone — the entire silent-gym corpus reads cleanly this way.

### Empty states (first-class)

| Field | Rendering |
|---|---|
| `footage_summary` empty | Hide the summary block entirely (no "—" placeholder) |
| Audio transcript missing OR `segments: []` | Visual rows render alone; no banner |
| Visual transcript missing | Single faint mono italic line: "This clip hasn't been analyzed yet." in the transcript zone |
| Both transcripts missing | Same line. Player still works. |
| Per-clip summary missing | Not rendered in M1 (only library-level summary) |
| Thumbnail generation fails | Card shows hairline-bordered box with filename — no error toast |
| Selected clip's video file missing on disk | Stage zone shows: "Can't find the video file. Expected at: `<path>`" |

## Out of scope (re-confirmed)

- Transcript editing, find/replace, "trust this name" — M3.
- Per-video summary pane — none in current libraries; arrives with M2 or a backfill migration.
- Clip multi-select, sort/filter, search, favorites.
- Keyboard shortcuts beyond what the native player provides.
- Persistence of selection / scroll / player time.
- Regeneration / re-analysis triggers — those are M2.

## Acceptance criteria

- [ ] Clicking a project card from the Projects window opens the Library window populated (replaces M0 placeholder).
- [ ] Clip grid renders all videos in the library with thumbnails generated lazily, durations, and analysis dot.
- [ ] First clip auto-selected on open; selecting another clip loads its transcripts in the detail pane.
- [ ] Player plays the selected clip via assetProtocol; native scrubber works.
- [ ] Visual transcript rows render and seek the player on click.
- [ ] Where audio words exist, clicking a word seeks the player to that word's `start`.
- [ ] Empty audio segments produce no audio rows and no banner.
- [ ] Force-renaming a clip's video file → reselect → specific "Can't find the video file" message with path.
- [ ] Force-deleting `visual_*.json` → that clip shows "hasn't been analyzed yet."
- [ ] Two Library windows open simultaneously — both work; assetProtocol scope is additive.
- [ ] Close + reopen Library window → first clip selected (no persistence).
- [ ] No regressions: M0 Projects screen still works, sidecar still terminates cleanly on app exit.
- [ ] `cargo check`, `pnpm build`, and the sidecar smoke tests for the three new methods all pass.

## Test plan

- Smoke-test each new sidecar method directly via `echo '...' | ruby ui/sidecar/buttercut_ui_sidecar.rb libraries`.
- Manual run-through of the acceptance list against `march-30-workout`.
- Empty-state coverage: hand-edit a copy of `library.yaml` to set one video's `visual_transcript: ""` and another video's `path: /nonexistent.mp4`; verify both render cleanly.
- Multi-window: open Projects, click `march-30-workout` (M0 already focuses an existing window if open with the same name — confirm that contract still holds in M1).
- Click-word-to-scrub: cannot be verified against the current corpus (audio is empty). Will be exercised manually against a hand-added talky fixture (a single short interview clip) before merging.

## Decisions log (from brainstorming)

| Q | Decision |
|---|---|
| Test corpus footing | B — design for graceful empty states; don't gate M1 on backfill migrations. |
| Video playback | A — Tauri assetProtocol with dynamic scope grant per library. |
| Thumbnails | B — lazy generation per visible card, cached on disk at `libraries/<name>/thumbnails/`. |
| Detail pane layout | B — fixed top stage (~40%) with player + summary; scrolling transcript below (~60%). |
| Sidecar API granularity | B — tiered: `get_library` for list, `get_clip_transcripts` per selection, thumbnails independently. |
| Selection persistence | B — none for M1; first clip selected on every open. |
