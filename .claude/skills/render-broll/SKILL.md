---
name: render-broll
description: Renders one b-roll manifest entry to MP4 via Hyperframes. Use for swap-in-place re-renders after a manifest entry's content has been edited; the rough-cut export script auto-renders unrendered entries on its own.
---

# Skill: Render B-Roll (parent brief)

Takes one entry from a `broll.yaml` manifest plus the active library theme and produces an MP4 at `libraries/<library>/broll/<id>.mp4`. Idempotent — re-rendering an existing `<id>` overwrites the same MP4 path so timing/recipe/XML never change (the swap-in-place loop in `CLAUDE.md`).

`SKILL.md` is the parent's dispatch brief. The sub-agent's working prompt lives in `agent_prompt.md` — inline its contents when launching the Task agent. Don't pass `SKILL.md`.

## When to use

- **Swap-in-place** (primary): user watched the rough cut in their NLE and asked for a fix to one entry. Edit `content` in `<roughcut>.broll.yaml`, dispatch this skill on the changed entry, user reloads the project in their NLE.
- **Bulk pre-render** (rarely needed): the export script (`export_to_fcpxml.rb`) auto-renders entries whose `rendered` is empty or whose MP4 is missing. Use this skill explicitly only if you want renders to land before export, or if export was run with `--no-render` / `BUTTERCUT_SKIP_BROLL_RENDER=1`.

## Parallelism

Launch at most **2 in parallel**. Each Hyperframes render spawns a Chrome process plus FFmpeg; 2 keeps a 16GB Mac comfortable.

## Inputs to gather and pass inline

The parent reads the manifest (`libraries/<lib>/roughcuts/<id>.broll.yaml`) and the library's theme block, then for each entry passes inline:

- `entry` — the full manifest entry hash (id, template, content, start, end, …)
- `theme` — resolved theme tokens hash (currently just `{ "name": "tutorial-dark" }`)
- `output_dir` — `libraries/<library>/broll/`
- `hyperframes_dir` — absolute path to `hyperframes/` at the repo root

## After the agent returns

Update the manifest entry's `rendered` field to the returned relative path (e.g. `broll/br-0001.mp4`) and save the manifest via `ButterCut::BrollManifest`.

## Dependencies

Node ≥22 and FFmpeg. `npx hyperframes` must succeed. Use the **setup** skill to verify.
