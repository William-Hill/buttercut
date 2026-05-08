# B-Roll Director Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Author the editorial brain of the Hyperframes pipeline — given an existing rough cut and the transcripts/visual transcripts/summaries of the videos it references, decide where graphics belong, what they say, and how they sit in the frame, and write a `<roughcut>.broll.yaml` the existing render skill (#28) and roughcut integration (#33) consume. Ship a CLI skill **and** a UI button on each rough cut row, both backed by a single shared prompt file.

**Architecture:** Per-rough-cut director (timing is rough-cut-relative, matching the shipped manifest schema). Pure-Ruby helpers under `lib/buttercut/` for input gathering and post-processing. One LLM call per invocation; the model returns candidate JSON; the caller validates against `ButterCut::BrollManifest` before writing. Two surfaces (skill + sidecar controller) share `.claude/skills/broll-director/agent_prompt.md` so behavior cannot drift.

**Tech Stack:** Ruby (gem helpers + sidecar), RSpec, Anthropic SDK (already in sidecar), TypeScript/React (UI button).

**Spec:** `docs/superpowers/specs/2026-05-07-broll-director-design.md`

---

## File Structure

**New (Ruby gem helpers — pure functions, no LLM, no I/O beyond what the caller passes):**
- `lib/buttercut/broll_director_inputs.rb` — gathers transcripts/summaries/templates/theme for a given rough cut
- `lib/buttercut/broll_director_postprocess.rb` — threshold filtering, source→cut timecode mapping, density pruning, id assignment, manifest assembly + validation hand-off

**New (skill):**
- `.claude/skills/broll-director/SKILL.md` — parent dispatch brief
- `.claude/skills/broll-director/agent_prompt.md` — canonical director prompt

**New (sidecar):**
- `ui/sidecar/lib/buttercut_ui_sidecar/broll_director_controller.rb` — mirrors `RoughcutController`; loads the same `agent_prompt.md`

**Modify (sidecar):**
- `ui/sidecar/buttercut_ui_sidecar.rb` — register `start_broll_director` op, wire controller, list rough cuts that have/haven't a manifest yet

**New (UI):**
- `ui/src/routes/library/AddBrollButton.tsx` — button + click handler + status display

**Modify (UI):**
- `ui/src/routes/library/RoughcutTimeline.tsx` — render the button per finished rough cut row

**New (tests + fixtures):**
- `spec/buttercut/broll_director_inputs_spec.rb`
- `spec/buttercut/broll_director_postprocess_spec.rb`
- `spec/fixtures/broll_director/sample_library/library.yaml`
- `spec/fixtures/broll_director/sample_library/roughcuts/sample.yaml`
- `spec/fixtures/broll_director/sample_library/transcripts/tutorial_01.json`
- `spec/fixtures/broll_director/sample_library/transcripts/visual_tutorial_01.json`
- `spec/fixtures/broll_director/sample_library/summaries/summary_tutorial_01.md`
- `spec/fixtures/broll_director/canned_model_response.json`

---

### Task 1: Gem helper — `BrollDirectorInputs.gather`

Pure-Ruby helper that the skill parent and the sidecar controller both call. Reads files only (no LLM). Returns a hash with everything the prompt needs.

**Files:**
- Create: `lib/buttercut/broll_director_inputs.rb`
- Create: `spec/buttercut/broll_director_inputs_spec.rb`
- Create: `spec/fixtures/broll_director/sample_library/library.yaml`
- Create: `spec/fixtures/broll_director/sample_library/roughcuts/sample.yaml`
- Create: `spec/fixtures/broll_director/sample_library/transcripts/tutorial_01.json`
- Create: `spec/fixtures/broll_director/sample_library/transcripts/visual_tutorial_01.json`
- Create: `spec/fixtures/broll_director/sample_library/summaries/summary_tutorial_01.md`

- [ ] **Step 1: Create the fixture library.yaml**

`spec/fixtures/broll_director/sample_library/library.yaml`:

```yaml
library_name: sample-library
language: English
editor: Final Cut Pro X
transcript_refinement: true
user_context: ""
footage_summary: "A short tutorial covering interactive rebase."
theme:
  font_display: Inter
  font_mono: JetBrains Mono
  color_bg: '#0d0d0d'
  color_fg: '#f5f5f4'
  color_accent: '#ff6b35'
  template_set: tutorial-dark
  motion: snappy
videos:
  - path: /fixtures/tutorial_01.mov
    duration: "00:02:00"
    transcript: tutorial_01.json
    visual_transcript: visual_tutorial_01.json
    summary: summary_tutorial_01.md
```

- [ ] **Step 2: Create the fixture rough cut**

`spec/fixtures/broll_director/sample_library/roughcuts/sample.yaml`:

```yaml
project: sample
clips:
  - source_video: tutorial_01.mov
    in:  "00:00:30.00"
    out: "00:01:00.00"
  - source_video: tutorial_01.mov
    in:  "00:01:20.00"
    out: "00:01:50.00"
```

- [ ] **Step 3: Create fixture audio transcript**

`spec/fixtures/broll_director/sample_library/transcripts/tutorial_01.json`:

```json
{
  "video_path": "/fixtures/tutorial_01.mov",
  "language": "en",
  "segments": [
    { "start": 30.0, "end": 35.0, "text": "Today we'll look at git rebase interactive." },
    { "start": 35.0, "end": 45.0, "text": "Run git rebase -i HEAD~3 to edit the last three commits." },
    { "start": 45.0, "end": 60.0, "text": "Pick, squash, fixup, reword - those are your main options." },
    { "start": 80.0, "end": 90.0, "text": "Step one: stash any uncommitted changes first." },
    { "start": 90.0, "end": 110.0, "text": "Step two: run git status to confirm a clean tree." }
  ]
}
```

- [ ] **Step 4: Create fixture visual transcript**

`spec/fixtures/broll_director/sample_library/transcripts/visual_tutorial_01.json`:

```json
{
  "video_path": "/fixtures/tutorial_01.mov",
  "frames": [
    { "t": 32.0, "description": "Talking head of presenter, no terminal visible." },
    { "t": 40.0, "description": "Terminal visible showing a git log." },
    { "t": 50.0, "description": "Terminal with interactive rebase editor open." },
    { "t": 85.0, "description": "Talking head only." },
    { "t": 100.0, "description": "Terminal running git status." }
  ]
}
```

