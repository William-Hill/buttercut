---
name: transcribe-audio
description: Transcribes video audio using WhisperX, preserving original timestamps. Creates JSON transcript with word-level timing. Use when you need to generate audio transcripts for videos.
---

# Skill: Transcribe Audio

Transcribes video audio using WhisperX and creates clean JSON transcripts with word-level timing data. Includes LLM refinement to correct domain-specific terminology.

## When to Use
- Videos need audio transcripts before visual analysis

## Critical Requirements

Use WhisperX, NOT standard Whisper. WhisperX preserves the original video timeline including leading silence, ensuring transcripts match actual video timestamps. Run WhisperX directly on video files. Don't extract audio separately - this ensures timestamp alignment.

## Workflow

### 1. Read Settings and Library Context

Read `libraries/settings.yaml` to get the `whisper_model` value (defaults to `medium` if settings file is missing).

Read the library's `library.yaml` to get:
- `language` - map the value to an ISO 639-1 code ("English" → `en`, "Spanish" → `es`, "French" → `fr`, "German" → `de`, "Japanese" → `ja`; use the appropriate ISO 639-1 code for other languages)
- `footage_summary` - description of footage content (used in refinement step)
- `user_context` - user-provided context like names and terminology (used in refinement step)

### 2. Run WhisperX

```bash
whisperx "/full/path/to/video.mov" \
  --language [mapped language code] \
  --model [whisper_model from settings] \
  --compute_type float32 \
  --device cpu \
  --output_format json \
  --output_dir libraries/[library-name]/transcripts
```

### 3. Prepare Audio Transcript

After WhisperX completes, format the JSON using our prepare_audio_script:

```bash
ruby .claude/skills/transcribe-audio/prepare_audio_script.rb \
  libraries/[library-name]/transcripts/video_name.json \
  /full/path/to/original/video_name.mov
```

This script:
- Adds video source path as metadata
- Removes unnecessary fields to reduce file size
- Prettifies JSON

### 4. Refine Transcript with LLM Pass

The `small` WhisperX model is fast but makes mistakes on proper nouns, brand names, jargon, and uncommon words. Use Sonnet to identify and fix these errors using context from library.yaml.

**Skip this step if:**
- `footage_summary` is "No footage analyzed yet." AND `user_context` is empty
- Both fields lack domain-specific terms to guide corrections

**To refine:**

1. Read the transcript JSON file
2. Use the Task tool with `model: "sonnet"` to identify corrections:

```
You are reviewing an audio transcript from video footage for transcription errors.

CONTEXT:
{footage_summary}
{user_context}

Your task is to identify transcription errors caused by the speech-to-text model not understanding the subject matter, heavier accents, etc.

Common issues to find:
- Proper nouns (people, companies, products, places)
- Subject-specific terminology and jargon
- Acronyms and abbreviations spoken aloud
- Names that sound like common words

Return a JSON array of proposed corrections. Each correction should have:
- "original": the incorrectly transcribed word/phrase
- "corrected": what it should be
- "reason": brief explanation (e.g., "product name", "person's name", "technical term")

Example output:
[
  {"original": "tube salt", "corrected": "TubeSalt", "reason": "product name"},
  {"original": "butter cut", "corrected": "ButterCut", "reason": "product name"},
  {"original": "Andrew forward", "corrected": "Andrew Ford", "reason": "person's name"}
]

If no corrections are needed, return an empty array: []

Here is the transcript JSON to review:
{transcript_json}
```

3. If corrections are returned, apply them to the segment `text` fields in the transcript JSON and save
4. Log corrections applied in the success response for traceability

**Only modify segment `text` fields.** Do not touch timestamps, `words` arrays, or any other fields — those are used for edit point timing.

### 5. Return Success Response

After transcription and refinement completes, return this structured response to the parent agent:

```
✓ [video_filename.mov] transcribed successfully
  Audio transcript: libraries/[library-name]/transcripts/video_name.json
  Video path: /full/path/to/video_filename.mov
  Refined: yes (3 corrections: "tube salt"→"TubeSalt", "butter cut"→"ButterCut", "Andrew forward"→"Andrew Ford")
```

If refinement was skipped (no context available), report `Refined: no (no context available)`.

**DO NOT update library.yaml** - the parent agent will handle this to avoid race conditions when running multiple transcriptions in parallel.

## Running in Parallel

This skill is designed to run inside a Task agent for parallel execution:
- Each agent handles ONE video file
- Multiple agents can run simultaneously
- Parent thread updates library.yaml sequentially after each agent completes
- No race conditions on shared YAML file

## Next Step

After audio transcription, use the **analyze-video** skill to add visual descriptions and create the visual transcript.

## Installation

Ensure WhisperX is installed. Use the **setup** skill to verify dependencies.
