# M3 — Transcript Editing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship inline word-level audio-transcript editing in the M1 footage browser, with three scopes (this clip / this library / trust globally), library-wide find/replace, and stable scroll across mutations.

**Architecture:** Three new Ruby classes in the sidecar (`TranscriptEditor`, `TranscriptFinder`, `LibraryReplacer`) hold all editing logic, mirroring the existing `refine_instructions.md` Step 5 rules but as deterministic code. Three new JSON-RPC methods + Tauri commands expose them to the React UI, where a `WordToken` + `EditPopover` + `FindReplacePanel` cluster integrate with the existing `TranscriptZone`. A `transcript_edited` notification triggers a refetch with a captured scroll anchor so the active clip's view stays still while a library-wide replace mutates it underneath.

**Tech Stack:** Tauri 2 / Rust, Ruby 3 (stdlib), React 19 + TS, plain CSS. Spec source: `docs/superpowers/specs/2026-05-03-m3-transcript-editing-design.md`. Branch: `sprint-02-m3-transcript-editing` (already cut, spec already committed).

**Working assumptions (from M2 precedent — confirmed by repo inspection):**
- TDD with RSpec for every new Ruby class. Specs live under `ui/sidecar/spec/lib/buttercut_ui_sidecar/`. Existing test pattern: `Dir.mktmpdir` + `LibraryFixture` (`ui/sidecar/spec/fixtures/library_fixture.rb`) + the integration helper in `ui/sidecar/spec/buttercut_ui_sidecar_spec.rb` that drives the dispatcher with StringIO.
- **No JS/TS test harness exists.** Frontend testing follows M0/M1/M2: manual smoke testing only. The spec called for React component tests for the popover; this plan instead extracts validation into a pure TS helper that is exercised by the manual smoke checklist. (Adding Vitest/Jest is out of scope.)
- Rust commands are smoke-tested manually as in M0/M1/M2.
- Keep main-thread context minimal: each task is self-contained with full code.

---

## Handoff briefing — read this if you're picking up a single task cold

Each task is self-contained. But the surrounding context an outside agent needs:

**Repo:** `buttercut` — Ruby gem for FCPXML/Resolve XML generation, with a Tauri 2 desktop UI in `ui/`. M3 adds inline transcript editing to the M1 library browser. M0 (#15), M1 (#17), M2 (#18) are merged on `main`.

**Stack invariants — do not change:**
- Tauri 2 + React 19 + plain CSS. No Tailwind, no component libraries.
- `@fontsource/eb-garamond` (italic display) + `@fontsource/jetbrains-mono` (technical metadata).
- Tungsten amber `#e0a55a` accent on dark stage `#14141a`.
- Local Ruby sidecar over JSON-RPC stdio. Ruby ≥ 3.
- Sidecar entrypoint: `ui/sidecar/buttercut_ui_sidecar.rb` (one class per file convention; `CLAUDE.md` "Programming Style").
- Rust shell: `ui/src-tauri/src/lib.rs` (commands) + `ui/src-tauri/src/sidecar.rs` (JSON-RPC reader/writer).

**Architectural decisions locked in by the spec:**
1. **Decision B from brainstorming** — "trust globally" appends to `library.yaml` `user_context` and applies a deterministic library-wide replace. **NO** Claude re-refinement of existing transcripts. Future analyses pick up the term automatically.
2. **Strict word-count rule** — 1→1 (popover) or N→N (find/replace) only. Splits/merges blocked client- and server-side. Squashing (`Sanjose` → `SanJose`) is the escape hatch.
3. **Three arrays kept consistent per edit** — `segments[].text`, `segments[].words[].word`, `word_segments[].word`. Atomic write under the existing transcript file (no partial writes).
4. **Scroll stability** — capture `(segment_index, word_index)` of the topmost visible word + viewport offset before mutation; restore after.
5. **One in-memory undo level per open clip.** Cleared on clip change.

**WhisperX transcript shape** (verified against `libraries/1stphorm-workout/transcripts/C0077.json`):
```json
{
  "language": "en",
  "video_path": "...",
  "segments": [
    {
      "start": 0.009,
      "end": 0.09,
      "text": " Yeah.",
      "words": [{ "word": "Yeah.", "start": 0.009, "end": 0.09 }]
    }
  ],
  "word_segments": [{ "word": "Yeah.", "start": 0.009, "end": 0.09 }]
}
```
Notes you'll need:
- `segments[].text` may have a leading space — preserve it.
- A "token" is whitespace-delimited; trailing punctuation (`Yeah.`) is part of the token. The editor never strips punctuation.
- Some transcripts have empty `segments: []` (silent clips). Editor must handle this without crashing.
- `word_segments` is a flat top-level array; some older transcripts may not have it. Editor must tolerate both shapes.

**Existing patterns to follow:**
- Ruby: one class per file; required args raise `ArgumentError` in `initialize`; expose entry method (`Klass.apply`/`Klass.find`); spec at mirrored path; `Dir.mktmpdir` + `LibraryFixture` for setup.
- Rust: every Tauri command is `async fn`, returns `Result<Value, String>`, delegates to `sidecar::call(...)`; register in the `tauri::generate_handler![...]` list.
- TypeScript: typed wrappers in `ui/src/ipc/sidecar.ts`; React components default-exported.

**Don't:** add Co-Authored-By or Claude attribution to commits; skip git hooks (`--no-verify`); use `git add .`/`git add -A` (be explicit); modify `lib/buttercut/` (gem core); touch `refine_instructions.md` (the agent skill keeps its own copy of the rules — a future cleanup may unify them, out of scope here).

**When stuck:** re-read the spec section that the task implements. If the spec doesn't cover it, leave a brief PR-description note rather than expanding scope.

---

## File Structure

### New Ruby files (sidecar)
```
ui/sidecar/lib/buttercut_ui_sidecar/
├── transcript_editor.rb        # single-clip atomic edit; enforces 3-array consistency + 1↔1/N↔N rule
├── transcript_finder.rb        # word-boundary search across one or all clips in a library
└── library_replacer.rb         # library-wide replace; orchestrates finder + editor; mutex-guarded; user_context append on trust=true

ui/sidecar/spec/lib/buttercut_ui_sidecar/
├── transcript_editor_spec.rb
├── transcript_finder_spec.rb
└── library_replacer_spec.rb
```

### Modified Ruby files
```
ui/sidecar/buttercut_ui_sidecar.rb   # 3 new dispatch cases, instantiate replacer, expose mutex
ui/sidecar/spec/buttercut_ui_sidecar_spec.rb   # 3 new integration test blocks
ui/sidecar/spec/fixtures/library_fixture.rb    # extend write_audio_transcript to accept full WhisperX shape
```

### Modified Rust files
```
ui/src-tauri/src/lib.rs   # 3 new Tauri commands + register in handler
```

### New TypeScript / React files
```
ui/src/routes/library/
├── editorTypes.ts          # shared types: TranscriptEditPayload, FinderMatch, ReplaceScope
├── tokenValidation.ts      # pure validation helper (1↔1 / N↔N enforcement)
├── WordToken.tsx           # replaces inline word <button>; pencil affordance + scrub click
├── EditPopover.tsx         # anchored popover: input + scope picker + match count + Replace
├── FindReplacePanel.tsx    # ⌘F floating panel
└── useTranscriptEditor.ts  # hook: edit dispatch, scroll anchor capture/restore, one-level undo
```

### Modified TypeScript / React files
```
ui/src/ipc/sidecar.ts                            # 3 new bindings + listenTranscriptEdited helper
ui/src/routes/library/TranscriptZone.tsx         # integrate WordToken, subscribe to transcript_edited, scroll anchor wiring
ui/src/routes/library/library.css                # popover, panel, pencil affordance, error states
```

---

## Phase 1 — TranscriptEditor (single-clip edits)

**Spec section:** "Architecture → Sidecar → TranscriptEditor"; "Word-count rule enforcement → Server"; spec also references the canonical examples from `refine_instructions.md`.

### Task 1: Extend LibraryFixture with WhisperX-shaped writer

Today `LibraryFixture.write_audio_transcript` writes a stripped-down `{ language, video_path, segments }` payload without `words[]` or `word_segments`. We need fixtures that look like real WhisperX output to test the three-array consistency.

**Files:**
- Modify: `ui/sidecar/spec/fixtures/library_fixture.rb`

- [ ] **Step 1: Add `write_whisperx_transcript` helper**

```ruby
# Append to ui/sidecar/spec/fixtures/library_fixture.rb (above the closing `end`):

  # Writes a transcript JSON with the full WhisperX shape: segments[].words[]
  # and a top-level word_segments[]. Each segment is provided as
  # { start:, end:, text:, words: [{word:, start:, end:}, ...] }.
  # word_segments is auto-derived as the flat concatenation of all words[].
  def self.write_whisperx_transcript(lib_dir, basename, segments:, language: "en")
    path = File.join(lib_dir, "transcripts", basename)
    word_segments = segments.flat_map { |s| s[:words] || [] }.map do |w|
      { "word" => w[:word], "start" => w[:start], "end" => w[:end] }
    end
    payload = {
      "language" => language,
      "video_path" => "n/a",
      "segments" => segments.map do |s|
        {
          "start" => s[:start],
          "end" => s[:end],
          "text" => s[:text],
          "words" => (s[:words] || []).map { |w| { "word" => w[:word], "start" => w[:start], "end" => w[:end] } }
        }
      end,
      "word_segments" => word_segments
    }
    File.write(path, JSON.pretty_generate(payload))
    path
  end
```

- [ ] **Step 2: Commit**

```bash
git add ui/sidecar/spec/fixtures/library_fixture.rb
git commit -m "M3: LibraryFixture.write_whisperx_transcript for full WhisperX shape"
```

### Task 2: Write failing TranscriptEditor specs

**Files:**
- Create: `ui/sidecar/spec/lib/buttercut_ui_sidecar/transcript_editor_spec.rb`

- [ ] **Step 1: Write the failing spec**

```ruby
# ui/sidecar/spec/lib/buttercut_ui_sidecar/transcript_editor_spec.rb
require "spec_helper"
require "json"
require "tmpdir"
require "fileutils"
require_relative "../../fixtures/library_fixture"
require_relative "../../../lib/buttercut_ui_sidecar/transcript_editor"

RSpec.describe ButtercutUiSidecar::TranscriptEditor do
  def with_lib
    Dir.mktmpdir do |root|
      lib_dir = LibraryFixture.build(root, name: "demo",
        videos: [{ path: "/x/a.mp4", transcript: "a.json" }])
      yield root, lib_dir
    end
  end

  def write_transcript(lib_dir)
    LibraryFixture.write_whisperx_transcript(lib_dir, "a.json", segments: [
      {
        start: 0.0, end: 1.5, text: " ride out to Walnut Creak for the weekend",
        words: [
          { word: "ride", start: 0.0, end: 0.2 },
          { word: "out", start: 0.21, end: 0.3 },
          { word: "to", start: 0.31, end: 0.4 },
          { word: "Walnut", start: 0.41, end: 0.7 },
          { word: "Creak", start: 0.71, end: 1.0 },
          { word: "for", start: 1.01, end: 1.1 },
          { word: "the", start: 1.11, end: 1.2 },
          { word: "weekend", start: 1.21, end: 1.5 }
        ]
      }
    ])
  end

  def read_transcript(lib_dir)
    JSON.parse(File.read(File.join(lib_dir, "transcripts", "a.json")))
  end

  describe ".apply" do
    it "applies a 1->1 spelling fix to all three arrays" do
      with_lib do |root, lib_dir|
        write_transcript(lib_dir)

        result = described_class.apply(
          libraries_root: root, library: "demo", clip: "a.json",
          edit: { segment_index: 0, word_index: 4, old_tokens: ["Creak"], new_tokens: ["Creek"] }
        )

        data = read_transcript(lib_dir)
        expect(data["segments"][0]["text"]).to eq(" ride out to Walnut Creek for the weekend")
        expect(data["segments"][0]["words"][4]["word"]).to eq("Creek")
        expect(data["segments"][0]["words"][4]["start"]).to eq(0.71) # timing untouched
        expect(data["word_segments"][4]["word"]).to eq("Creek")
        expect(result[:edit_count]).to eq(1)
      end
    end

    it "supports an N->N phrase fix" do
      with_lib do |root, lib_dir|
        LibraryFixture.write_whisperx_transcript(lib_dir, "a.json", segments: [
          {
            start: 0.0, end: 1.0, text: " hello dear world",
            words: [
              { word: "hello", start: 0.0, end: 0.3 },
              { word: "dear", start: 0.31, end: 0.6 },
              { word: "world", start: 0.61, end: 1.0 }
            ]
          }
        ])

        described_class.apply(
          libraries_root: root, library: "demo", clip: "a.json",
          edit: { segment_index: 0, word_index: 0, old_tokens: ["hello", "dear"], new_tokens: ["howdy", "friend"] }
        )

        data = read_transcript(lib_dir)
        expect(data["segments"][0]["text"]).to eq(" howdy friend world")
        expect(data["segments"][0]["words"].map { |w| w["word"] }).to eq(["howdy", "friend", "world"])
        expect(data["word_segments"].map { |w| w["word"] }).to eq(["howdy", "friend", "world"])
      end
    end

    it "preserves case character-for-character" do
      with_lib do |root, lib_dir|
        LibraryFixture.write_whisperx_transcript(lib_dir, "a.json", segments: [
          {
            start: 0.0, end: 0.5, text: " tundraloin neighborhood",
            words: [
              { word: "tundraloin", start: 0.0, end: 0.3 },
              { word: "neighborhood", start: 0.31, end: 0.5 }
            ]
          }
        ])

        described_class.apply(
          libraries_root: root, library: "demo", clip: "a.json",
          edit: { segment_index: 0, word_index: 0, old_tokens: ["tundraloin"], new_tokens: ["tenderloin"] }
        )

        data = read_transcript(lib_dir)
        expect(data["segments"][0]["text"]).to eq(" tenderloin neighborhood")
      end
    end

    it "raises TokenCountViolation when new_tokens length differs from old_tokens" do
      with_lib do |root, lib_dir|
        write_transcript(lib_dir)

        expect {
          described_class.apply(
            libraries_root: root, library: "demo", clip: "a.json",
            edit: { segment_index: 0, word_index: 4, old_tokens: ["Creak"], new_tokens: ["Walnut", "Creek"] }
          )
        }.to raise_error(ButtercutUiSidecar::TranscriptEditor::TokenCountViolation)

        # Disk unchanged
        expect(read_transcript(lib_dir)["segments"][0]["text"]).to eq(" ride out to Walnut Creak for the weekend")
      end
    end

    it "raises ArgumentError if old_tokens does not match the words at (segment_index, word_index)" do
      with_lib do |root, lib_dir|
        write_transcript(lib_dir)

        expect {
          described_class.apply(
            libraries_root: root, library: "demo", clip: "a.json",
            edit: { segment_index: 0, word_index: 4, old_tokens: ["Lake"], new_tokens: ["Pond"] }
          )
        }.to raise_error(ArgumentError, /old_tokens does not match/)
      end
    end

    it "writes atomically via tempfile + rename" do
      with_lib do |root, lib_dir|
        write_transcript(lib_dir)
        # Existence check: there must NOT be a leftover .tmp file after a successful edit
        described_class.apply(
          libraries_root: root, library: "demo", clip: "a.json",
          edit: { segment_index: 0, word_index: 4, old_tokens: ["Creak"], new_tokens: ["Creek"] }
        )
        expect(Dir.glob(File.join(lib_dir, "transcripts", "*.tmp"))).to be_empty
      end
    end

    it "tolerates transcripts without a top-level word_segments array" do
      with_lib do |root, lib_dir|
        # write a payload without word_segments
        path = File.join(lib_dir, "transcripts", "a.json")
        File.write(path, JSON.pretty_generate({
          "language" => "en", "video_path" => "n/a",
          "segments" => [
            {
              "start" => 0.0, "end" => 0.5, "text" => " ride out",
              "words" => [
                { "word" => "ride", "start" => 0.0, "end" => 0.2 },
                { "word" => "out", "start" => 0.21, "end" => 0.5 }
              ]
            }
          ]
        }))

        described_class.apply(
          libraries_root: root, library: "demo", clip: "a.json",
          edit: { segment_index: 0, word_index: 0, old_tokens: ["ride"], new_tokens: ["walk"] }
        )

        data = read_transcript(lib_dir)
        expect(data["segments"][0]["text"]).to eq(" walk out")
        expect(data["segments"][0]["words"][0]["word"]).to eq("walk")
        expect(data).not_to have_key("word_segments") # we don't synthesize one we didn't get
      end
    end
  end
end
```

- [ ] **Step 2: Run spec to verify it fails**

```bash
cd ui/sidecar && bundle exec rspec spec/lib/buttercut_ui_sidecar/transcript_editor_spec.rb
```
Expected: FAIL with "cannot load such file -- .../transcript_editor".

### Task 3: Implement TranscriptEditor

**Files:**
- Create: `ui/sidecar/lib/buttercut_ui_sidecar/transcript_editor.rb`

- [ ] **Step 1: Write the implementation**

```ruby
# ui/sidecar/lib/buttercut_ui_sidecar/transcript_editor.rb
# frozen_string_literal: true

require "json"
require "fileutils"
require "pathname"
require "tempfile"

module ButtercutUiSidecar
  # Applies a single-clip word-level edit to a WhisperX transcript JSON,
  # keeping segments[].text, segments[].words[].word, and word_segments[].word
  # consistent. Enforces the 1->1 / N->N word-count rule that downstream
  # timing depends on.
  class TranscriptEditor
    class TokenCountViolation < StandardError; end

    def self.apply(libraries_root:, library:, clip:, edit:)
      new(libraries_root: libraries_root, library: library, clip: clip, edit: edit).apply
    end

    def initialize(libraries_root:, library:, clip:, edit:)
      raise ArgumentError, "libraries_root required" if libraries_root.nil? || libraries_root.to_s.empty?
      raise ArgumentError, "library required" if library.nil? || library.to_s.empty?
      raise ArgumentError, "clip required" if clip.nil? || clip.to_s.empty?
      raise ArgumentError, "edit required" if edit.nil?
      raise ArgumentError, "old_tokens required" if edit[:old_tokens].nil? || edit[:old_tokens].empty?
      raise ArgumentError, "new_tokens required" if edit[:new_tokens].nil? || edit[:new_tokens].empty?

      @path = Pathname.new(libraries_root).join(library, "transcripts", clip)
      @segment_index = edit[:segment_index]
      @word_index = edit[:word_index]
      @old_tokens = edit[:old_tokens]
      @new_tokens = edit[:new_tokens]
    end

    def apply
      raise ArgumentError, "transcript not found: #{@path}" unless @path.file?
      if @new_tokens.length != @old_tokens.length
        raise TokenCountViolation,
              "new_tokens (#{@new_tokens.length}) != old_tokens (#{@old_tokens.length})"
      end

      data = JSON.parse(@path.read)
      segments = data["segments"] || []
      segment = segments[@segment_index] or raise ArgumentError, "segment_index out of range"
      words = segment["words"] || []
      slice = words[@word_index, @old_tokens.length] || []
      actual = slice.map { |w| w["word"] }
      unless actual == @old_tokens
        raise ArgumentError,
              "old_tokens does not match: expected #{@old_tokens.inspect}, found #{actual.inspect}"
      end

      apply_to_words(words)
      apply_to_segment_text(segment)
      apply_to_word_segments(data) if data["word_segments"]

      write_atomic(data)

      { edit_count: 1 }
    end

    private

    def apply_to_words(words)
      @new_tokens.each_with_index do |new_word, i|
        words[@word_index + i]["word"] = new_word
      end
    end

    # The segment's `text` is the space-joined view of its words. Replace the
    # exact phrase rather than the bare token to avoid the "carrot" trap
    # (substring matching corrupting unrelated occurrences).
    def apply_to_segment_text(segment)
      old_phrase = @old_tokens.join(" ")
      new_phrase = @new_tokens.join(" ")
      text = segment["text"].to_s
      idx = text.index(old_phrase)
      raise ArgumentError, "phrase not found in segment text: #{old_phrase.inspect}" if idx.nil?
      segment["text"] = text[0...idx] + new_phrase + text[(idx + old_phrase.length)..]
    end

    # The flat top-level word_segments array mirrors segments[].words[] in
    # document order. Find the matching window by token sequence + start time,
    # then update.
    def apply_to_word_segments(data)
      target_start = data["segments"][@segment_index]["words"][@word_index]["start"]
      flat = data["word_segments"]
      window = nil
      flat.each_with_index do |entry, i|
        next unless entry["start"] == target_start && entry["word"] == @new_tokens.first
        # First word already updated in-place via apply_to_words... but
        # word_segments is a separate array (entries are dup'd at write time).
        # So we need to match by start AND old token. Re-check with the original.
        window = i
        break
      end

      # If we didn't catch it via new_tokens.first (which we can't, because
      # apply_to_words mutated words[] not word_segments[]), fall back to
      # matching by start + old token.
      window = nil
      flat.each_with_index do |entry, i|
        if entry["start"] == target_start && entry["word"] == @old_tokens.first
          window = i
          break
        end
      end
      return if window.nil? # leave consistent enough; spec for finder catches drift

      @new_tokens.each_with_index do |new_word, i|
        flat[window + i]["word"] = new_word if flat[window + i]
      end
    end

    def write_atomic(data)
      dir = @path.dirname
      tmp = Tempfile.create(["transcript", ".tmp"], dir.to_s)
      begin
        tmp.write(JSON.pretty_generate(data))
        tmp.close
        File.rename(tmp.path, @path.to_s)
      rescue StandardError
        File.unlink(tmp.path) if File.exist?(tmp.path)
        raise
      end
    end
  end
end
```

- [ ] **Step 2: Run specs and verify they pass**

```bash
cd ui/sidecar && bundle exec rspec spec/lib/buttercut_ui_sidecar/transcript_editor_spec.rb
```
Expected: 7 examples, 0 failures.

- [ ] **Step 3: Commit**

```bash
git add ui/sidecar/lib/buttercut_ui_sidecar/transcript_editor.rb \
        ui/sidecar/spec/lib/buttercut_ui_sidecar/transcript_editor_spec.rb
git commit -m "M3: TranscriptEditor — atomic 1->1 / N->N word edits"
```

---

## Phase 2 — TranscriptFinder (word-boundary search)

**Spec section:** "Architecture → Sidecar → TranscriptFinder"; "Testing → TranscriptFinder".

### Task 4: Write failing TranscriptFinder specs

**Files:**
- Create: `ui/sidecar/spec/lib/buttercut_ui_sidecar/transcript_finder_spec.rb`

- [ ] **Step 1: Write the failing spec**

```ruby
# ui/sidecar/spec/lib/buttercut_ui_sidecar/transcript_finder_spec.rb
require "spec_helper"
require "tmpdir"
require_relative "../../fixtures/library_fixture"
require_relative "../../../lib/buttercut_ui_sidecar/transcript_finder"

RSpec.describe ButtercutUiSidecar::TranscriptFinder do
  def with_two_clip_lib
    Dir.mktmpdir do |root|
      lib_dir = LibraryFixture.build(root, name: "demo",
        videos: [
          { path: "/x/a.mp4", transcript: "a.json" },
          { path: "/x/b.mp4", transcript: "b.json" }
        ])
      LibraryFixture.write_whisperx_transcript(lib_dir, "a.json", segments: [
        {
          start: 0.0, end: 1.0, text: " I bought a Tenderlohn loaf",
          words: [
            { word: "I", start: 0.0, end: 0.05 },
            { word: "bought", start: 0.06, end: 0.3 },
            { word: "a", start: 0.31, end: 0.35 },
            { word: "Tenderlohn", start: 0.36, end: 0.7 },
            { word: "loaf", start: 0.71, end: 1.0 }
          ]
        }
      ])
      LibraryFixture.write_whisperx_transcript(lib_dir, "b.json", segments: [
        {
          start: 0.0, end: 0.8, text: " near Tenderlohn",
          words: [
            { word: "near", start: 0.0, end: 0.2 },
            { word: "Tenderlohn", start: 0.21, end: 0.8 }
          ]
        },
        {
          start: 1.0, end: 1.5, text: " a carrot cake",
          words: [
            { word: "a", start: 1.0, end: 1.05 },
            { word: "carrot", start: 1.06, end: 1.3 },
            { word: "cake", start: 1.31, end: 1.5 }
          ]
        }
      ])
      yield root, lib_dir
    end
  end

  describe ".find" do
    it "finds matches across multiple clips with clip filename, segment, and word index" do
      with_two_clip_lib do |root, _lib_dir|
        matches = described_class.find(libraries_root: root, library: "demo", tokens: ["Tenderlohn"], scope: :library)
        expect(matches.size).to eq(2)
        expect(matches.map { |m| m[:clip] }.sort).to eq(["a.json", "b.json"])
        a_match = matches.find { |m| m[:clip] == "a.json" }
        expect(a_match[:segment_index]).to eq(0)
        expect(a_match[:word_index]).to eq(3)
      end
    end

    it "is case-insensitive in matching but returns the actual cased token slice" do
      with_two_clip_lib do |root, _lib_dir|
        matches = described_class.find(libraries_root: root, library: "demo", tokens: ["tenderlohn"], scope: :library)
        expect(matches.size).to eq(2)
        expect(matches.first[:matched_tokens]).to eq(["Tenderlohn"])
      end
    end

    it "matches whole tokens only — NOT substrings (the `car` -> `carrot` trap)" do
      with_two_clip_lib do |root, _lib_dir|
        matches = described_class.find(libraries_root: root, library: "demo", tokens: ["car"], scope: :library)
        expect(matches).to be_empty
      end
    end

    it "supports clip-scoped search" do
      with_two_clip_lib do |root, _lib_dir|
        matches = described_class.find(libraries_root: root, library: "demo", tokens: ["Tenderlohn"], scope: :clip, clip: "a.json")
        expect(matches.size).to eq(1)
        expect(matches.first[:clip]).to eq("a.json")
      end
    end

    it "supports N-token phrase search" do
      with_two_clip_lib do |root, _lib_dir|
        matches = described_class.find(libraries_root: root, library: "demo", tokens: ["a", "carrot"], scope: :library)
        expect(matches.size).to eq(1)
        expect(matches.first[:clip]).to eq("b.json")
        expect(matches.first[:segment_index]).to eq(1)
        expect(matches.first[:word_index]).to eq(0)
      end
    end

    it "returns context_snippet with surrounding words" do
      with_two_clip_lib do |root, _lib_dir|
        matches = described_class.find(libraries_root: root, library: "demo", tokens: ["Tenderlohn"], scope: :library)
        a = matches.find { |m| m[:clip] == "a.json" }
        expect(a[:context_snippet]).to include("Tenderlohn")
        expect(a[:context_snippet]).to include("bought") # surrounding context
      end
    end
  end
end
```

- [ ] **Step 2: Run spec to verify it fails**

```bash
cd ui/sidecar && bundle exec rspec spec/lib/buttercut_ui_sidecar/transcript_finder_spec.rb
```
Expected: FAIL with "cannot load such file".

### Task 5: Implement TranscriptFinder

**Files:**
- Create: `ui/sidecar/lib/buttercut_ui_sidecar/transcript_finder.rb`

- [ ] **Step 1: Write the implementation**

```ruby
# ui/sidecar/lib/buttercut_ui_sidecar/transcript_finder.rb
# frozen_string_literal: true

require "json"
require "pathname"
require "yaml"

module ButtercutUiSidecar
  # Searches WhisperX transcripts for a token sequence using whole-token
  # matching. Returns each match with the clip filename, segment index,
  # word index, the actual cased token slice, and a short surrounding-context
  # snippet for the UI.
  #
  # Whole-token (NOT substring) matching is load-bearing: searching `car`
  # MUST NOT match `carrot`. Comparison is case-insensitive on input, but the
  # returned :matched_tokens preserves the actual case from the transcript.
  class TranscriptFinder
    CONTEXT_WORDS = 4 # words on either side of the match

    def self.find(libraries_root:, library:, tokens:, scope:, clip: nil)
      new(libraries_root: libraries_root, library: library, tokens: tokens, scope: scope, clip: clip).find
    end

    def initialize(libraries_root:, library:, tokens:, scope:, clip:)
      raise ArgumentError, "libraries_root required" if libraries_root.nil? || libraries_root.to_s.empty?
      raise ArgumentError, "library required" if library.nil? || library.to_s.empty?
      raise ArgumentError, "tokens required" if tokens.nil? || tokens.empty?
      raise ArgumentError, "scope must be :clip or :library" unless %i[clip library].include?(scope)
      raise ArgumentError, "clip required when scope=:clip" if scope == :clip && (clip.nil? || clip.empty?)

      @lib_dir = Pathname.new(libraries_root).join(library)
      @tokens_lc = tokens.map { |t| t.downcase }
      @scope = scope
      @clip = clip
    end

    def find
      transcripts.flat_map { |path| matches_in(path) }
    end

    private

    def transcripts
      if @scope == :clip
        [@lib_dir.join("transcripts", @clip)]
      else
        clip_filenames_from_yaml.map { |c| @lib_dir.join("transcripts", c) }
      end.select(&:file?)
    end

    def clip_filenames_from_yaml
      yaml_path = @lib_dir.join("library.yaml")
      return [] unless yaml_path.file?
      data = YAML.safe_load(yaml_path.read, permitted_classes: [Date, Time], aliases: true) || {}
      (data["videos"] || []).filter_map { |v| v["transcript"] if v["transcript"] && !v["transcript"].to_s.empty? }
    end

    def matches_in(path)
      data = JSON.parse(path.read)
      clip = path.basename.to_s
      results = []
      (data["segments"] || []).each_with_index do |segment, seg_idx|
        words = segment["words"] || []
        next if words.length < @tokens_lc.length
        words.each_with_index do |_, word_idx|
          window = words[word_idx, @tokens_lc.length]
          window_lc = window.map { |w| w["word"].to_s.downcase }
          next unless window_lc == @tokens_lc

          results << {
            clip: clip,
            segment_index: seg_idx,
            word_index: word_idx,
            matched_tokens: window.map { |w| w["word"] },
            context_snippet: snippet(words, word_idx, @tokens_lc.length)
          }
        end
      end
      results
    end

    def snippet(words, start, length)
      from = [start - CONTEXT_WORDS, 0].max
      to = [start + length + CONTEXT_WORDS, words.length].min
      words[from...to].map { |w| w["word"] }.join(" ")
    end
  end
end
```

- [ ] **Step 2: Run specs and verify they pass**

```bash
cd ui/sidecar && bundle exec rspec spec/lib/buttercut_ui_sidecar/transcript_finder_spec.rb
```
Expected: 6 examples, 0 failures.

- [ ] **Step 3: Commit**

```bash
git add ui/sidecar/lib/buttercut_ui_sidecar/transcript_finder.rb \
        ui/sidecar/spec/lib/buttercut_ui_sidecar/transcript_finder_spec.rb
git commit -m "M3: TranscriptFinder — whole-token cross-clip search"
```

---

## Phase 3 — LibraryReplacer (orchestrator)

**Spec section:** "Architecture → Sidecar → LibraryReplacer"; "UX flow → Library-wide replace / Trust globally"; "Error handling → match_count_drift".

### Task 6: Write failing LibraryReplacer specs

**Files:**
- Create: `ui/sidecar/spec/lib/buttercut_ui_sidecar/library_replacer_spec.rb`

- [ ] **Step 1: Write the failing spec**

```ruby
# ui/sidecar/spec/lib/buttercut_ui_sidecar/library_replacer_spec.rb
require "spec_helper"
require "stringio"
require "tmpdir"
require "yaml"
require_relative "../../fixtures/library_fixture"
require_relative "../../../lib/buttercut_ui_sidecar/notifier"
require_relative "../../../lib/buttercut_ui_sidecar/library_replacer"

RSpec.describe ButtercutUiSidecar::LibraryReplacer do
  def with_lib(user_context: "")
    Dir.mktmpdir do |root|
      lib_dir = LibraryFixture.build(root, name: "demo",
        videos: [
          { path: "/x/a.mp4", transcript: "a.json" },
          { path: "/x/b.mp4", transcript: "b.json" }
        ])

      yaml_path = File.join(lib_dir, "library.yaml")
      data = YAML.safe_load(File.read(yaml_path)) || {}
      data["user_context"] = user_context
      File.write(yaml_path, YAML.dump(data))

      LibraryFixture.write_whisperx_transcript(lib_dir, "a.json", segments: [
        { start: 0.0, end: 0.5, text: " near Tenderlohn",
          words: [
            { word: "near", start: 0.0, end: 0.2 },
            { word: "Tenderlohn", start: 0.21, end: 0.5 }
          ] }
      ])
      LibraryFixture.write_whisperx_transcript(lib_dir, "b.json", segments: [
        { start: 0.0, end: 0.7, text: " over by Tenderlohn area",
          words: [
            { word: "over", start: 0.0, end: 0.1 },
            { word: "by", start: 0.11, end: 0.2 },
            { word: "Tenderlohn", start: 0.21, end: 0.5 },
            { word: "area", start: 0.51, end: 0.7 }
          ] }
      ])

      yield root, lib_dir
    end
  end

  let(:io) { StringIO.new }
  let(:notifier) { ButtercutUiSidecar::Notifier.new(io: io) }

  describe ".apply" do
    it "replaces all matches across clips and returns affected clip count" do
      with_lib do |root, lib_dir|
        result = described_class.apply(
          libraries_root: root, library: "demo",
          old_tokens: ["Tenderlohn"], new_tokens: ["Tenderloin"], trust: false,
          notifier: notifier
        )

        expect(result[:edit_count]).to eq(2)
        expect(result[:affected_clips]).to contain_exactly("a.json", "b.json")

        a = JSON.parse(File.read(File.join(lib_dir, "transcripts", "a.json")))
        b = JSON.parse(File.read(File.join(lib_dir, "transcripts", "b.json")))
        expect(a["segments"][0]["text"]).to eq(" near Tenderloin")
        expect(b["segments"][0]["text"]).to eq(" over by Tenderloin area")
      end
    end

    it "emits a transcript_edited notification per affected clip" do
      with_lib do |root, _lib_dir|
        described_class.apply(
          libraries_root: root, library: "demo",
          old_tokens: ["Tenderlohn"], new_tokens: ["Tenderloin"], trust: false,
          notifier: notifier
        )

        lines = io.string.lines.map { |l| JSON.parse(l) }
        edited = lines.select { |l| l["method"] == "transcript_edited" }
        expect(edited.size).to eq(2)
        expect(edited.map { |n| n.dig("params", "clip") }.sort).to eq(["a.json", "b.json"])
        expect(edited.first.dig("params", "library")).to eq("demo")
        expect(edited.first.dig("params", "edit_count")).to eq(1)
      end
    end

    it "appends to user_context when trust=true (idempotent)" do
      with_lib do |root, lib_dir|
        described_class.apply(
          libraries_root: root, library: "demo",
          old_tokens: ["Tenderlohn"], new_tokens: ["Tenderloin"], trust: true,
          notifier: notifier
        )

        yaml = YAML.safe_load(File.read(File.join(lib_dir, "library.yaml")))
        expect(yaml["user_context"]).to include("Tenderloin")

        # Idempotent: second call doesn't double-append.
        described_class.apply(
          libraries_root: root, library: "demo",
          old_tokens: ["Tenderloin"], new_tokens: ["Tenderloin"], trust: true,
          notifier: notifier
        )

        yaml2 = YAML.safe_load(File.read(File.join(lib_dir, "library.yaml")))
        expect(yaml2["user_context"].scan("Tenderloin").size).to eq(1)
      end
    end

    it "does NOT touch user_context when trust=false even if matches replaced" do
      with_lib(user_context: "existing context") do |root, lib_dir|
        described_class.apply(
          libraries_root: root, library: "demo",
          old_tokens: ["Tenderlohn"], new_tokens: ["Tenderloin"], trust: false,
          notifier: notifier
        )

        yaml = YAML.safe_load(File.read(File.join(lib_dir, "library.yaml")))
        expect(yaml["user_context"]).to eq("existing context")
      end
    end

    it "uses a single mutex acquisition for the whole walk" do
      with_lib do |root, _lib_dir|
        mutex = Mutex.new
        acquired = 0
        allow(mutex).to receive(:synchronize).and_wrap_original do |orig, &blk|
          acquired += 1
          orig.call(&blk)
        end

        described_class.apply(
          libraries_root: root, library: "demo",
          old_tokens: ["Tenderlohn"], new_tokens: ["Tenderloin"], trust: false,
          notifier: notifier, mutex: mutex
        )

        expect(acquired).to eq(1)
      end
    end

    it "returns edit_count=0 when there are no matches" do
      with_lib do |root, _lib_dir|
        result = described_class.apply(
          libraries_root: root, library: "demo",
          old_tokens: ["Pleasanton"], new_tokens: ["Pleasanton"], trust: false,
          notifier: notifier
        )
        expect(result[:edit_count]).to eq(0)
        expect(result[:affected_clips]).to be_empty
      end
    end
  end
end
```

- [ ] **Step 2: Run spec to verify it fails**

```bash
cd ui/sidecar && bundle exec rspec spec/lib/buttercut_ui_sidecar/library_replacer_spec.rb
```
Expected: FAIL with "cannot load such file -- .../library_replacer".

### Task 7: Implement LibraryReplacer

**Files:**
- Create: `ui/sidecar/lib/buttercut_ui_sidecar/library_replacer.rb`

- [ ] **Step 1: Write the implementation**

```ruby
# ui/sidecar/lib/buttercut_ui_sidecar/library_replacer.rb
# frozen_string_literal: true

require "json"
require "pathname"
require "yaml"

require_relative "transcript_editor"
require_relative "transcript_finder"

module ButtercutUiSidecar
  # Library-wide replace orchestrator. Drives TranscriptFinder + TranscriptEditor
  # across every clip in a library under a single mutex acquisition. When
  # trust=true, idempotently appends new_tokens.join(" ") to library.yaml's
  # user_context. Emits one `transcript_edited` notification per affected clip.
  class LibraryReplacer
    def self.apply(libraries_root:, library:, old_tokens:, new_tokens:, trust:, notifier:, mutex: Mutex.new)
      new(
        libraries_root: libraries_root, library: library,
        old_tokens: old_tokens, new_tokens: new_tokens,
        trust: trust, notifier: notifier, mutex: mutex
      ).apply
    end

    def initialize(libraries_root:, library:, old_tokens:, new_tokens:, trust:, notifier:, mutex:)
      raise ArgumentError, "libraries_root required" if libraries_root.nil? || libraries_root.to_s.empty?
      raise ArgumentError, "library required" if library.nil? || library.to_s.empty?
      raise ArgumentError, "old_tokens required" if old_tokens.nil? || old_tokens.empty?
      raise ArgumentError, "new_tokens required" if new_tokens.nil? || new_tokens.empty?
      if old_tokens.length != new_tokens.length
        raise TranscriptEditor::TokenCountViolation,
              "new_tokens (#{new_tokens.length}) != old_tokens (#{old_tokens.length})"
      end

      @libraries_root = libraries_root
      @library = library
      @old_tokens = old_tokens
      @new_tokens = new_tokens
      @trust = trust
      @notifier = notifier
      @mutex = mutex
    end

    def apply
      @mutex.synchronize do
        matches = TranscriptFinder.find(
          libraries_root: @libraries_root, library: @library,
          tokens: @old_tokens, scope: :library
        )

        per_clip = matches.group_by { |m| m[:clip] }
        affected_clips = []
        edit_count = 0

        per_clip.each do |clip, clip_matches|
          # Apply right-to-left within a clip so word_index values stay valid
          # across multiple edits in the same segment.
          clip_matches.sort_by { |m| [-m[:segment_index], -m[:word_index]] }.each do |m|
            TranscriptEditor.apply(
              libraries_root: @libraries_root, library: @library, clip: clip,
              edit: {
                segment_index: m[:segment_index],
                word_index: m[:word_index],
                old_tokens: @old_tokens,
                new_tokens: @new_tokens
              }
            )
            edit_count += 1
          end

          affected_clips << clip
          @notifier.notify("transcript_edited",
            library: @library, clip: clip, edit_count: clip_matches.size)
        end

        append_to_user_context if @trust && edit_count > 0

        { edit_count: edit_count, affected_clips: affected_clips }
      end
    end

    private

    def append_to_user_context
      yaml_path = Pathname.new(@libraries_root).join(@library, "library.yaml")
      return unless yaml_path.file?

      data = YAML.safe_load(yaml_path.read, permitted_classes: [Date, Time], aliases: true) || {}
      term = @new_tokens.join(" ")
      existing = (data["user_context"] || "").to_s
      return if existing.downcase.split(/\W+/).include?(term.downcase)

      data["user_context"] = existing.empty? ? term : "#{existing}\n#{term}"
      yaml_path.write(YAML.dump(data))
    end
  end
end
```

- [ ] **Step 2: Run specs and verify they pass**

```bash
cd ui/sidecar && bundle exec rspec spec/lib/buttercut_ui_sidecar/library_replacer_spec.rb
```
Expected: 6 examples, 0 failures.

- [ ] **Step 3: Commit**

```bash
git add ui/sidecar/lib/buttercut_ui_sidecar/library_replacer.rb \
        ui/sidecar/spec/lib/buttercut_ui_sidecar/library_replacer_spec.rb
git commit -m "M3: LibraryReplacer — library-wide replace with trust=true user_context append"
```

---

## Phase 4 — Sidecar dispatcher integration

**Spec section:** "Architecture → New IPC commands"; "Error handling → token_count_violation, not_found".

### Task 8: Add three new RPC dispatch cases + integration specs

**Files:**
- Modify: `ui/sidecar/buttercut_ui_sidecar.rb`
- Modify: `ui/sidecar/spec/buttercut_ui_sidecar_spec.rb`

- [ ] **Step 1: Write failing integration specs**

Append the following block to `ui/sidecar/spec/buttercut_ui_sidecar_spec.rb` (just before the final `end`):

```ruby
  describe "apply_transcript_edit" do
    it "applies a 1->1 edit and returns edit_count" do
      Dir.mktmpdir do |root|
        lib_dir = LibraryFixture.build(root, name: "demo",
          videos: [{ path: "/x/a.mp4", transcript: "a.json" }])
        LibraryFixture.write_whisperx_transcript(lib_dir, "a.json", segments: [
          { start: 0.0, end: 0.5, text: " hi Tenderlohn",
            words: [
              { word: "hi", start: 0.0, end: 0.1 },
              { word: "Tenderlohn", start: 0.11, end: 0.5 }
            ] }
        ])

        result = call(root, "apply_transcript_edit", {
          library: "demo", clip: "a.json",
          edit: { segment_index: 0, word_index: 1, old_tokens: ["Tenderlohn"], new_tokens: ["Tenderloin"] }
        })
        expect(result["error"]).to be_nil
        expect(result["result"]["edit_count"]).to eq(1)
      end
    end

    it "returns RPC error code -32013 token_count_violation on bad edit" do
      Dir.mktmpdir do |root|
        lib_dir = LibraryFixture.build(root, name: "demo",
          videos: [{ path: "/x/a.mp4", transcript: "a.json" }])
        LibraryFixture.write_whisperx_transcript(lib_dir, "a.json", segments: [
          { start: 0.0, end: 0.5, text: " hi there",
            words: [
              { word: "hi", start: 0.0, end: 0.1 },
              { word: "there", start: 0.11, end: 0.5 }
            ] }
        ])

        result = call(root, "apply_transcript_edit", {
          library: "demo", clip: "a.json",
          edit: { segment_index: 0, word_index: 0, old_tokens: ["hi"], new_tokens: ["hi", "there"] }
        })
        expect(result["error"]["code"]).to eq(-32013)
        expect(result["error"]["message"]).to match(/token_count_violation/)
      end
    end
  end

  describe "find_transcript_matches" do
    it "returns library-wide matches" do
      Dir.mktmpdir do |root|
        lib_dir = LibraryFixture.build(root, name: "demo",
          videos: [{ path: "/x/a.mp4", transcript: "a.json" }])
        LibraryFixture.write_whisperx_transcript(lib_dir, "a.json", segments: [
          { start: 0.0, end: 0.3, text: " hi Tenderlohn",
            words: [
              { word: "hi", start: 0.0, end: 0.1 },
              { word: "Tenderlohn", start: 0.11, end: 0.3 }
            ] }
        ])

        result = call(root, "find_transcript_matches", {
          library: "demo", tokens: ["Tenderlohn"], scope: "library"
        })["result"]
        expect(result["matches"].length).to eq(1)
        expect(result["matches"].first["clip"]).to eq("a.json")
      end
    end
  end

  describe "apply_library_replace" do
    it "replaces matches across the library and returns counts" do
      Dir.mktmpdir do |root|
        lib_dir = LibraryFixture.build(root, name: "demo",
          videos: [{ path: "/x/a.mp4", transcript: "a.json" }])
        LibraryFixture.write_whisperx_transcript(lib_dir, "a.json", segments: [
          { start: 0.0, end: 0.3, text: " hi Tenderlohn",
            words: [
              { word: "hi", start: 0.0, end: 0.1 },
              { word: "Tenderlohn", start: 0.11, end: 0.3 }
            ] }
        ])

        result = call(root, "apply_library_replace", {
          library: "demo", old_tokens: ["Tenderlohn"], new_tokens: ["Tenderloin"], trust: true
        })["result"]
        expect(result["edit_count"]).to eq(1)
        expect(result["affected_clips"]).to eq(["a.json"])

        yaml = YAML.safe_load(File.read(File.join(lib_dir, "library.yaml")))
        expect(yaml["user_context"]).to include("Tenderloin")
      end
    end
  end
```

- [ ] **Step 2: Run specs to verify they fail**

```bash
cd ui/sidecar && bundle exec rspec spec/buttercut_ui_sidecar_spec.rb
```
Expected: 5 new failures with "unknown method".

- [ ] **Step 3: Wire the dispatcher**

Edit `ui/sidecar/buttercut_ui_sidecar.rb`:

Add these two `require_relative` lines after the existing `require_relative "lib/buttercut_ui_sidecar/analysis_controller"` line:

```ruby
require_relative "lib/buttercut_ui_sidecar/transcript_editor"
require_relative "lib/buttercut_ui_sidecar/transcript_finder"
require_relative "lib/buttercut_ui_sidecar/library_replacer"
```

Then in `Dispatcher#initialize`, add a mutex for transcript edits (after `@registry = ...`):

```ruby
      @transcript_mutex = Mutex.new
```

Then in `Dispatcher#dispatch`, add three new `when` clauses inside the existing `case method` block, before the `else raise UnknownMethod, ...` line:

```ruby
      when "apply_transcript_edit"
        edit = symbolize_edit(params.fetch("edit"))
        ButtercutUiSidecar::TranscriptEditor.apply(
          libraries_root: @libraries_root.to_s,
          library: params.fetch("library"),
          clip: params.fetch("clip"),
          edit: edit
        )
      when "find_transcript_matches"
        matches = ButtercutUiSidecar::TranscriptFinder.find(
          libraries_root: @libraries_root.to_s,
          library: params.fetch("library"),
          tokens: params.fetch("tokens"),
          scope: params.fetch("scope").to_sym,
          clip: params["clip"]
        )
        { matches: matches }
      when "apply_library_replace"
        ButtercutUiSidecar::LibraryReplacer.apply(
          libraries_root: @libraries_root.to_s,
          library: params.fetch("library"),
          old_tokens: params.fetch("old_tokens"),
          new_tokens: params.fetch("new_tokens"),
          trust: params.fetch("trust"),
          notifier: @notifier,
          mutex: @transcript_mutex
        )
```

Then add a private helper at the bottom of `Dispatcher` (before `class UnknownMethod`):

```ruby
    def symbolize_edit(edit)
      {
        segment_index: edit.fetch("segment_index"),
        word_index: edit.fetch("word_index"),
        old_tokens: edit.fetch("old_tokens"),
        new_tokens: edit.fetch("new_tokens")
      }
    end
```

Then in `Dispatcher#handle_line`'s rescue chain, map the new error to a specific RPC code. Add a rescue clause for `ButtercutUiSidecar::TranscriptEditor::TokenCountViolation` BEFORE the generic `rescue StandardError => e`:

```ruby
    rescue ButtercutUiSidecar::TranscriptEditor::TokenCountViolation => e
      respond_error(id: id, code: -32013, message: "token_count_violation: #{e.message}")
```

- [ ] **Step 4: Run specs and verify they pass**

```bash
cd ui/sidecar && bundle exec rspec spec/buttercut_ui_sidecar_spec.rb
```
Expected: all specs pass (existing + 5 new).

- [ ] **Step 5: Commit**

```bash
git add ui/sidecar/buttercut_ui_sidecar.rb \
        ui/sidecar/spec/buttercut_ui_sidecar_spec.rb
git commit -m "M3: dispatch apply_transcript_edit, find_transcript_matches, apply_library_replace"
```

---

## Phase 5 — Rust Tauri commands

**Spec section:** "Architecture → New IPC commands".

### Task 9: Add three Tauri commands

**Files:**
- Modify: `ui/src-tauri/src/lib.rs`

- [ ] **Step 1: Add commands**

Insert these three command functions after the existing `cancel_job` definition (around line 101 in `ui/src-tauri/src/lib.rs`):

```rust
#[tauri::command]
async fn apply_transcript_edit(library: String, clip: String, edit: Value) -> Result<Value, String> {
    sidecar::call(
        "apply_transcript_edit",
        json!({ "library": library, "clip": clip, "edit": edit }),
    )
    .await
    .map_err(|e| e.to_string())
}

#[tauri::command]
async fn find_transcript_matches(
    library: String,
    tokens: Vec<String>,
    scope: String,
    clip: Option<String>,
) -> Result<Value, String> {
    sidecar::call(
        "find_transcript_matches",
        json!({ "library": library, "tokens": tokens, "scope": scope, "clip": clip }),
    )
    .await
    .map_err(|e| e.to_string())
}

#[tauri::command]
async fn apply_library_replace(
    library: String,
    old_tokens: Vec<String>,
    new_tokens: Vec<String>,
    trust: bool,
) -> Result<Value, String> {
    sidecar::call(
        "apply_library_replace",
        json!({
            "library": library,
            "old_tokens": old_tokens,
            "new_tokens": new_tokens,
            "trust": trust
        }),
    )
    .await
    .map_err(|e| e.to_string())
}
```

- [ ] **Step 2: Register commands in the handler list**

In the `tauri::generate_handler![...]` macro inside `run()`, add the three new command names. After `cancel_job` add a comma and:

```rust
            apply_transcript_edit,
            find_transcript_matches,
            apply_library_replace
```

(The existing list ends with `cancel_job` and no trailing comma; replace `cancel_job` with `cancel_job,` and add the three new entries above without a trailing comma after the last one.)

- [ ] **Step 3: Build the Tauri app to verify compilation**

```bash
cd ui && pnpm tauri build --no-bundle
```
Expected: Rust compilation succeeds (warnings about unused symbols from sidecar.rs are fine).

If `pnpm tauri build` is too heavy locally, alternatively run just the Rust check:

```bash
cd ui/src-tauri && cargo check
```
Expected: 0 errors.

- [ ] **Step 4: Commit**

```bash
git add ui/src-tauri/src/lib.rs
git commit -m "M3: Tauri commands for apply_transcript_edit, find_transcript_matches, apply_library_replace"
```

---

## Phase 6 — Frontend types and IPC bindings

**Spec section:** "Architecture → Frontend → editorTypes.ts; Modified → ui/src/ipc/sidecar.ts".

### Task 10: Add editor types

**Files:**
- Create: `ui/src/routes/library/editorTypes.ts`

- [ ] **Step 1: Write the file**

```ts
// ui/src/routes/library/editorTypes.ts

export type ReplaceScope = "clip" | "library" | "trust";

export interface TranscriptEdit {
  segment_index: number;
  word_index: number;
  old_tokens: string[];
  new_tokens: string[];
}

export interface FinderMatch {
  clip: string;
  segment_index: number;
  word_index: number;
  matched_tokens: string[];
  context_snippet: string;
}

export interface FinderResult {
  matches: FinderMatch[];
}

export interface ApplyEditResult {
  edit_count: number;
}

export interface ApplyLibraryReplaceResult {
  edit_count: number;
  affected_clips: string[];
}

export interface TranscriptEditedEvent {
  library: string;
  clip: string;
  edit_count: number;
}

// One-level undo entry. Stored in memory; cleared on clip change.
export interface UndoEntry {
  scope: ReplaceScope;
  // For clip scope: the inverse edit. For library/trust: the reverse replace
  // payload, plus whether to remove the term from user_context (only true if
  // the trust=true edit was the one that ADDED the term).
  inverse_edit?: TranscriptEdit & { clip: string };
  inverse_replace?: { old_tokens: string[]; new_tokens: string[]; remove_user_context_term: string | null };
}
```

- [ ] **Step 2: Commit**

```bash
git add ui/src/routes/library/editorTypes.ts
git commit -m "M3: editor types"
```

### Task 11: Add sidecar IPC bindings + transcript_edited event helper

**Files:**
- Modify: `ui/src/ipc/sidecar.ts`

- [ ] **Step 1: Append three new IPC bindings + a listener helper**

Add at the bottom of `ui/src/ipc/sidecar.ts`:

```ts
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import type {
  TranscriptEdit,
  FinderResult,
  ApplyEditResult,
  ApplyLibraryReplaceResult,
  TranscriptEditedEvent,
} from "../routes/library/editorTypes";

export async function applyTranscriptEdit(
  library: string,
  clip: string,
  edit: TranscriptEdit
): Promise<ApplyEditResult> {
  return invoke<ApplyEditResult>("apply_transcript_edit", { library, clip, edit });
}

export async function findTranscriptMatches(
  library: string,
  tokens: string[],
  scope: "clip" | "library",
  clip?: string
): Promise<FinderResult> {
  return invoke<FinderResult>("find_transcript_matches", { library, tokens, scope, clip });
}

export async function applyLibraryReplace(
  library: string,
  oldTokens: string[],
  newTokens: string[],
  trust: boolean
): Promise<ApplyLibraryReplaceResult> {
  return invoke<ApplyLibraryReplaceResult>("apply_library_replace", {
    library,
    oldTokens,
    newTokens,
    trust,
  });
}

// Listens for sidecar `transcript_edited` notifications. The notification
// arrives on the global "sidecar-event" channel (no job_id). Caller must
// filter by (library, clip).
export async function listenTranscriptEdited(
  handler: (e: TranscriptEditedEvent) => void
): Promise<UnlistenFn> {
  return listen<{ method: string; params: TranscriptEditedEvent }>(
    "sidecar-event",
    (event) => {
      if (event.payload.method === "transcript_edited") {
        handler(event.payload.params);
      }
    }
  );
}
```

- [ ] **Step 2: TypeScript-check**

```bash
cd ui && pnpm tsc --noEmit
```
Expected: 0 errors.

- [ ] **Step 3: Commit**

```bash
git add ui/src/ipc/sidecar.ts
git commit -m "M3: TS IPC bindings + listenTranscriptEdited helper"
```

---

## Phase 7 — Validation helper, WordToken, hook

**Spec section:** "Architecture → Frontend"; "Word-count rule enforcement → Client".

### Task 12: Token validation helper

**Files:**
- Create: `ui/src/routes/library/tokenValidation.ts`

- [ ] **Step 1: Write the file**

```ts
// ui/src/routes/library/tokenValidation.ts

export interface ValidationResult {
  valid: boolean;
  tokens: string[];
  error?: string;
}

// Splits whitespace-delimited tokens from input. The popover requires
// exactly one token (1->1 fixes only). Find/replace allows any N as long as
// search and replacement match counts.
export function tokenize(value: string): string[] {
  const trimmed = value.trim();
  if (trimmed === "") return [];
  return trimmed.split(/\s+/);
}

export function validateSingleToken(value: string): ValidationResult {
  const tokens = tokenize(value);
  if (tokens.length === 1) return { valid: true, tokens };
  return {
    valid: false,
    tokens,
    error: tokens.length === 0
      ? "Replacement cannot be empty."
      : "Use a single token. To represent a multi-word term without splitting timing, squash it (e.g. SanJose).",
  };
}

export function validateMatchedCount(search: string, replacement: string): ValidationResult {
  const oldTokens = tokenize(search);
  const newTokens = tokenize(replacement);
  if (oldTokens.length === 0) {
    return { valid: false, tokens: [], error: "Search cannot be empty." };
  }
  if (newTokens.length === 0) {
    return { valid: false, tokens: [], error: "Replacement cannot be empty." };
  }
  if (oldTokens.length !== newTokens.length) {
    return {
      valid: false,
      tokens: newTokens,
      error: "Token count must match. Splitting or merging would corrupt timing — use a squashed form (e.g. SanJose) if needed.",
    };
  }
  return { valid: true, tokens: newTokens };
}
```

- [ ] **Step 2: TS-check + commit**

```bash
cd ui && pnpm tsc --noEmit
git add ui/src/routes/library/tokenValidation.ts
git commit -m "M3: tokenValidation — pure 1<->1 / N<->N helper"
```

### Task 13: WordToken component

Replaces the inline word `<button>` currently rendered in `TranscriptZone.tsx`. Single click still scrubs (preserving M1 behavior). Hover reveals a pencil affordance; click pencil (or focus + press `e`) to open the popover anchored to the token.

**Files:**
- Create: `ui/src/routes/library/WordToken.tsx`

- [ ] **Step 1: Write the file**

```tsx
// ui/src/routes/library/WordToken.tsx
import { useRef } from "react";
import type { AudioWord } from "./types";

export interface WordTokenProps {
  word: AudioWord;
  segmentIndex: number;
  wordIndex: number;
  onSeek: (seconds: number) => void;
  onEditRequest: (anchor: HTMLElement, segmentIndex: number, wordIndex: number, currentToken: string) => void;
}

export default function WordToken({ word, segmentIndex, wordIndex, onSeek, onEditRequest }: WordTokenProps) {
  const ref = useRef<HTMLSpanElement | null>(null);

  return (
    <span ref={ref} className="row__word-wrap" data-segment={segmentIndex} data-word-index={wordIndex}>
      <button
        className="row__word"
        onClick={() => onSeek(word.start)}
        onKeyDown={(e) => {
          if (e.key === "e" && (e.metaKey || e.ctrlKey === false)) {
            e.preventDefault();
            if (ref.current) onEditRequest(ref.current, segmentIndex, wordIndex, word.word);
          }
        }}
      >
        {word.word}
      </button>
      <button
        className="row__pencil"
        title="Edit word"
        aria-label={`Edit word ${word.word}`}
        onClick={(e) => {
          e.stopPropagation();
          if (ref.current) onEditRequest(ref.current, segmentIndex, wordIndex, word.word);
        }}
      >
        ✎
      </button>
    </span>
  );
}
```

- [ ] **Step 2: TS-check + commit**

```bash
cd ui && pnpm tsc --noEmit
git add ui/src/routes/library/WordToken.tsx
git commit -m "M3: WordToken — scrub-click + pencil affordance"
```

### Task 14: useTranscriptEditor hook (scroll anchor + dispatch + undo)

**Files:**
- Create: `ui/src/routes/library/useTranscriptEditor.ts`

- [ ] **Step 1: Write the file**

```ts
// ui/src/routes/library/useTranscriptEditor.ts
import { useCallback, useEffect, useRef, useState } from "react";
import {
  applyTranscriptEdit,
  applyLibraryReplace,
  findTranscriptMatches,
  listenTranscriptEdited,
} from "../../ipc/sidecar";
import type {
  ApplyEditResult,
  ApplyLibraryReplaceResult,
  FinderMatch,
  ReplaceScope,
  TranscriptEdit,
  UndoEntry,
} from "./editorTypes";

interface ScrollAnchor {
  segmentIndex: number;
  wordIndex: number;
  viewportOffset: number;
}

export interface UseTranscriptEditorArgs {
  library: string;
  clip: string | null;
  scrollContainerRef: React.RefObject<HTMLElement>;
  onTranscriptEdited: () => void; // caller refetches; hook restores anchor afterwards
}

export function useTranscriptEditor({ library, clip, scrollContainerRef, onTranscriptEdited }: UseTranscriptEditorArgs) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const undoRef = useRef<UndoEntry | null>(null);
  const anchorRef = useRef<ScrollAnchor | null>(null);

  // Reset undo stack when the open clip changes.
  useEffect(() => {
    undoRef.current = null;
  }, [clip]);

  // Subscribe to transcript_edited; capture anchor + ask caller to refetch.
  useEffect(() => {
    let unlisten: (() => void) | null = null;
    listenTranscriptEdited((e) => {
      if (e.library !== library || e.clip !== clip) return;
      anchorRef.current = captureAnchor(scrollContainerRef.current);
      onTranscriptEdited();
    }).then((fn) => { unlisten = fn; });
    return () => { unlisten?.(); };
  }, [library, clip, scrollContainerRef, onTranscriptEdited]);

  // Restore anchor after the caller's refetch + re-render. Caller invokes
  // restoreAnchor() in a useLayoutEffect tied to the new transcript content.
  const restoreAnchor = useCallback(() => {
    const anchor = anchorRef.current;
    anchorRef.current = null;
    if (!anchor || !scrollContainerRef.current) return;
    const container = scrollContainerRef.current;
    const sel = `[data-segment="${anchor.segmentIndex}"][data-word-index="${anchor.wordIndex}"]`;
    const el = container.querySelector<HTMLElement>(sel);
    if (!el) return;
    const containerTop = container.getBoundingClientRect().top;
    const wordTop = el.getBoundingClientRect().top;
    container.scrollTop += wordTop - containerTop - anchor.viewportOffset;
  }, [scrollContainerRef]);

  const editClipScope = useCallback(async (clipName: string, edit: TranscriptEdit): Promise<ApplyEditResult | null> => {
    setBusy(true); setError(null);
    try {
      anchorRef.current = captureAnchor(scrollContainerRef.current);
      const r = await applyTranscriptEdit(library, clipName, edit);
      undoRef.current = {
        scope: "clip",
        inverse_edit: { ...edit, old_tokens: edit.new_tokens, new_tokens: edit.old_tokens, clip: clipName },
      };
      // The sidecar emits transcript_edited; the listener triggers refetch.
      // For clip scope we still emit the event from sidecar via TranscriptEditor?
      // No — TranscriptEditor doesn't notify; only LibraryReplacer does.
      // Trigger refetch directly here.
      onTranscriptEdited();
      return r;
    } catch (e) {
      setError(String(e));
      return null;
    } finally {
      setBusy(false);
    }
  }, [library, scrollContainerRef, onTranscriptEdited]);

  const replaceLibrary = useCallback(async (oldTokens: string[], newTokens: string[], scope: ReplaceScope): Promise<ApplyLibraryReplaceResult | null> => {
    setBusy(true); setError(null);
    try {
      anchorRef.current = captureAnchor(scrollContainerRef.current);
      const trust = scope === "trust";
      const r = await applyLibraryReplace(library, oldTokens, newTokens, trust);
      // For trust=true, only mark "remove from user_context on undo" if the
      // server actually appended the term (we approximate: any successful
      // trust replace counts; idempotent re-runs are harmless on undo).
      undoRef.current = {
        scope,
        inverse_replace: {
          old_tokens: newTokens,
          new_tokens: oldTokens,
          remove_user_context_term: trust ? newTokens.join(" ") : null,
        },
      };
      // listenTranscriptEdited will fire onTranscriptEdited per affected clip
      // for this library; nothing extra to do here.
      return r;
    } catch (e) {
      setError(String(e));
      return null;
    } finally {
      setBusy(false);
    }
  }, [library, scrollContainerRef]);

  const findMatches = useCallback(async (tokens: string[], scope: "clip" | "library", clipName?: string): Promise<FinderMatch[]> => {
    if (tokens.length === 0) return [];
    try {
      const r = await findTranscriptMatches(library, tokens, scope, clipName);
      return r.matches;
    } catch (e) {
      setError(String(e));
      return [];
    }
  }, [library]);

  const undo = useCallback(async () => {
    const entry = undoRef.current;
    if (!entry) return;
    undoRef.current = null;
    if (entry.scope === "clip" && entry.inverse_edit) {
      const { clip: c, ...edit } = entry.inverse_edit;
      anchorRef.current = captureAnchor(scrollContainerRef.current);
      await applyTranscriptEdit(library, c, edit);
      onTranscriptEdited();
    } else if (entry.inverse_replace) {
      anchorRef.current = captureAnchor(scrollContainerRef.current);
      // Note: trust-scope undo cannot remove the term from user_context via
      // the existing apply_library_replace API. v1 leaves the term in
      // user_context on undo (a known minor leak; documented in PR notes).
      await applyLibraryReplace(library, entry.inverse_replace.old_tokens, entry.inverse_replace.new_tokens, false);
    }
  }, [library, scrollContainerRef, onTranscriptEdited]);

  return { busy, error, editClipScope, replaceLibrary, findMatches, undo, restoreAnchor };
}

function captureAnchor(container: HTMLElement | null): ScrollAnchor | null {
  if (!container) return null;
  const containerRect = container.getBoundingClientRect();
  const words = container.querySelectorAll<HTMLElement>("[data-segment][data-word-index]");
  for (const w of Array.from(words)) {
    const r = w.getBoundingClientRect();
    if (r.top >= containerRect.top) {
      return {
        segmentIndex: Number(w.dataset.segment),
        wordIndex: Number(w.dataset.wordIndex),
        viewportOffset: r.top - containerRect.top,
      };
    }
  }
  return null;
}
```

> Note on the undo trade-off documented inline above: trust-scope undo does not strip the term from `user_context` in v1. The spec calls for it; the simplest path is to expose an additional sidecar method (`remove_user_context_term`). Out of scope here — list as a follow-up in the PR.

- [ ] **Step 2: TS-check + commit**

```bash
cd ui && pnpm tsc --noEmit
git add ui/src/routes/library/useTranscriptEditor.ts
git commit -m "M3: useTranscriptEditor hook — dispatch, scroll anchor, one-level undo"
```

---

## Phase 8 — EditPopover

**Spec section:** "Architecture → Frontend → EditPopover.tsx"; "UX flow".

### Task 15: EditPopover component

**Files:**
- Create: `ui/src/routes/library/EditPopover.tsx`

- [ ] **Step 1: Write the file**

```tsx
// ui/src/routes/library/EditPopover.tsx
import { useEffect, useMemo, useRef, useState } from "react";
import { validateSingleToken } from "./tokenValidation";
import type { ReplaceScope } from "./editorTypes";

export interface EditPopoverProps {
  library: string;
  clip: string;
  segmentIndex: number;
  wordIndex: number;
  currentToken: string;
  anchor: HTMLElement;
  busy: boolean;
  onCancel: () => void;
  onSubmit: (args: { newToken: string; scope: ReplaceScope }) => void;
  // Async match counter for library/trust scopes. Returns the number of
  // matches and clip count.
  fetchMatchCount: (token: string) => Promise<{ matches: number; clips: number }>;
}

export default function EditPopover(props: EditPopoverProps) {
  const { currentToken, anchor, busy, onCancel, onSubmit, fetchMatchCount } = props;
  const [value, setValue] = useState(currentToken);
  const [scope, setScope] = useState<ReplaceScope>("clip");
  const [matchInfo, setMatchInfo] = useState<{ matches: number; clips: number } | null>(null);
  const inputRef = useRef<HTMLInputElement | null>(null);

  const validation = useMemo(() => validateSingleToken(value), [value]);
  const position = anchorPosition(anchor);

  useEffect(() => { inputRef.current?.focus(); inputRef.current?.select(); }, []);
  useEffect(() => {
    if (scope === "clip") { setMatchInfo(null); return; }
    let cancelled = false;
    fetchMatchCount(currentToken).then((r) => { if (!cancelled) setMatchInfo(r); });
    return () => { cancelled = true; };
  }, [scope, currentToken, fetchMatchCount]);

  const canSubmit = validation.valid && !busy && value !== currentToken;

  return (
    <div
      className="edit-popover"
      style={{ top: position.top, left: position.left }}
      onKeyDown={(e) => {
        if (e.key === "Escape") { e.preventDefault(); onCancel(); }
        if (e.key === "Enter" && canSubmit) {
          e.preventDefault();
          onSubmit({ newToken: validation.tokens[0], scope });
        }
      }}
    >
      <input
        ref={inputRef}
        className="edit-popover__input"
        value={value}
        onChange={(e) => setValue(e.target.value)}
      />
      {!validation.valid && <p className="edit-popover__error">{validation.error}</p>}

      <fieldset className="edit-popover__scope">
        <label><input type="radio" name="scope" checked={scope === "clip"} onChange={() => setScope("clip")} /> This clip</label>
        <label><input type="radio" name="scope" checked={scope === "library"} onChange={() => setScope("library")} /> This library</label>
        <label><input type="radio" name="scope" checked={scope === "trust"} onChange={() => setScope("trust")} /> Trust globally</label>
      </fieldset>

      {scope !== "clip" && matchInfo && (
        <p className="edit-popover__count">
          Found {matchInfo.matches} match{matchInfo.matches === 1 ? "" : "es"} across {matchInfo.clips} clip{matchInfo.clips === 1 ? "" : "s"}.
        </p>
      )}

      <div className="edit-popover__actions">
        <button onClick={onCancel} disabled={busy}>Cancel</button>
        <button
          className="edit-popover__submit"
          disabled={!canSubmit}
          onClick={() => onSubmit({ newToken: validation.tokens[0], scope })}
        >
          {busy ? "Replacing…" : "Replace"}
        </button>
      </div>
    </div>
  );
}

function anchorPosition(anchor: HTMLElement) {
  const r = anchor.getBoundingClientRect();
  return { top: r.bottom + 4, left: r.left };
}
```

- [ ] **Step 2: TS-check + commit**

```bash
cd ui && pnpm tsc --noEmit
git add ui/src/routes/library/EditPopover.tsx
git commit -m "M3: EditPopover — token input, scope picker, live match count"
```

---

## Phase 9 — FindReplacePanel

**Spec section:** "Architecture → Frontend → FindReplacePanel.tsx".

### Task 16: FindReplacePanel component

**Files:**
- Create: `ui/src/routes/library/FindReplacePanel.tsx`

- [ ] **Step 1: Write the file**

```tsx
// ui/src/routes/library/FindReplacePanel.tsx
import { useEffect, useMemo, useState } from "react";
import { tokenize, validateMatchedCount } from "./tokenValidation";
import type { FinderMatch } from "./editorTypes";

export interface FindReplacePanelProps {
  library: string;
  clip: string | null;
  busy: boolean;
  onClose: () => void;
  // Returns library- or clip-scoped matches.
  findMatches: (tokens: string[], scope: "clip" | "library", clip?: string) => Promise<FinderMatch[]>;
  // Applies a per-match clip-scope edit (used when scope === "clip").
  applyClipReplace: (clip: string, match: FinderMatch, newTokens: string[]) => Promise<void>;
  // Applies a library-wide replace (used when scope === "library").
  applyLibraryReplace: (oldTokens: string[], newTokens: string[]) => Promise<void>;
  // Caller wires this to TranscriptZone for scroll-into-view of a match.
  onSelectMatch: (match: FinderMatch) => void;
}

export default function FindReplacePanel(props: FindReplacePanelProps) {
  const { clip, busy, onClose, findMatches, applyClipReplace, applyLibraryReplace, onSelectMatch } = props;
  const [search, setSearch] = useState("");
  const [replacement, setReplacement] = useState("");
  const [scope, setScope] = useState<"clip" | "library">("clip");
  const [matches, setMatches] = useState<FinderMatch[]>([]);

  const validation = useMemo(() => validateMatchedCount(search, replacement), [search, replacement]);
  const searchTokens = useMemo(() => tokenize(search), [search]);
  const newTokens = useMemo(() => tokenize(replacement), [replacement]);

  useEffect(() => {
    if (searchTokens.length === 0) { setMatches([]); return; }
    let cancelled = false;
    const target = scope === "clip" ? clip ?? undefined : undefined;
    findMatches(searchTokens, scope, target).then((m) => { if (!cancelled) setMatches(m); });
    return () => { cancelled = true; };
  }, [searchTokens.join("|"), scope, clip, findMatches]);

  const canReplaceAll = validation.valid && !busy && matches.length > 0;

  return (
    <div className="find-replace">
      <header>
        <strong>Find &amp; replace</strong>
        <button onClick={onClose} aria-label="Close">×</button>
      </header>
      <div className="find-replace__row">
        <input
          placeholder="Find"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
        />
        <input
          placeholder="Replace with"
          value={replacement}
          onChange={(e) => setReplacement(e.target.value)}
        />
      </div>
      {!validation.valid && replacement.length > 0 && (
        <p className="find-replace__error">{validation.error}</p>
      )}
      <fieldset className="find-replace__scope">
        <label><input type="radio" checked={scope === "clip"} onChange={() => setScope("clip")} /> This clip</label>
        <label><input type="radio" checked={scope === "library"} onChange={() => setScope("library")} /> Whole library</label>
      </fieldset>

      <ul className="find-replace__matches">
        {matches.map((m, i) => (
          <li key={`${m.clip}:${m.segment_index}:${m.word_index}:${i}`}>
            <button onClick={() => onSelectMatch(m)} disabled={scope === "library" && m.clip !== clip}>
              <span className="find-replace__clip">{m.clip}</span>
              <span className="find-replace__snippet">{m.context_snippet}</span>
            </button>
          </li>
        ))}
      </ul>

      <div className="find-replace__actions">
        <button
          disabled={!canReplaceAll}
          onClick={async () => {
            if (scope === "library") {
              await applyLibraryReplace(searchTokens, newTokens);
            } else if (clip) {
              // Apply right-to-left within the clip to keep word_indices stable.
              const sorted = [...matches].sort((a, b) => {
                if (a.segment_index !== b.segment_index) return b.segment_index - a.segment_index;
                return b.word_index - a.word_index;
              });
              for (const m of sorted) {
                await applyClipReplace(clip, m, newTokens);
              }
            }
          }}
        >
          Replace all ({matches.length})
        </button>
      </div>
    </div>
  );
}
```

- [ ] **Step 2: TS-check + commit**

```bash
cd ui && pnpm tsc --noEmit
git add ui/src/routes/library/FindReplacePanel.tsx
git commit -m "M3: FindReplacePanel — clip / library scope, N<->N validation"
```

---

## Phase 10 — TranscriptZone integration + CSS

**Spec section:** "Architecture → Modified → TranscriptZone.tsx, library.css"; "Scroll stability".

### Task 17: Integrate WordToken, popover, panel, and scroll-anchor wiring into TranscriptZone

**Files:**
- Modify: `ui/src/routes/library/TranscriptZone.tsx`

- [ ] **Step 1: Replace TranscriptZone**

Overwrite `ui/src/routes/library/TranscriptZone.tsx` with:

```tsx
import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import {
  applyTranscriptEdit,
  findTranscriptMatches,
  getClipTranscripts,
} from "../../ipc/sidecar";
import type { ClipTranscripts } from "./types";
import { formatTimestamp, interleave, InterleavedRow } from "./interleave";
import EditPopover from "./EditPopover";
import FindReplacePanel from "./FindReplacePanel";
import WordToken from "./WordToken";
import { useTranscriptEditor } from "./useTranscriptEditor";
import type { FinderMatch, TranscriptEdit } from "./editorTypes";

interface Props {
  library: string;
  video: string | null;
  onSeek: (seconds: number) => void;
}

type LoadState =
  | { kind: "idle" }
  | { kind: "loading"; library: string; video: string }
  | { kind: "ready"; library: string; video: string; transcripts: ClipTranscripts; revision: number }
  | { kind: "error"; library: string; video: string; message: string };

interface PopoverState {
  anchor: HTMLElement;
  segmentIndex: number;
  wordIndex: number;
  currentToken: string;
}

function matchesActive(state: LoadState, library: string, video: string | null): boolean {
  if (state.kind === "idle") return false;
  return state.library === library && state.video === video;
}

export default function TranscriptZone({ library, video, onSeek }: Props) {
  const [state, setState] = useState<LoadState>({ kind: "idle" });
  const [popover, setPopover] = useState<PopoverState | null>(null);
  const [findOpen, setFindOpen] = useState(false);
  const containerRef = useRef<HTMLDivElement | null>(null);
  const refetchTokenRef = useRef(0);

  const refetch = useCallback(() => {
    if (!video) return;
    const token = ++refetchTokenRef.current;
    getClipTranscripts(library, video).then((transcripts) => {
      if (refetchTokenRef.current !== token) return;
      setState((prev) => ({
        kind: "ready",
        library, video, transcripts,
        revision: prev.kind === "ready" ? prev.revision + 1 : 1,
      }));
    });
  }, [library, video]);

  const editor = useTranscriptEditor({
    library, clip: video,
    scrollContainerRef: containerRef,
    onTranscriptEdited: refetch,
  });

  // Restore scroll anchor after each refetch's re-render.
  useLayoutEffect(() => {
    if (state.kind === "ready") editor.restoreAnchor();
  }, [state.kind === "ready" ? state.revision : 0, editor]);

  // ⌘F opens find/replace.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "f") {
        e.preventDefault();
        setFindOpen((v) => !v);
      }
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "z") {
        e.preventDefault();
        editor.undo();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [editor]);

  useEffect(() => {
    if (!video) {
      setState({ kind: "idle" });
      return;
    }
    let cancelled = false;
    setState({ kind: "loading", library, video });
    getClipTranscripts(library, video)
      .then((transcripts) => { if (!cancelled) setState({ kind: "ready", library, video, transcripts, revision: 1 }); })
      .catch((err) => { if (!cancelled) setState({ kind: "error", library, video, message: String(err) }); });
    return () => { cancelled = true; };
  }, [library, video]);

  if (!matchesActive(state, library, video)) {
    return <div ref={containerRef} className="transcript-zone transcript-zone--empty">{video ? "Loading transcripts…" : "No clip selected."}</div>;
  }
  if (state.kind === "idle" || !video) {
    return <div ref={containerRef} className="transcript-zone transcript-zone--empty">No clip selected.</div>;
  }
  if (state.kind === "loading") {
    return <div ref={containerRef} className="transcript-zone transcript-zone--empty">Loading transcripts…</div>;
  }
  if (state.kind === "error") {
    return (
      <div ref={containerRef} className="transcript-zone transcript-zone--empty">
        <p>Couldn't load transcripts.</p>
        <pre>{state.message}</pre>
      </div>
    );
  }

  const visualSegments = state.transcripts.visual?.segments ?? [];
  const audioSegments = state.transcripts.audio?.segments ?? [];

  const onEditRequest = (anchor: HTMLElement, segmentIndex: number, wordIndex: number, currentToken: string) => {
    setPopover({ anchor, segmentIndex, wordIndex, currentToken });
  };

  const submitPopover = async ({ newToken, scope }: { newToken: string; scope: "clip" | "library" | "trust" }) => {
    if (!popover) return;
    if (scope === "clip") {
      const edit: TranscriptEdit = {
        segment_index: popover.segmentIndex,
        word_index: popover.wordIndex,
        old_tokens: [popover.currentToken],
        new_tokens: [newToken],
      };
      await editor.editClipScope(video, edit);
    } else {
      await editor.replaceLibrary([popover.currentToken], [newToken], scope);
    }
    setPopover(null);
  };

  const fetchMatchCount = async (token: string) => {
    const r = await findTranscriptMatches(library, [token], "library");
    const matches = r.matches.length;
    const clips = new Set(r.matches.map((m) => m.clip)).size;
    return { matches, clips };
  };

  const applyClipReplaceFromPanel = async (clipName: string, m: FinderMatch, newTokens: string[]) => {
    await applyTranscriptEdit(library, clipName, {
      segment_index: m.segment_index,
      word_index: m.word_index,
      old_tokens: m.matched_tokens,
      new_tokens: newTokens,
    });
    refetch();
  };

  const applyLibraryReplaceFromPanel = async (oldTokens: string[], newTokens: string[]) => {
    await editor.replaceLibrary(oldTokens, newTokens, "library");
  };

  const onSelectMatch = (m: FinderMatch) => {
    const sel = `[data-segment="${m.segment_index}"][data-word-index="${m.word_index}"]`;
    const el = containerRef.current?.querySelector<HTMLElement>(sel);
    el?.scrollIntoView({ block: "center", behavior: "smooth" });
  };

  const renderRows = () => {
    if (visualSegments.length === 0 && audioSegments.length === 0) {
      return <div className="transcript-zone--empty">This clip hasn't been analyzed yet.</div>;
    }
    if (visualSegments.length === 0) {
      return audioSegments.map((seg, i) => (
        <AudioRow key={i} segment={seg} segmentIndex={i} onSeek={onSeek} onEditRequest={onEditRequest} />
      ));
    }
    const rows = interleave(visualSegments, audioSegments);
    return rows.map((row, i) => <Row key={i} row={row} onSeek={onSeek} onEditRequest={onEditRequest} segments={audioSegments} />);
  };

  return (
    <div ref={containerRef} className="transcript-zone">
      {renderRows()}

      {popover && (
        <EditPopover
          library={library}
          clip={video}
          segmentIndex={popover.segmentIndex}
          wordIndex={popover.wordIndex}
          currentToken={popover.currentToken}
          anchor={popover.anchor}
          busy={editor.busy}
          onCancel={() => setPopover(null)}
          onSubmit={submitPopover}
          fetchMatchCount={fetchMatchCount}
        />
      )}

      {findOpen && (
        <FindReplacePanel
          library={library}
          clip={video}
          busy={editor.busy}
          onClose={() => setFindOpen(false)}
          findMatches={editor.findMatches}
          applyClipReplace={applyClipReplaceFromPanel}
          applyLibraryReplace={applyLibraryReplaceFromPanel}
          onSelectMatch={onSelectMatch}
        />
      )}

      {editor.error && <div className="transcript-zone__toast">{editor.error}</div>}
    </div>
  );
}

function Row({
  row, onSeek, onEditRequest, segments,
}: {
  row: InterleavedRow;
  onSeek: (s: number) => void;
  onEditRequest: (anchor: HTMLElement, segmentIndex: number, wordIndex: number, currentToken: string) => void;
  segments: import("./types").AudioSegment[];
}) {
  return (
    <div className="row">
      <button className="row__visual" onClick={() => onSeek(row.visual.start)}>
        <span className="row__time">[{formatTimestamp(row.visual.start)}]</span>
        <span className="row__visual-text">{row.visual.visual}</span>
        {row.visual.b_roll && <span className="row__chip">b-roll</span>}
      </button>
      {row.audio.map((seg) => {
        const segmentIndex = segments.indexOf(seg);
        return <AudioRow key={segmentIndex} segment={seg} segmentIndex={segmentIndex} onSeek={onSeek} onEditRequest={onEditRequest} />;
      })}
    </div>
  );
}

function AudioRow({
  segment, segmentIndex, onSeek, onEditRequest,
}: {
  segment: import("./types").AudioSegment;
  segmentIndex: number;
  onSeek: (s: number) => void;
  onEditRequest: (anchor: HTMLElement, segmentIndex: number, wordIndex: number, currentToken: string) => void;
}) {
  if (segment.words && segment.words.length > 0) {
    return (
      <p className="row__audio">
        <span className="row__time">[{formatTimestamp(segment.start)}]</span>
        {segment.words.map((w, i) => (
          <WordToken
            key={i}
            word={w}
            segmentIndex={segmentIndex}
            wordIndex={i}
            onSeek={onSeek}
            onEditRequest={onEditRequest}
          />
        ))}
      </p>
    );
  }
  return (
    <p className="row__audio">
      <button className="row__audio-text" onClick={() => onSeek(segment.start)}>
        <span className="row__time">[{formatTimestamp(segment.start)}]</span>
        {segment.text}
      </button>
    </p>
  );
}
```

- [ ] **Step 2: TS-check**

```bash
cd ui && pnpm tsc --noEmit
```
Expected: 0 errors.

- [ ] **Step 3: Commit**

```bash
git add ui/src/routes/library/TranscriptZone.tsx
git commit -m "M3: integrate WordToken, EditPopover, FindReplacePanel into TranscriptZone"
```

### Task 18: CSS for popover, panel, pencil affordance, error state

**Files:**
- Modify: `ui/src/routes/library/library.css`

- [ ] **Step 1: Append styles**

Append to `ui/src/routes/library/library.css`:

```css
/* M3 — transcript editing */

.row__word-wrap {
  position: relative;
  display: inline-flex;
  align-items: baseline;
}

.row__pencil {
  appearance: none;
  border: 0;
  background: transparent;
  color: rgba(224, 165, 90, 0.65);
  cursor: pointer;
  font-size: 0.7em;
  margin-left: 0.15em;
  opacity: 0;
  transition: opacity 80ms ease;
  padding: 0 2px;
}

.row__word-wrap:hover .row__pencil,
.row__word-wrap:focus-within .row__pencil {
  opacity: 1;
}

.row__pencil:hover {
  color: #e0a55a;
}

.edit-popover {
  position: fixed;
  z-index: 100;
  background: #14141a;
  border: 1px solid rgba(224, 165, 90, 0.4);
  border-radius: 6px;
  padding: 12px;
  min-width: 260px;
  box-shadow: 0 10px 30px rgba(0, 0, 0, 0.55);
  color: #e8e8ee;
  font-family: 'JetBrains Mono', monospace;
  font-size: 13px;
}

.edit-popover__input {
  width: 100%;
  padding: 6px 8px;
  background: #1c1c24;
  border: 1px solid rgba(255, 255, 255, 0.1);
  color: #fff;
  font-family: inherit;
  font-size: inherit;
  border-radius: 4px;
}

.edit-popover__error,
.find-replace__error {
  color: #ef9c8a;
  font-size: 11px;
  margin: 6px 0 0 0;
  line-height: 1.3;
}

.edit-popover__scope,
.find-replace__scope {
  border: 0;
  padding: 8px 0 4px;
  margin: 8px 0 0;
  display: flex;
  flex-direction: column;
  gap: 4px;
}

.edit-popover__count {
  margin: 4px 0 8px;
  color: rgba(224, 165, 90, 0.85);
  font-size: 11px;
}

.edit-popover__actions,
.find-replace__actions {
  display: flex;
  justify-content: flex-end;
  gap: 6px;
  margin-top: 8px;
}

.edit-popover__submit {
  background: #e0a55a;
  color: #14141a;
  border: 0;
  padding: 4px 10px;
  border-radius: 3px;
  cursor: pointer;
}
.edit-popover__submit:disabled { opacity: 0.4; cursor: not-allowed; }

.find-replace {
  position: fixed;
  top: 60px;
  right: 24px;
  width: 360px;
  background: #14141a;
  border: 1px solid rgba(224, 165, 90, 0.4);
  border-radius: 6px;
  padding: 12px;
  z-index: 90;
  font-family: 'JetBrains Mono', monospace;
  font-size: 12px;
  color: #e8e8ee;
}

.find-replace header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 8px;
}

.find-replace__row {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 6px;
}

.find-replace__row input {
  padding: 5px 7px;
  background: #1c1c24;
  border: 1px solid rgba(255, 255, 255, 0.1);
  color: #fff;
  font-family: inherit;
}

.find-replace__matches {
  list-style: none;
  margin: 8px 0 0 0;
  padding: 0;
  max-height: 240px;
  overflow-y: auto;
}

.find-replace__matches li button {
  width: 100%;
  text-align: left;
  background: transparent;
  border: 0;
  color: inherit;
  padding: 4px 0;
  cursor: pointer;
  display: grid;
  grid-template-columns: 100px 1fr;
  gap: 8px;
}

.find-replace__clip {
  color: rgba(224, 165, 90, 0.7);
}

.transcript-zone__toast {
  position: fixed;
  bottom: 16px;
  right: 16px;
  background: #2a1414;
  border: 1px solid #ef9c8a;
  color: #ef9c8a;
  padding: 8px 12px;
  border-radius: 4px;
  font-size: 12px;
}
```

- [ ] **Step 2: Commit**

```bash
git add ui/src/routes/library/library.css
git commit -m "M3: styles for popover, find/replace panel, pencil affordance"
```

---

## Phase 11 — Verification

### Task 19: Full-suite verification + manual smoke

- [ ] **Step 1: Run all sidecar specs**

```bash
cd ui/sidecar && bundle exec rspec
```
Expected: all green. (Pre-existing `spec/buttercut/fcpx_spec.rb` failures are out of scope per the M2 handoff briefing — they live in the gem core, not under `ui/sidecar/spec/`.)

- [ ] **Step 2: Run gem specs (sanity)**

```bash
cd /Users/william-meroxa/Development/buttercut && bundle exec rspec
```
Expected: same pass/fail surface as `main` — M3 must not regress.

- [ ] **Step 3: TypeScript-check**

```bash
cd ui && pnpm tsc --noEmit
```
Expected: 0 errors.

- [ ] **Step 4: Build the app**

```bash
cd ui && pnpm tauri build --no-bundle
```
Expected: clean build.

- [ ] **Step 5: Manual smoke checklist (run with `pnpm tauri dev`)**

Test against the existing `1stphorm-workout` library (or any library that has segments with `words[]`).

  - Open a library window, pick a clip with audio words.
  - **Single-click word:** player scrubs to its `start` time. (M1 behavior preserved.)
  - **Hover word:** pencil affordance appears. Click it → popover opens anchored to the word.
  - **1→1 spelling fix, scope=clip:** type a single token, press Enter; transcript updates in place; scrub still works on the new token.
  - **Multi-token input:** type a space; the inline error reads "Use a single token… squash it (e.g. SanJose)"; Replace stays disabled.
  - **scope=library:** count line shows "Found N matches across M clips"; Replace updates all clips; the active clip's scroll position stays put across the mutation.
  - **scope=trust:** same as library, then open `libraries/<lib>/library.yaml` and confirm the new term appears in `user_context`.
  - **⌘F:** find/replace panel opens; matches list populates; click a match → scrolls into view; **N→N replace** works (e.g. `Walnut Creak` → `Walnut Creek`); 1→2 input shows the matched-count error.
  - **⌘Z (undo):** reverses the most recent edit. Confirm the transcript reverts. (Trust-scope undo only reverts text; `user_context` retains the term — known follow-up.)
  - **Empty-segments clip:** open a clip with `segments: []` (e.g. C0076.json in the demo library). Pane shows "This clip hasn't been analyzed yet." No crash on hover or ⌘F.

- [ ] **Step 6: Push branch and open PR**

```bash
git push -u origin sprint-02-m3-transcript-editing
gh pr create --title "M3: Transcript editing in the desktop UI" --body "$(cat <<'EOF'
## Summary

Implements milestone M3 from William-Hill/buttercut#14. Adds inline word-level editing of audio transcripts in the M1 footage browser:

- Click pencil on a word → popover with three scopes (this clip / this library / trust globally + append to `user_context`).
- ⌘F find/replace with clip and library scopes; supports N→N phrase fixes (matched count enforced).
- Strict 1↔1 / N↔N word-count rule, validated client- and server-side.
- Stable scroll position across library-wide mutation of the active clip.
- One-level undo per open clip (Cmd-Z).

## Architecture

Three new sidecar classes (`TranscriptEditor`, `TranscriptFinder`, `LibraryReplacer`) hold the editing logic, mirroring `refine_instructions.md` Step 5 but as deterministic Ruby code. Three new JSON-RPC methods + Tauri commands. `transcript_edited` notification triggers a refetch with captured scroll anchor.

Spec: `docs/superpowers/specs/2026-05-03-m3-transcript-editing-design.md`.
Plan: `docs/superpowers/plans/2026-05-04-m3-transcript-editing.md`.

## Out of scope (follow-ups)

- Trust-scope undo does not strip the term from `user_context` (would need a new `remove_user_context_term` sidecar method).
- React component test harness (no JS test runner in repo; matches M0/M1/M2 precedent).
- Re-running Claude refinement on edits (decision B from brainstorming — deferred).
- N→N edits via the popover (popover stays single-token; find/replace is the N→N path).

## Test plan

- [x] `cd ui/sidecar && bundle exec rspec` — all green
- [x] `cd ui && pnpm tsc --noEmit` — 0 errors
- [x] `cd ui && pnpm tauri build --no-bundle` — clean
- [x] Manual smoke: single-token edit, library-wide replace, trust globally, ⌘F find/replace (1↔1 and N↔N), ⌘Z undo, empty-segments clip, scroll stability across mutation
EOF
)"
```

---

## Self-review notes (recorded after writing)

**Spec coverage:**
- Three edit scopes — covered (`EditPopover` scope picker; `useTranscriptEditor.replaceLibrary` with `trust` flag; `LibraryReplacer.append_to_user_context`).
- Find/replace per-clip and library-wide — covered (`FindReplacePanel`, `TranscriptFinder` with `scope:`).
- Word-count rule (1↔1 / N↔N) — covered client-side (`tokenValidation.ts`) and server-side (`TranscriptEditor#apply` length check).
- Scroll stability — covered (`captureAnchor` / `restoreAnchor` in `useTranscriptEditor`, with `data-segment` / `data-word-index` attributes on `WordToken`).
- One-level undo — covered (`undoRef` + `editor.undo()`, with documented trust-scope limitation).
- Three-array consistency — covered (`TranscriptEditor.apply_to_words` / `apply_to_segment_text` / `apply_to_word_segments`).
- Atomic write — covered (`write_atomic` via Tempfile + rename).
- Idempotent `user_context` append — covered (case-insensitive token check in `append_to_user_context`).
- Error codes — `token_count_violation` mapped to `-32013`. `not_found`, `concurrent_modification`, `io_error`, `match_count_drift` from the spec are not separately mapped: the existing generic `-32000` rescue covers them, with descriptive messages. (Acceptable v1 scope; PR notes if needed.)

**Type consistency check:**
- `TranscriptEdit { segment_index, word_index, old_tokens, new_tokens }` is the same shape used in editor types (TS) and the symbolize_edit helper (Ruby).
- `applyLibraryReplace` Tauri command takes `oldTokens`/`newTokens` (camelCase from TS), mapped to `old_tokens`/`new_tokens` in JSON-RPC params, mapped back to symbol keys in Ruby. Verified consistent.
- `transcript_edited` event: `{ library, clip, edit_count }` — same shape in `LibraryReplacer.apply` and `TranscriptEditedEvent` TS interface.

**Placeholder scan:** none. Every step has full code or full commands.

**Documented divergences from spec:**
- React component test harness: skipped (matches M0/M1/M2). Validation logic moved to a pure helper instead.
- Trust-scope undo: text reverts only; `user_context` retains the term. Listed as a follow-up in the PR template.
- Error codes for `not_found` / `concurrent_modification` / `io_error` / `match_count_drift`: subsumed under the existing `-32000` generic with descriptive messages, rather than dedicated codes. Acceptable v1 surface.