- [ ] **Step 5: Create fixture summary**

`spec/fixtures/broll_director/sample_library/summaries/summary_tutorial_01.md`:

```markdown
# tutorial_01.mov

A short walk-through of `git rebase -i`, demonstrated against a tutorial repo.

## Key visuals
- Talking head intro
- Terminal with git log
- Interactive rebase editor

## Notable dialogue
- "Today we'll look at git rebase interactive"
- "Step one: stash any uncommitted changes first"
```

- [ ] **Step 6: Write the failing spec**

`spec/buttercut/broll_director_inputs_spec.rb`:

```ruby
require "spec_helper"
require "buttercut/broll_director_inputs"

RSpec.describe ButterCut::BrollDirectorInputs do
  let(:fixtures) { File.expand_path("../fixtures/broll_director", __dir__) }
  let(:lib_dir) { File.join(fixtures, "sample_library") }
  let(:roughcut_path) { File.join(lib_dir, "roughcuts", "sample.yaml") }
  let(:hyperframes_dir) { File.expand_path("../../../hyperframes", __dir__) }

  it "gathers everything the director prompt needs" do
    result = described_class.gather(
      library_dir: lib_dir,
      roughcut_path: roughcut_path,
      hyperframes_dir: hyperframes_dir
    )

    expect(result[:library_name]).to eq("sample-library")
    expect(result[:roughcut_stem]).to eq("sample")
    expect(result[:roughcut]["clips"].length).to eq(2)
    expect(result[:theme]["template_set"]).to eq("tutorial-dark")

    sources = result[:source_videos]
    expect(sources.keys).to contain_exactly("tutorial_01.mov")
    src = sources["tutorial_01.mov"]
    expect(src[:audio_transcript]["segments"].first["text"]).to include("git rebase")
    expect(src[:visual_transcript]["frames"].length).to eq(5)
    expect(src[:summary]).to include("git rebase")

    templates = result[:available_templates]
    template_names = templates.map { |t| t[:name] }
    expect(template_names).to include("code-callout")
    callout = templates.find { |t| t[:name] == "code-callout" }
    expect(callout[:readme_md]).to be_a(String)
    expect(callout[:readme_md]).not_to be_empty
  end

  it "raises if a referenced source_video is missing transcripts in library.yaml" do
    Dir.mktmpdir do |tmp|
      bad_lib = File.join(tmp, "lib")
      FileUtils.mkdir_p(File.join(bad_lib, "roughcuts"))
      File.write(File.join(bad_lib, "library.yaml"), {
        "library_name" => "x",
        "theme" => {},
        "videos" => [{ "path" => "/x/tutorial_01.mov" }]
      }.to_yaml)
      File.write(File.join(bad_lib, "roughcuts", "r.yaml"), {
        "clips" => [{ "source_video" => "tutorial_01.mov", "in" => "00:00:00.00", "out" => "00:00:05.00" }]
      }.to_yaml)

      expect {
        described_class.gather(
          library_dir: bad_lib,
          roughcut_path: File.join(bad_lib, "roughcuts", "r.yaml"),
          hyperframes_dir: hyperframes_dir
        )
      }.to raise_error(ArgumentError, /missing transcripts.*tutorial_01\.mov/i)
    end
  end
end
```

- [ ] **Step 7: Run the spec, confirm it fails**

Run: `bundle exec rspec spec/buttercut/broll_director_inputs_spec.rb`
Expected: FAIL with `LoadError: cannot load such file -- buttercut/broll_director_inputs`.

- [ ] **Step 8: Implement the helper**

`lib/buttercut/broll_director_inputs.rb`:

```ruby
require "yaml"
require "json"
require "date"
require "pathname"

class ButterCut
  # Pure-Ruby gathering of everything the b-roll director prompt needs.
  # No LLM, no writes — just reads files the caller points at.
  class BrollDirectorInputs
    REQUIRED_VIDEO_KEYS = %w[transcript visual_transcript summary].freeze

    def self.gather(library_dir:, roughcut_path:, hyperframes_dir:)
      new(
        library_dir: library_dir,
        roughcut_path: roughcut_path,
        hyperframes_dir: hyperframes_dir
      ).gather
    end

    def initialize(library_dir:, roughcut_path:, hyperframes_dir:)
      raise ArgumentError, "library_dir required" if library_dir.to_s.empty?
      raise ArgumentError, "roughcut_path required" if roughcut_path.to_s.empty?
      raise ArgumentError, "hyperframes_dir required" if hyperframes_dir.to_s.empty?

      @library_dir = Pathname.new(library_dir)
      @roughcut_path = Pathname.new(roughcut_path)
      @hyperframes_dir = Pathname.new(hyperframes_dir)
    end

    def gather
      library = load_library
      roughcut = load_roughcut
      sources = load_source_videos(library, roughcut)
      {
        library_name: library["library_name"] || @library_dir.basename.to_s,
        roughcut_stem: @roughcut_path.basename.sub_ext("").to_s,
        roughcut: roughcut,
        theme: library["theme"] || {},
        source_videos: sources,
        available_templates: load_templates
      }
    end

    private

    def load_library
      path = @library_dir.join("library.yaml")
      raise ArgumentError, "library.yaml not found at #{path}" unless path.file?
      YAML.safe_load(path.read, permitted_classes: [Date, Time], aliases: true) || {}
    end

    def load_roughcut
      raise ArgumentError, "rough cut not found at #{@roughcut_path}" unless @roughcut_path.file?
      data = YAML.safe_load(@roughcut_path.read, permitted_classes: [Date, Time], aliases: true) || {}
      raise ArgumentError, "rough cut has no clips" unless data["clips"].is_a?(Array) && !data["clips"].empty?
      data
    end

    def load_source_videos(library, roughcut)
      videos_by_basename = (library["videos"] || []).each_with_object({}) do |v, h|
        h[File.basename(v["path"].to_s)] = v
      end

      referenced = roughcut["clips"].map { |c| c["source_video"] }.uniq
      missing_meta = []
      result = {}

      referenced.each do |basename|
        video = videos_by_basename[basename]
        if video.nil?
          missing_meta << basename
          next
        end
        absent = REQUIRED_VIDEO_KEYS.reject { |k| !video[k].to_s.empty? }
        if !absent.empty?
          missing_meta << "#{basename} (missing #{absent.join(', ')})"
          next
        end
        result[basename] = {
          audio_transcript: load_json(@library_dir.join("transcripts", video["transcript"])),
          visual_transcript: load_json(@library_dir.join("transcripts", video["visual_transcript"])),
          summary: @library_dir.join("summaries", video["summary"]).read
        }
      end

      unless missing_meta.empty?
        raise ArgumentError, "missing transcripts/summaries for: #{missing_meta.join('; ')}"
      end

      result
    end

    def load_json(path)
      raise ArgumentError, "transcript not found at #{path}" unless path.file?
      JSON.parse(path.read)
    end

    def load_templates
      compositions_dir = @hyperframes_dir.join("compositions")
      return [] unless compositions_dir.directory?

      compositions_dir.children.select(&:directory?).sort.filter_map do |dir|
        readme = dir.join("README.md")
        next nil unless readme.file?
        { name: dir.basename.to_s, readme_md: readme.read }
      end
    end
  end
end
```

