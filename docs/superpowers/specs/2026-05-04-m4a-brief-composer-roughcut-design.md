# M4a — Brief composer + rough cut generation (UI)

**Status:** Implemented 2026-05-04  
**Tracks:** epic [#14](https://github.com/William-Hill/buttercut/issues/14)  
**Depends on:** M2 sidecar + Anthropic pattern  
**Branch:** `sprint-02-m4a-brief-composer`

## Goal

Terminal-free rough cut: user writes a plain-language brief and target duration, optionally forks prior briefs, runs **Generate**, and receives the same on-disk artifacts as the CLI roughcut flow (YAML + editor XML + `.recipe.json` + `*_apply.py`). After generation, the UI shows a flat clip list with in/out and paths; the user opens the XML (etc.) in their NLE manually.

## Architecture (mirrors M2)

- **Sidecar** owns prerequisites check, combined transcript assembly, Anthropic **Sonnet** editorial call (same role as the Claude Code roughcut sub-agent), YAML normalization, and `bundle exec ruby .claude/skills/roughcut/export_to_fcpxml.rb` from the **repo root** (same script the skill documents).
- **No** packaged headless Claude Code Task — one code path with the Anthropic Ruby SDK in-process, matching M2’s “sidecar owns long-running / Anthropic work.”
- **IPC:** JSON-RPC methods on the existing stdio sidecar; progress via notifications with `job_id` scoped Tauri events (`sidecar-event:{job_id}`), same transport as analysis jobs.

## Brief storage

- **Path:** `libraries/<library-slug>/briefs/catalog.yaml` (gitignored with the rest of `libraries/`).
- **Schema:** top-level `briefs:` array of records:
  - `id` (string, `b-` + urlsafe base64)
  - `parent_id` (nullable string; set when created via **Fork**)
  - `prompt` (string)
  - `target_duration_seconds` (integer)
  - `title` (optional short label for the stack UI)
  - `created_at`, `updated_at` (ISO8601 UTC)
- **Fork:** append a new record with a new `id`, `parent_id` = source id, copied `prompt` / `target_duration_seconds`, fresh timestamps. The UI loads the fork into the editor as a new draft.
- **History:** `list_briefs` returns rows sorted by `updated_at` descending (stack of past briefs).

## RPC surface

| Method | Params | Result |
|--------|--------|--------|
| `roughcut_prerequisites` | `library` | `{ "ok": bool, "missing": [ { "video", "missing" } ] }` — `missing` lists which of `transcript`, `visual_transcript`, `summary` are absent per basename. |
| `list_briefs` | `library` | `{ "briefs": [ { id, parent_id, prompt, target_duration_seconds, title, created_at, updated_at } ] }` |
| `upsert_brief` | `library`, `prompt`, `target_duration_seconds`, optional `id`, optional `title` | `{ "id" }` |
| `fork_brief` | `library`, `parent_id` | `{ "id" }` |
| `start_roughcut` | `library`, `brief_id` | `{ "job_id" }` — resolves prompt/duration from catalog; errors if prerequisites fail (sync error on dispatch before job starts) or unknown `brief_id`. |

**Generate flow (UI):** optional `upsert_brief` to persist the draft, then `start_roughcut` with the returned `brief_id`. Prerequisites are checked in the sidecar before spawning the background thread; if not ok, RPC returns an error (no `job_id`).

## Job notifications (`job_id` present)

- `roughcut_job_started` — `{ job_id, library }`
- `roughcut_phase` — `{ job_id, phase, message? }` (`combine_transcript`, `model`, `export`)
- `roughcut_job_done` — `{ job_id, library, yaml_path, xml_path, recipe_path, apply_path, clips: [{ source_file, in_point, out_point }] }`
- `roughcut_job_failed` — `{ job_id, message }`

`cancel_job` reuses **JobRegistry** + **AnalysisJob**-style cancellation (SIGTERM/KILL has no effect on pure Ruby HTTP, but registry clears the job; future work can wire SDK abort).

## Generate → four artifacts

1. Model returns rough cut **YAML** (extracted from a ` ```yaml ` fenced block).
2. Sidecar writes `libraries/<lib>/roughcuts/<stem>_<timestamp>.yaml` with normalized `metadata.created_date` and `metadata.total_duration`.
3. Invokes the existing exporter (unchanged):

   `bundle exec ruby .claude/skills/roughcut/export_to_fcpxml.rb <yaml> <xml_out> <editor>`

   with `editor` in `{ fcpx, premiere, resolve }` from `library.yaml`’s `editor` field (and `libraries/settings.yaml` fallback if empty), matching the skill.

4. Exporter already writes sibling **`.recipe.json`** and **`*_apply.py`** next to the XML/FCPXML path.

**Note:** `export_to_fcpxml.rb` does **not** emit `*_edit_guide.html` today; the sprint doc mentioned it as optional. M4a matches the **implemented** exporter (YAML + XML/FCPXML + recipe + apply script).

## Limits

- Combined visual transcript NDJSON is capped (~900k bytes). Above that, the RPC fails with a clear message suggesting CLI / smaller libraries for now.

## UI (minimal)

- Library detail **tabs:** “Footage” (existing) / “Rough cut”.
- Rough cut: prerequisite banner, prompt + target duration, brief history list (fork + load), Save brief, Generate, Cancel (when job running).
- After `roughcut_job_done`: flat table of clips (source file, in, out) + absolute paths with “Reveal in Finder” via `@tauri-apps/plugin-opener`.
