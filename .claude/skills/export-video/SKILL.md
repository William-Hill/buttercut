---
name: export-video
description: Renders a roughcut YAML to a single playable MP4 using ffmpeg. Use when the user wants to preview a rough cut or sequence as a video file without importing the XML into a video editor.
---

# Skill: Export Video

Render a roughcut YAML to a playable MP4 by extracting each clip's in/out range from its source file and concatenating the segments.

## Prerequisites

- `ffmpeg` and `ffprobe` on PATH (Homebrew: `brew install ffmpeg`).
- A roughcut YAML at `libraries/[library-name]/roughcuts/[name].yaml` with a sibling `library.yaml` that resolves each clip's `source_file` to a full path.

## Run

```bash
ruby .claude/skills/export-video/export_video.rb <roughcut.yaml> [output.mp4]
```

If `output.mp4` is omitted, writes to `libraries/[library-name]/roughcuts/[roughcut-name]_preview_YYYYMMDD_HHMMSS.mp4`.

## Notes

- All clips are re-encoded to match the first clip's resolution and frame rate so cuts are frame-accurate and concatenation works across mixed sources. Mismatched aspect ratios are letter/pillarboxed.
- Uses H.264 `ultrafast` / CRF 23 for quick previews — not a delivery encode.
- After export, tell the user the output path so they can open it.