- [ ] **Step 9: Run the spec, confirm it passes**

Run: `bundle exec rspec spec/buttercut/broll_director_inputs_spec.rb`
Expected: 2 examples, 0 failures.

- [ ] **Step 10: Commit**

```bash
git add lib/buttercut/broll_director_inputs.rb \
        spec/buttercut/broll_director_inputs_spec.rb \
        spec/fixtures/broll_director/
git commit -m "feat: BrollDirectorInputs gathers transcripts + templates for the director (#30)"
```

---

### Task 2: Gem helper — `BrollDirectorPostprocess.assemble`

Takes the candidate array the model returns, plus the rough cut, and produces a validated, ready-to-write manifest hash. Pure functions: threshold → source-to-cut timecode mapping → density pruning → id assignment → schema validation.

**Files:**
- Create: `lib/buttercut/broll_director_postprocess.rb`
- Create: `spec/buttercut/broll_director_postprocess_spec.rb`
- Create: `spec/fixtures/broll_director/canned_model_response.json`

- [ ] **Step 1: Create the canned model response fixture**

`spec/fixtures/broll_director/canned_model_response.json`:

```json
[
  {
    "source_video": "tutorial_01.mov",
    "source_start": 35.0,
    "source_end": 40.0,
    "template": "code-callout",
    "placement": "overlay",
    "content": { "command": "git rebase -i HEAD~3", "caption": "Interactive rebase, last 3 commits" },
    "score": 0.9,
    "rationale": "introduces command, terminal visible"
  },
  {
    "source_video": "tutorial_01.mov",
    "source_start": 36.0,
    "source_end": 38.0,
    "template": "code-callout",
    "placement": "overlay",
    "content": { "command": "git log --oneline" },
    "score": 0.4,
    "rationale": "low-novelty filler"
  },
  {
    "source_video": "tutorial_01.mov",
    "source_start": 100.0,
    "source_end": 105.0,
    "template": "code-callout",
    "placement": "overlay",
    "content": { "command": "git status", "caption": "Confirm a clean tree" },
    "score": 0.7,
    "rationale": "structural beat, terminal visible"
  },
  {
    "source_video": "tutorial_01.mov",
    "source_start": 200.0,
    "source_end": 205.0,
    "template": "code-callout",
    "placement": "overlay",
    "content": { "command": "out-of-cut" },
    "score": 0.95,
    "rationale": "outside any clip"
  },
  {
    "source_video": "tutorial_01.mov",
    "source_start": 95.0,
    "source_end": 99.0,
    "template": "no-such-template",
    "placement": "overlay",
    "content": { "x": "y" },
    "score": 0.8,
    "rationale": "unknown template"
  }
]
```

- [ ] **Step 2: Write the failing spec**

`spec/buttercut/broll_director_postprocess_spec.rb`:

```ruby
require "spec_helper"
require "json"
require "buttercut/broll_director_postprocess"
require "buttercut/broll_manifest"

RSpec.describe ButterCut::BrollDirectorPostprocess do
  let(:fixtures) { File.expand_path("../fixtures/broll_director", __dir__) }
  let(:roughcut) {
    {
      "clips" => [
        { "source_video" => "tutorial_01.mov", "in" => "00:00:30.00", "out" => "00:01:00.00" },
        { "source_video" => "tutorial_01.mov", "in" => "00:01:20.00", "out" => "00:01:50.00" }
      ]
    }
  }
  let(:candidates) { JSON.parse(File.read(File.join(fixtures, "canned_model_response.json"))) }
  let(:available_templates) { [{ name: "code-callout", readme_md: "" }] }

  def call(opts = {})
    described_class.assemble(
      library_name: "sample-library",
      roughcut_stem: "sample",
      roughcut: roughcut,
      candidates: candidates,
      available_templates: available_templates,
      density: opts.fetch(:density, "medium"),
      score_threshold: opts.fetch(:score_threshold, 0.5)
    )
  end

  it "drops candidates below the score threshold, outside any clip, or with an unknown template" do
    manifest = call
    contents = manifest["entries"].map { |e| e["content"] }
    commands = contents.map { |c| c["command"] }
    expect(commands).to contain_exactly("git rebase -i HEAD~3", "git status")
  end

  it "remaps source-relative timing to rough-cut-relative timing" do
    manifest = call
    rebase = manifest["entries"].find { |e| e["content"]["command"] == "git rebase -i HEAD~3" }
    # source 35.0 - clip[0].in (30.0) = 5.0 into the cut
    expect(rebase["start"]).to eq(5.0)
    expect(rebase["end"]).to eq(10.0)
    status = manifest["entries"].find { |e| e["content"]["command"] == "git status" }
    # clip[0] is 30s long (0..30), clip[1] starts at 30 in the cut
    # source 100.0 - clip[1].in (80.0) = 20.0 into clip[1] -> 30 + 20 = 50.0 in cut
    expect(status["start"]).to eq(50.0)
    expect(status["end"]).to eq(55.0)
  end

  it "assigns sequential ids in time order" do
    manifest = call
    expect(manifest["entries"].map { |e| e["id"] }).to eq(["br-0001", "br-0002"])
    starts = manifest["entries"].map { |e| e["start"] }
    expect(starts).to eq(starts.sort)
  end

  it "applies a density budget per minute" do
    many = (0..9).map do |i|
      {
        "source_video" => "tutorial_01.mov",
        "source_start" => 30.0 + i, "source_end" => 31.0 + i,
        "template" => "code-callout", "placement" => "overlay",
        "content" => { "command" => "cmd_#{i}" },
        "score" => 0.5 + i * 0.05
      }
    end
    manifest = described_class.assemble(
      library_name: "x", roughcut_stem: "y", roughcut: roughcut,
      candidates: many, available_templates: available_templates,
      density: "low", score_threshold: 0.0
    )
    expect(manifest["entries"].length).to eq(2)  # low = 2/min, all in minute 0
    kept = manifest["entries"].map { |e| e["content"]["command"] }
    expect(kept).to contain_exactly("cmd_9", "cmd_8")
  end

  it "produces a manifest that validates via BrollManifest" do
    manifest = call
    expect { ButterCut::BrollManifest.from_hash(manifest) }.not_to raise_error
  end

  it "rejects unsupported density" do
    expect { call(density: "extreme") }.to raise_error(ArgumentError, /density/)
  end
end
```

