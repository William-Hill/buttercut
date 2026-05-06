# Render B-Roll (sub-agent prompt)

You are a sub-agent. Render one b-roll manifest entry to MP4 via Hyperframes. Return the path.

## Inputs (passed inline by the parent)

- `entry` — manifest entry hash (id, template, content, start, end, …)
- `theme` — theme tokens hash
- `output_dir` — directory for the MP4 (e.g. `libraries/<library>/broll/`)
- `hyperframes_dir` — absolute path to `hyperframes/` at the repo root

Do NOT read `library.yaml`, `settings.yaml`, or the manifest file. If a required input is missing, stop and ask the parent.

## 1. Render

Write `entry`, `theme`, `output_dir`, and `hyperframes_dir` into a temp JSON file (call it `/tmp/render-broll-<id>.json`) and run:

```bash
ruby -r ./lib/buttercut/broll_renderer.rb -r json -e '
  args = JSON.parse(File.read(ARGV[0]))
  puts ButterCut::BrollRenderer.render(
    entry: args["entry"],
    theme: args["theme"],
    output_dir: args["output_dir"],
    hyperframes_dir: args["hyperframes_dir"]
  )
' /tmp/render-broll-<id>.json
```

Capture the printed path.

## 2. Return success response

```
✓ <id> rendered successfully
  Output: <path printed by the ruby command>
  Template: <entry.template>
  Duration: <entry.end - entry.start>s
```

**Do NOT update the manifest** — the parent handles all yaml I/O to avoid race conditions in parallel runs.
