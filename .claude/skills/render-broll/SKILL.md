---
name: render-broll
description: Renders one b-roll manifest entry to MP4 via Hyperframes. Use when a broll.yaml manifest exists and entries need their `rendered` field populated.
---

# Skill: Render B-Roll (parent brief)

Takes one entry from a `broll.yaml` manifest plus the active library theme and produces an MP4 at `libraries/<library>/broll/<id>.mp4`.

`SKILL.md` is the parent's dispatch brief. The sub-agent's working prompt lives in `agent_prompt.md` — inline its contents when launching the Task agent. Don't pass `SKILL.md`.

## Parallelism

Launch at most **2 in parallel**. Each Hyperframes render spawns a Chrome process plus FFmpeg; 2 keeps a 16GB Mac comfortable.

## Inputs to gather and pass inline

The parent reads the manifest (`libraries/<lib>/roughcuts/<id>.broll.yaml`) and the library's theme block, then for each entry passes inline:

- `entry` — the full manifest entry hash (id, template, content, start, end, …)
- `theme` — resolved theme tokens hash (for now `{ "name": "tutorial-dark" }` — #27 will lift real tokens out of library.yaml)
- `output_dir` — `libraries/<library>/broll/`
- `hyperframes_dir` — absolute path to `hyperframes/` at the repo root

## After the agent returns

Update the manifest entry's `rendered` field to the returned path (filename only, e.g. `broll/br-0001.mp4`) and save the manifest via `ButterCut::BrollManifest`.

## Dependencies

Node ≥22 and FFmpeg. `npx hyperframes` must succeed. Use the **setup** skill to verify.