- [ ] **Step 3: Run the spec, confirm it fails**

Run: `bundle exec rspec spec/buttercut/broll_director_postprocess_spec.rb`
Expected: `LoadError: cannot load such file -- buttercut/broll_director_postprocess`.

- [ ] **Step 4: Implement the post-processor**

`lib/buttercut/broll_director_postprocess.rb`:

```ruby
require_relative "broll_manifest"

class ButterCut
  # Turns candidate JSON from the director model into a validated manifest hash
  # ready for ButterCut::BrollManifest.from_hash. Pure functions only.
  class BrollDirectorPostprocess
    DENSITY_BUDGETS = { "low" => 2, "medium" => 4, "high" => 8 }.freeze

    def self.assemble(library_name:, roughcut_stem:, roughcut:, candidates:,
                      available_templates:, density:, score_threshold:)
      new(
        library_name: library_name,
        roughcut_stem: roughcut_stem,
        roughcut: roughcut,
        candidates: candidates,
        available_templates: available_templates,
        density: density,
        score_threshold: score_threshold
      ).assemble
    end

    def initialize(library_name:, roughcut_stem:, roughcut:, candidates:,
                   available_templates:, density:, score_threshold:)
      @library_name = library_name
      @roughcut_stem = roughcut_stem
      @roughcut = roughcut
      @candidates = candidates
      @template_names = available_templates.map { |t| t[:name] || t["name"] }.to_set
      @budget = DENSITY_BUDGETS.fetch(density) {
        raise ArgumentError, "density must be one of #{DENSITY_BUDGETS.keys.inspect}, got #{density.inspect}"
      }
      @score_threshold = score_threshold.to_f
    end

    def assemble
      mapped = @candidates.filter_map { |c| map_candidate(c) }
      mapped.sort_by! { |e| e["start"] }
      mapped = apply_density(mapped)
      mapped.each_with_index { |e, i| e["id"] = format("br-%04d", i + 1) }
      manifest = {
        "version" => ButterCut::BrollManifest::SCHEMA_VERSION,
        "library" => @library_name,
        "roughcut" => @roughcut_stem,
        "entries" => mapped
      }
      ButterCut::BrollManifest.from_hash(manifest)  # raises if invalid
      manifest
    end

    private

    def map_candidate(c)
      return nil unless @template_names.include?(c["template"])
      score = c["score"].to_f
      return nil if score < @score_threshold

      mapping = locate_in_cut(c)
      return nil if mapping.nil?

      {
        "source_video" => c["source_video"],
        "start" => mapping[:start],
        "end" => mapping[:end],
        "template" => c["template"],
        "placement" => c["placement"],
        "score" => score,
        "content" => c["content"],
        "rendered" => nil,
        "notes" => c["rationale"].to_s
      }
    end

    # Walk the rough cut's clips in order, accumulating a cut-time offset.
    # If [source_start, source_end] falls (even partially) inside a clip
    # of the matching source_video, return its position in the cut.
    def locate_in_cut(c)
      cursor = 0.0
      @roughcut["clips"].each do |clip|
        clip_in = parse_tc(clip["in"])
        clip_out = parse_tc(clip["out"])
        clip_len = clip_out - clip_in

        if clip["source_video"] == c["source_video"]
          s = c["source_start"].to_f
          e = c["source_end"].to_f
          if e > clip_in && s < clip_out
            mapped_start = cursor + [s, clip_in].max - clip_in
            mapped_end   = cursor + [e, clip_out].min - clip_in
            return nil if mapped_end <= mapped_start
            return { start: mapped_start.round(2), end: mapped_end.round(2) }
          end
        end

        cursor += clip_len
      end
      nil
    end

    def parse_tc(tc)
      h, m, s = tc.to_s.split(":")
      h.to_i * 3600 + m.to_i * 60 + s.to_f
    end

    def apply_density(entries)
      buckets = entries.group_by { |e| (e["start"] / 60.0).floor }
      buckets.values.flat_map { |list|
        list.sort_by { |e| -e["score"] }.first(@budget)
      }.sort_by { |e| e["start"] }
    end
  end
end
```

- [ ] **Step 5: Run the spec, confirm it passes**

Run: `bundle exec rspec spec/buttercut/broll_director_postprocess_spec.rb`
Expected: 6 examples, 0 failures.

- [ ] **Step 6: Run the full gem suite to make sure nothing else broke**

Run: `bundle exec rspec`
Expected: all green.

- [ ] **Step 7: Commit**

```bash
git add lib/buttercut/broll_director_postprocess.rb \
        spec/buttercut/broll_director_postprocess_spec.rb \
        spec/fixtures/broll_director/canned_model_response.json
git commit -m "feat: BrollDirectorPostprocess maps candidates to a validated manifest (#30)"
```

---

### Task 3: Skill — `broll-director`

The CLI surface. Parent reads `SKILL.md`, gathers inputs via `BrollDirectorInputs`, dispatches one sub-agent with `agent_prompt.md` inlined, post-processes the returned JSON, and writes the manifest.

**Files:**
- Create: `.claude/skills/broll-director/SKILL.md`
- Create: `.claude/skills/broll-director/agent_prompt.md`

