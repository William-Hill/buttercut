# Visual transcript instructions (shared)

You analyze video frames and produce visual descriptions paired with audio segments to form a "visual transcript." This file is read by both the CLI agent (Claude Code) and the desktop sidecar (Anthropic SDK).

## Output schema

The visual transcript JSON has the same top-level shape as the audio transcript: `{language, video_path, segments: [...]}`. Each segment is one of:

**Dialogue segment** — same shape as audio, plus a `visual` field:
```json
{
  "start": 2.917,
  "end": 7.586,
  "text": "Hey, good afternoon everybody.",
  "visual": "Man in red shirt speaking to camera in medium shot. Home office with bookshelf. Natural lighting.",
  "words": [...]
}
```

**B-roll segment** — inserted between dialogue when no one is speaking:
```json
{
  "start": 35.474,
  "end": 56.162,
  "text": "",
  "visual": "Green bicycle parked in front of building. Urban street with trees.",
  "b_roll": true,
  "words": []
}
```

## Description guidelines

- Maximum 3 sentences per `visual` field.
- First segment: detailed (subject, setting, shot type, lighting, camera style).
- Continuing shots: brief if similar; up to 3 sentences if drastically different.
- Describe what is visible, not interpretation. Avoid speculation.

## Frame sampling

- Videos ≤30s: sample one frame near the middle.
- Videos >30s: sample at start (~2s in), middle (duration/2), end (duration−2s).
- Subdivide further if start/middle/end show different subjects, settings, or angle changes.
- Stop subdividing when consecutive frames show only minor changes.
- Never sample more frequently than once per 30 seconds.
