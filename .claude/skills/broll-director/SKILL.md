---
name: broll-director
description: Authors a `<roughcut>.broll.yaml` manifest from an existing rough cut + the transcripts of the videos it references. Use after a rough cut is approved when the user wants AI-generated graphics placed on the timeline.
---

# Skill: B-Roll Director (parent brief)

Editorial layer of the Hyperframes pipeline (#26 / #30). Reads a rough cut and emits a sibling `<roughcut>.broll.yaml` of candidate graphics with template, content, timing, placement, and score. The render skill (#28) and roughcut integration (#33) consume the manifest downstream.

`SKILL.md` is the parent's dispatch brief. The sub-agent's working prompt lives in `agent_prompt.md` — inline its contents when launching the Task agent. Don't pass `SKILL.md`.

## Prerequisites

- The rough cut YAML exists at `libraries/<library>/roughcuts/<stem>.yaml`.
- Every `source_video` referenced by the rough cut has `transcript`, `visual_transcript`, AND `summary` populated in `library.yaml`. Abort with a clear message if not.

## Inputs to gather (parent only — sub-agent does not read library.yaml)

Use `ButterCut::BrollDirectorInputs.gather(library_dir:, roughcut_path:, hyperframes_dir:)` to collect:

- `library_name`, `roughcut_stem`, `roughcut`, `theme`
- `source_videos` (per-video audio transcript + visual transcript + summary)
- `available_templates` (auto-discovered from `hyperframes/compositions/*/README.md`)

Plus from the user / defaults:

- `density` — `"low" | "medium" | "high"` (default `"medium"`)
- `score_threshold` — float (default `0.5`)

## Parallelism

Launch **1** sub-agent per invocation. The director needs the full picture of the rough cut to make a coherent manifest; splitting per-video would produce overlapping or duplicate candidates.

## What to pass the sub-agent

Inline the entire contents of `agent_prompt.md`, then append a clearly delimited values block with the gathered inputs serialized as JSON (the prompt expects JSON-shaped values).

## After the sub-agent returns

1. Parse the returned JSON array. If parsing fails, send the parse error back to the model and ask for a corrected JSON. Give up after one retry.
2. Call `ButterCut::BrollDirectorPostprocess.assemble(...)` with the candidates + the gathered inputs + density + score_threshold. This filters by template/threshold, maps source-relative timing to rough-cut-relative, applies the density budget, assigns ids, and validates against `ButterCut::BrollManifest`.
3. If a manifest already exists at `libraries/<library>/roughcuts/<stem>.broll.yaml`, log a one-line warning naming the prior entry count, then overwrite. Existing rendered MP4s in `broll/` are NOT deleted (their entry ids will be orphans the user can clean up later).
4. Write the manifest via `manifest.save(path)` (where `manifest = BrollManifest.from_hash(...)`).
5. Print: `Wrote N entries to libraries/<library>/roughcuts/<stem>.broll.yaml (density=<density>)`.

## Out of scope

- Rendering — that's the `render-broll` skill.
- Re-exporting the editor XML with the b-roll on the timeline — that's the existing roughcut export step (and #34 for late-render swap-in-place).