- [ ] **Step 1: Write `agent_prompt.md` (the canonical director prompt)**

`.claude/skills/broll-director/agent_prompt.md`:

````markdown
You are the b-roll director for ButterCut. Your job is to read a rough cut plus the transcripts of the videos it references and decide where motion graphics belong.

You will be given the following values inline by the parent:

- `LIBRARY_NAME` — string
- `ROUGHCUT_STEM` — string
- `ROUGHCUT_YAML` — the rough cut as parsed YAML, with an ordered `clips` array. Each clip has `source_video` (filename), `in` and `out` (HH:MM:SS.ss timecodes into the source video).
- `THEME` — the library's theme block (read-only — affects placement defaults; see below).
- `SOURCE_VIDEOS` — a hash keyed by source_video filename. Each value has:
  - `audio_transcript` — the WhisperX JSON for that video
  - `visual_transcript` — the visual JSON with frame-level descriptions
  - `summary` — a short markdown summary
- `AVAILABLE_TEMPLATES` — array of `{ name, readme_md }`. The README is the source of truth for that template's `content` shape. You MUST only emit candidates whose `template` is one of these names AND whose `content` matches the README.
- `DENSITY` — `"low"` | `"medium"` | `"high"` (informational; the caller enforces a per-minute budget after you return)
- `SCORE_THRESHOLD` — float (informational; the caller drops anything below this)

Return ONLY a JSON array (no surrounding prose, no markdown fence). Each element is one candidate:

```json
{
  "source_video": "tutorial_01.mov",
  "source_start": 42.10,
  "source_end":   47.80,
  "template": "code-callout",
  "placement": "overlay",
  "content": { "command": "git rebase -i HEAD~3", "caption": "Interactive rebase, last 3 commits" },
  "score": 0.84,
  "rationale": "introduces a command verbally; terminal visible at this moment"
}
```

Field rules:

- `source_start`/`source_end` are seconds into the **source video** (not the rough cut). The caller maps these into rough-cut time. Only emit candidates whose `[source_start, source_end]` overlaps a clip in `ROUGHCUT_YAML` for that source_video.
- `template` MUST be in `AVAILABLE_TEMPLATES`. If no template fits, drop the candidate.
- `content` MUST match the chosen template's README schema.
- `placement` is one of `overlay` | `cutaway` | `pip`. Pick by looking at the visual transcript description nearest the candidate's time:
  - terminal/IDE visible AND the graphic relates to what's shown → `overlay`
  - talking head only OR the graphic doesn't relate to what's shown → `cutaway`
  - both are useful AND the source visual should remain partially visible → `pip`
- `score` is `(novelty + emphasis + structural_role) / 3` in `0..1`:
  - novelty — is this term/idea new in the video?
  - emphasis — does the speaker dwell on it, repeat it, or call it out?
  - structural_role — is it a step number, heading, named example, stat, or quote?
- `rationale` is one short sentence explaining the score.

Candidate selection — look for:
- Named commands, files, functions, paths, error messages
- Terms introduced verbally for the first time
- Numbered or bulleted lists ("step one…", "first…", "second…")
- Stats and quotes worth pulling out
- Side-by-side comparisons

Do NOT emit candidates for:
- Generic filler ("um", "you know", "so basically")
- Repetitions of something you already covered nearby
- Anything outside the time spans the rough cut's clips actually include

Return the array. Nothing else.
````

- [ ] **Step 2: Write `SKILL.md` (parent dispatch brief)**

`.claude/skills/broll-director/SKILL.md`:

````markdown
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
````

- [ ] **Step 3: Verify both files load and `agent_prompt.md` is non-trivial**

Run: `wc -l .claude/skills/broll-director/*.md`
Expected: both files exist, agent_prompt is at least 50 lines.

- [ ] **Step 4: Commit**

```bash
git add .claude/skills/broll-director/
git commit -m "feat: broll-director skill (parent brief + canonical agent prompt) (#30)"
```

---

### Task 4: Sidecar — `BrollDirectorController`

UI surface. Mirrors `RoughcutController`'s job/notifier shape; loads the same `agent_prompt.md` as the skill so the two surfaces never drift.

**Files:**
- Create: `ui/sidecar/lib/buttercut_ui_sidecar/broll_director_controller.rb`
- Create: `ui/sidecar/spec/lib/buttercut_ui_sidecar/broll_director_controller_spec.rb`

- [ ] **Step 1: Write the failing spec**

`ui/sidecar/spec/lib/buttercut_ui_sidecar/broll_director_controller_spec.rb`:

```ruby
require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"
require "yaml"
require "buttercut_ui_sidecar/broll_director_controller"

RSpec.describe ButtercutUiSidecar::BrollDirectorController do
  let(:repo_root) { File.expand_path("../../../../..", __dir__) }
  let(:notifier) { double("notifier", notify: nil) }
  let(:registry) {
    Class.new {
      def initialize; @jobs = {}; end
      def create(_); id = "job-#{@jobs.size + 1}"; @jobs[id] = { canceled: false }; id; end
      def canceled?(id); @jobs[id][:canceled]; end
    }.new
  }

  let(:fixture_lib) {
    File.expand_path("../../../../../spec/fixtures/broll_director/sample_library", __dir__)
  }

  def with_libraries_root
    Dir.mktmpdir do |tmp|
      FileUtils.cp_r(fixture_lib, File.join(tmp, "sample-library"))
      yield Pathname.new(tmp)
    end
  end

  it "writes a validated manifest using a stubbed model response" do
    canned = File.read(File.expand_path(
      "../../../../../spec/fixtures/broll_director/canned_model_response.json", __dir__
    ))
    client = double("anthropic_client")
    allow(client).to receive(:complete).and_return(canned)

    with_libraries_root do |root|
      controller = described_class.new(
        libraries_root: root.to_s,
        repo_root: repo_root,
        notifier: notifier,
        registry: registry,
        client: client
      )
      result = controller.run!(
        library: "sample-library",
        roughcut_stem: "sample",
        density: "medium",
        score_threshold: 0.5
      )

      expect(result[:entries_written]).to be > 0
      manifest_path = root.join("sample-library/roughcuts/sample.broll.yaml")
      expect(manifest_path.file?).to be true
      data = YAML.safe_load(manifest_path.read, permitted_classes: [Date, Time])
      expect(data["library"]).to eq("sample-library")
      expect(data["roughcut"]).to eq("sample")
      expect(data["entries"]).not_to be_empty
    end
  end

  it "raises when the rough cut does not exist" do
    with_libraries_root do |root|
      controller = described_class.new(
        libraries_root: root.to_s, repo_root: repo_root,
        notifier: notifier, registry: registry,
        client: double("c")
      )
      expect {
        controller.run!(library: "sample-library", roughcut_stem: "nope",
                        density: "medium", score_threshold: 0.5)
      }.to raise_error(/rough cut not found/)
    end
  end
end
```

- [ ] **Step 2: Run the spec, confirm it fails**

Run: `cd ui/sidecar && bundle exec rspec spec/lib/buttercut_ui_sidecar/broll_director_controller_spec.rb`
Expected: `LoadError: cannot load such file -- buttercut_ui_sidecar/broll_director_controller`.

- [ ] **Step 3: Implement the controller**

`ui/sidecar/lib/buttercut_ui_sidecar/broll_director_controller.rb`:

```ruby
# frozen_string_literal: true

require "json"
require "pathname"
require "yaml"

require "buttercut/broll_director_inputs"
require "buttercut/broll_director_postprocess"
require "buttercut/broll_manifest"

require_relative "anthropic_client"

module ButtercutUiSidecar
  # UI-driven b-roll director. Mirrors RoughcutController's shape; loads the
  # same agent prompt as the broll-director skill so behavior cannot drift.
  class BrollDirectorController
    PROMPT_RELATIVE_PATH = ".claude/skills/broll-director/agent_prompt.md"
    DEFAULT_DENSITY = "medium"
    DEFAULT_SCORE_THRESHOLD = 0.5
    MODEL = AnthropicClient::VISION_MODEL

    def initialize(libraries_root:, repo_root:, notifier:, registry:, client:)
      raise ArgumentError, "libraries_root required" if libraries_root.to_s.empty?
      raise ArgumentError, "repo_root required" if repo_root.to_s.empty?
      raise ArgumentError, "notifier required" if notifier.nil?
      raise ArgumentError, "registry required" if registry.nil?
      raise ArgumentError, "client required" if client.nil?

      @libraries_root = Pathname.new(libraries_root)
      @repo_root = Pathname.new(repo_root)
      @notifier = notifier
      @registry = registry
      @client = client
    end

    def validate_and_start!(library:, roughcut_stem:, density: DEFAULT_DENSITY,
                            score_threshold: DEFAULT_SCORE_THRESHOLD)
      job_id = @registry.create(library)
      Thread.new do
        begin
          run!(
            library: library, roughcut_stem: roughcut_stem,
            density: density, score_threshold: score_threshold,
            job_id: job_id
          )
        rescue StandardError => e
          warn "[broll-director #{job_id}] FAILED #{e.class}: #{e.message}"
          @notifier.notify("broll_job_failed", job_id: job_id, message: e.message)
        end
      end
      job_id
    end

    def run!(library:, roughcut_stem:, density:, score_threshold:, job_id: nil)
      lib_dir = @libraries_root.join(library)
      roughcut_path = lib_dir.join("roughcuts", "#{roughcut_stem}.yaml")
      raise "rough cut not found at #{roughcut_path}" unless roughcut_path.file?

      notify(job_id, "broll_job_started", library: library, roughcut_stem: roughcut_stem)
      notify(job_id, "broll_phase", phase: "gather", message: "Gathering transcripts and templates…")

      inputs = ButterCut::BrollDirectorInputs.gather(
        library_dir: lib_dir.to_s,
        roughcut_path: roughcut_path.to_s,
        hyperframes_dir: @repo_root.join("hyperframes").to_s
      )

      notify(job_id, "broll_phase", phase: "model", message: "Asking the director for candidates…")
      raw = call_model(inputs, density, score_threshold)
      candidates = parse_or_retry(raw, inputs, density, score_threshold)

      notify(job_id, "broll_phase", phase: "write", message: "Validating and writing manifest…")
      manifest_hash = ButterCut::BrollDirectorPostprocess.assemble(
        library_name: inputs[:library_name],
        roughcut_stem: inputs[:roughcut_stem],
        roughcut: inputs[:roughcut],
        candidates: candidates,
        available_templates: inputs[:available_templates],
        density: density,
        score_threshold: score_threshold
      )

      manifest_path = lib_dir.join("roughcuts", "#{roughcut_stem}.broll.yaml")
      warn_if_overwriting(manifest_path)
      ButterCut::BrollManifest.from_hash(manifest_hash).save(manifest_path.to_s)

      notify(job_id, "broll_job_done",
             manifest_path: manifest_path.to_s,
             entries_written: manifest_hash["entries"].length,
             density: density)

      { manifest_path: manifest_path.to_s, entries_written: manifest_hash["entries"].length }
    end

    private

    def notify(job_id, event, **payload)
      return if job_id.nil?
      @notifier.notify(event, job_id: job_id, **payload)
    end

    def call_model(inputs, density, score_threshold)
      system = prompt_text
      user = JSON.pretty_generate(
        LIBRARY_NAME: inputs[:library_name],
        ROUGHCUT_STEM: inputs[:roughcut_stem],
        ROUGHCUT_YAML: inputs[:roughcut],
        THEME: inputs[:theme],
        SOURCE_VIDEOS: inputs[:source_videos],
        AVAILABLE_TEMPLATES: inputs[:available_templates],
        DENSITY: density,
        SCORE_THRESHOLD: score_threshold
      )
      @client.complete(system: system, user: user, model: MODEL)
    end

    def parse_or_retry(raw, inputs, density, score_threshold)
      JSON.parse(raw)
    rescue JSON::ParserError => e
      retry_user = "Your previous response was not valid JSON: #{e.message}\n\nReturn ONLY the JSON array, no surrounding text."
      raw2 = @client.complete(system: prompt_text, user: retry_user, model: MODEL)
      JSON.parse(raw2)
    end

    def prompt_text
      path = @repo_root.join(PROMPT_RELATIVE_PATH)
      raise "broll-director prompt missing: #{path}" unless path.file?
      path.read
    end

    def warn_if_overwriting(path)
      return unless path.file?
      prior = YAML.safe_load(path.read, permitted_classes: [Date, Time]) rescue {}
      n = (prior["entries"] || []).length
      warn "[broll-director] overwriting existing manifest at #{path} (#{n} prior entries)"
    end
  end
end
```

- [ ] **Step 4: Add `complete` to `AnthropicClient` if it doesn't exist yet**

Run: `grep -n "def complete\|def call\|def messages" ui/sidecar/lib/buttercut_ui_sidecar/anthropic_client.rb`

If `complete(system:, user:, model:)` already exists, skip. Otherwise add it. Open the file and inspect; if missing, add at the bottom of the class:

```ruby
def complete(system:, user:, model:)
  resp = messages.create(
    model: model,
    max_tokens: 8192,
    system: system,
    messages: [{ role: "user", content: user }]
  )
  resp.content.map { |b| b.respond_to?(:text) ? b.text : b["text"] }.compact.join
end
```

(Use whatever method on the existing client equates to "send a single user message and return the text" — the test stubs `complete` directly, so the spec passes regardless of how the production method is named, but production code in `BrollDirectorController#call_model` MUST call the real method that exists. If the existing client uses a different name, change `call_model` to call that name and stub that name in the spec.)

- [ ] **Step 5: Run the spec, confirm it passes**

Run: `cd ui/sidecar && bundle exec rspec spec/lib/buttercut_ui_sidecar/broll_director_controller_spec.rb`
Expected: 2 examples, 0 failures.

- [ ] **Step 6: Run the full sidecar suite**

Run: `cd ui/sidecar && bundle exec rspec`
Expected: all green.

- [ ] **Step 7: Commit**

```bash
git add ui/sidecar/lib/buttercut_ui_sidecar/broll_director_controller.rb \
        ui/sidecar/spec/lib/buttercut_ui_sidecar/broll_director_controller_spec.rb \
        ui/sidecar/lib/buttercut_ui_sidecar/anthropic_client.rb
git commit -m "feat: BrollDirectorController for the UI surface (#30)"
```

---

### Task 5: Sidecar — register the `start_broll_director` op

Wire the controller into the sidecar's op dispatch (the JSON-RPC-style switch in `buttercut_ui_sidecar.rb`).

**Files:**
- Modify: `ui/sidecar/buttercut_ui_sidecar.rb`

- [ ] **Step 1: Add the require**

Find the line `require_relative "lib/buttercut_ui_sidecar/roughcut_controller"` and add immediately after:

```ruby
require_relative "lib/buttercut_ui_sidecar/broll_director_controller"
```

- [ ] **Step 2: Add the op handler**

Find the `case op` switch with `when "start_roughcut"` and add a new branch immediately below the `when "export_roughcut_artifacts"` branch:

```ruby
when "start_broll_director"
  broll_director_start(params)
```

- [ ] **Step 3: Add the handler method**

Add a new method, modeled on `roughcut_start`, immediately after the `roughcut_start` method:

```ruby
def broll_director_start(params)
  lib = params.fetch("library")
  library_dir(lib)
  api_key = @settings.api_key
  raise StandardError, "missing_api_key" if api_key.nil? || api_key.empty?

  client = ButtercutUiSidecar::AnthropicClient.new(api_key: api_key)
  controller = ButtercutUiSidecar::BrollDirectorController.new(
    libraries_root: @libraries_root.to_s,
    repo_root: @repo_root.to_s,
    notifier: @notifier,
    registry: @registry,
    client: client
  )
  controller.validate_and_start!(
    library: lib,
    roughcut_stem: params.fetch("roughcut_stem"),
    density: params["density"] || ButtercutUiSidecar::BrollDirectorController::DEFAULT_DENSITY,
    score_threshold: params["score_threshold"] || ButtercutUiSidecar::BrollDirectorController::DEFAULT_SCORE_THRESHOLD
  )
end
```

- [ ] **Step 4: Run the sidecar suite to confirm nothing regressed**

Run: `cd ui/sidecar && bundle exec rspec`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add ui/sidecar/buttercut_ui_sidecar.rb
git commit -m "feat: register start_broll_director op (#30)"
```

---

### Task 6: UI — `AddBrollButton` component

A small button that POSTs `start_broll_director` and listens for `broll_phase` / `broll_job_done` / `broll_job_failed` events.

**Files:**
- Create: `ui/src/routes/library/AddBrollButton.tsx`

- [ ] **Step 1: Read sibling files for component conventions**

Run: `cat ui/src/routes/library/RoughcutTimeline.tsx | head -80`

You need to know how existing buttons are styled (className conventions), how the sidecar IPC client is imported, and how phase events are subscribed to. Look for an existing button-with-job-progress pattern (search for `start_roughcut` usage) and mirror it.

- [ ] **Step 2: Create the component**

`ui/src/routes/library/AddBrollButton.tsx`:

```tsx
import { useState, useEffect } from "react";
// Import the sidecar client + event subscription helper using whatever
// import path the existing buttons (e.g. the one that fires start_roughcut)
// use. If the project has a useSidecar() hook, prefer it.

type Props = {
  library: string;
  roughcutStem: string;
  hasManifest: boolean;
  manifestEntryCount?: number;
};

type Phase = "idle" | "gather" | "model" | "write" | "done" | "error";

export function AddBrollButton({ library, roughcutStem, hasManifest, manifestEntryCount }: Props) {
  const [phase, setPhase] = useState<Phase>("idle");
  const [message, setMessage] = useState<string>("");
  const [entries, setEntries] = useState<number | undefined>(manifestEntryCount);

  useEffect(() => {
    // Subscribe to broll_* events. Replace this with the actual subscription
    // helper used elsewhere in this codebase (search for "roughcut_phase" to
    // find the pattern). Filter by roughcutStem to ignore other rough cuts'
    // jobs.
    const unsubscribe = subscribeToSidecarEvents((event: any) => {
      if (event.roughcut_stem && event.roughcut_stem !== roughcutStem) return;
      switch (event.type) {
        case "broll_phase":
          setPhase(event.phase as Phase);
          setMessage(event.message ?? "");
          break;
        case "broll_job_done":
          setPhase("done");
          setEntries(event.entries_written);
          setMessage(`${event.entries_written} graphics ready to render`);
          break;
        case "broll_job_failed":
          setPhase("error");
          setMessage(event.message ?? "Director failed");
          break;
      }
    });
    return unsubscribe;
  }, [roughcutStem]);

  const running = phase !== "idle" && phase !== "done" && phase !== "error";

  const handleClick = async () => {
    if (running) return;
    setPhase("gather");
    setMessage("Starting…");
    try {
      await callSidecar("start_broll_director", {
        library,
        roughcut_stem: roughcutStem,
      });
    } catch (err: any) {
      setPhase("error");
      setMessage(err?.message ?? String(err));
    }
  };

  const label = (() => {
    if (running) return message || "Working…";
    if (phase === "done") return `B-Roll ready (${entries})`;
    if (phase === "error") return `Failed — retry`;
    if (hasManifest) return `Re-run B-Roll Director (${manifestEntryCount ?? "?"} entries)`;
    return "Add B-Roll";
  })();

  return (
    <button
      type="button"
      className="add-broll-button"
      disabled={running}
      onClick={handleClick}
      aria-busy={running}
      title={hasManifest ? "Replaces existing manifest" : "Generate b-roll manifest from this rough cut"}
    >
      {label}
    </button>
  );
}

// --- Replace these with actual project utilities ---
declare function callSidecar(op: string, params: Record<string, unknown>): Promise<any>;
declare function subscribeToSidecarEvents(handler: (event: any) => void): () => void;
```

> **Note for the engineer:** The two `declare function` lines at the bottom are placeholders for whatever IPC + event-bus utilities this project actually exposes. **Delete them and replace the imports/calls with the real ones the existing buttons use.** Search `ui/src` for an existing button that fires `start_roughcut` to see the pattern.

- [ ] **Step 3: Commit**

```bash
git add ui/src/routes/library/AddBrollButton.tsx
git commit -m "feat: AddBrollButton component (#30)"
```

---

### Task 7: UI — wire button into `RoughcutTimeline.tsx`

Render the button on each finished rough cut row. A "finished" rough cut is one whose YAML exists; whether it has a manifest yet drives the button label.

**Files:**
- Modify: `ui/src/routes/library/RoughcutTimeline.tsx`

- [ ] **Step 1: Inspect the file to find where rough cut rows render**

Run: `wc -l ui/src/routes/library/RoughcutTimeline.tsx && grep -n "roughcut\|fcpxml\|export\|button" ui/src/routes/library/RoughcutTimeline.tsx | head -40`

Identify the JSX block that renders the per-rough-cut artifacts (YAML link, XML link, etc.). The button goes there.

- [ ] **Step 2: Import and render the button**

At the top of the file:

```tsx
import { AddBrollButton } from "./AddBrollButton";
```

In the per-rough-cut row JSX, immediately after the existing artifact links/buttons for that row, add:

```tsx
<AddBrollButton
  library={libraryName}
  roughcutStem={roughcut.stem}
  hasManifest={Boolean(roughcut.brollManifest)}
  manifestEntryCount={roughcut.brollManifest?.entryCount}
/>
```

> **Note for the engineer:** if `roughcut.brollManifest` is not already a field on the rough cut row's data, pass `hasManifest={false}` for now and file a follow-up to surface the count from the sidecar's library listing. The button still works (it just always shows "Add B-Roll" / never the entry count).

- [ ] **Step 3: Verify the file still type-checks**

Run: `cd ui && pnpm tsc --noEmit` (or whatever this project's typecheck command is — check `ui/package.json` scripts).
Expected: no new TypeScript errors.

- [ ] **Step 4: Commit**

```bash
git add ui/src/routes/library/RoughcutTimeline.tsx
git commit -m "feat: surface AddBrollButton on each finished rough cut row (#30)"
```

---

### Task 8: End-to-end smoke check

Run the full test suites and a manual smoke through the skill on the fixture library to confirm the slice works.

- [ ] **Step 1: Run the gem suite**

Run: `bundle exec rspec`
Expected: all green.

- [ ] **Step 2: Run the sidecar suite**

Run: `cd ui/sidecar && bundle exec rspec`
Expected: all green.

- [ ] **Step 3: Manual skill smoke (no API key required)**

The director is exercised end-to-end by the controller spec (which uses a stubbed model response). For a real end-to-end run with the live model, the user can invoke the skill on a real library — that is not part of this plan's acceptance because it requires API spend.

Document this clearly in the PR body: "automated coverage stops at the post-processing layer; live-model exercise is a manual smoke."

- [ ] **Step 4: Confirm acceptance criteria from issue #30**

Tick off each item in the spec's "Acceptance" section against the implementation:

- Output validates against PR #25 schema → `BrollDirectorPostprocess` calls `BrollManifest.from_hash` before write
- Sub-agent contract: no library.yaml reads/writes → parent (skill) and controller (UI) both gather inputs; sub-agent receives only inline values
- Smoke test on a sample tutorial transcript produces non-empty, well-typed manifest → `BrollDirectorController` spec runs the full pipeline against the canned model response

Plus the spec's extra acceptance items:

- UI button on each finished rough cut row produces the same manifest as the skill for the same inputs → both surfaces share `agent_prompt.md` + `BrollDirectorInputs` + `BrollDirectorPostprocess`
- Re-running overwrites with a warning; existing renders untouched → `BrollDirectorController#warn_if_overwriting` + skill brief documents the behavior

- [ ] **Step 5: Open the PR**

Branch off `main` (or whatever the current sprint branch is — check `git status`), push, and open a PR titled `feat: b-roll director (skill + UI button) (#30)`. Body should reference the spec and plan paths and the issue number.

---

## Self-Review Notes

- Spec coverage: every section of the design doc maps to a task — gathering helper (Task 1), post-processing helper (Task 2), skill (Task 3), sidecar controller (Task 4), op registration (Task 5), button (Task 6), wiring (Task 7), acceptance (Task 8).
- Type consistency: `BrollDirectorInputs.gather` returns the keys `:library_name`, `:roughcut_stem`, `:roughcut`, `:theme`, `:source_videos`, `:available_templates` — used identically in the postprocess spec and the controller.
- Placeholder check: Task 6 explicitly flags the IPC import as a project-specific replacement. No other placeholders.
- Risk explicitly noted in plan body: Task 4 Step 4 asks the engineer to verify the AnthropicClient method name; the spec stubs are robust to either name.
