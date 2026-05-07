# Roughcut B-Roll Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Teach the rough-cut export pipeline to ingest a sibling `<roughcut>.broll.yaml`, load each entry's rendered MP4, and place it on the timeline at the manifest-specified timing — closing the foundational vertical slice of the Hyperframes epic (#26 / issue #33).

**Architecture:** Every placement (overlay/cutaway/pip) emits as a connected/lane-1 clip on top of the V1 spine — V1 spine and recipe clip indices are never touched. PiP carries optional `pip_corner` + `pip_scale` fields driving an `<adjust-transform>` (FCPX) or Motion `<filter>` (xmeml). All b-roll audio is muted: V1 audio bed continues underneath. Discovery is by sibling-file convention so empty/absent manifests are byte-identical to today.

**Tech Stack:** Ruby (gem code + scripts), RSpec, Nokogiri (XML emission), YAML (manifest), JSON (recipe). No new runtime deps.

**Spec:** `docs/superpowers/specs/2026-05-06-roughcut-broll-integration-design.md`

---

## File Structure

**Create:**
- `lib/buttercut/overlay.rb` — `ButterCut::Overlay` value class. Parses one raw overlay hash from `ButterCut.new(overlays: …)` into a normalized record; computes pip transform fractions (scale, x-offset, y-offset) from `pip_corner`/`pip_scale`; validates fields.
- `spec/buttercut/overlay_spec.rb`
- `spec/buttercut/fcpx_overlay_spec.rb`
- `spec/buttercut/fcp7_overlay_spec.rb`
- `spec/buttercut/export_to_fcpxml_broll_spec.rb` — end-to-end discovery + emission.
- `spec/fixtures/broll_integration/sample_roughcut.yaml`
- `spec/fixtures/broll_integration/sample_roughcut.broll.yaml`

**Modify:**
- `lib/buttercut.rb` — `ButterCut.new(clips, editor:, overlays: nil)`.
- `lib/buttercut/editor_base.rb` — `attr_reader :overlays`; accept and normalize the kwarg in `initialize`; ffprobe pre-cache extended to overlay sources.
- `lib/buttercut/fcpx.rb` — emit lane-1 connected clips, optional `<adjust-transform>` for pip, `<adjust-volume amount="-96dB"/>` to mute.
- `lib/buttercut/fcp7.rb` — emit a V2 `<track>` (and V3 only when needed for stacked simultaneous overlays); Motion filter for pip; muted audio track on V2.
- `lib/buttercut/broll_manifest.rb` — `SCHEMA_VERSION` 2; accept v1 with deprecation warning; validate `pip_corner`/`pip_scale`.
- `lib/buttercut/recipe.rb` — `SCHEMA_VERSION` 3; `SUPPORTED_VERSIONS = [1, 2, 3]`; optional top-level `broll` array.
- `.claude/skills/roughcut/export_to_fcpxml.rb` — discover sibling broll.yaml, build `overlays:`.
- `.claude/skills/roughcut/recipe_from_roughcut.rb` — when manifest present, attach `broll` array to recipe hash.
- `.claude/skills/roughcut/generate_apply_script.rb` — log b-roll clip count if present.
- `spec/broll_manifest_spec.rb` — extend with v2 cases.
- `spec/recipe_spec.rb` — extend with v3 cases.
- `spec/recipe_from_roughcut_spec.rb` — extend with broll-array case.
- `templates/broll_template.yaml` — bump version comment, document pip fields.
- `CLAUDE.md` — one-line update in the rough-cut artifacts paragraph.

---

## Conventions

- Ruby style follows CLAUDE.md "Programming Style": one class per file, single class-method entry point, small private helpers, required args raise `ArgumentError` in `initialize`.
- Tests are RSpec; mirror shape of `spec/broll_manifest_spec.rb` and `spec/recipe_spec.rb`.
- Commits per task; commit message format follows recent commits (`feat:`, `docs:`, `test:`).
- TDD: write failing test → run it → implement → run again. Don't skip the "watch it fail" step.

---

## Task 0: Worktree + branch

**Files:** none — environment.

- [ ] **Step 1: Create worktree**

```bash
git worktree add ../buttercut-broll-integration -b feat/broll-integration main
cd ../buttercut-broll-integration
```

- [ ] **Step 2: Verify baseline tests pass**

```bash
bundle install
bundle exec rspec
```

Expected: all green. We start from a clean baseline so any future failures are new.

---

## Task 1: BrollManifest schema v2 — pip fields

**Files:**
- Modify: `lib/buttercut/broll_manifest.rb`
- Modify: `spec/broll_manifest_spec.rb`

- [ ] **Step 1: Add failing tests for pip field validation**

Append inside the `RSpec.describe ButterCut::BrollManifest` block in `spec/broll_manifest_spec.rb`:

```ruby
  describe "schema v2 pip fields" do
    let(:pip_entry) do
      {
        "id" => "br-9001",
        "source_video" => "tutorial_01.mov",
        "start" => 10.0,
        "end" => 14.0,
        "template" => "code-callout",
        "placement" => "pip",
        "pip_corner" => "top_right",
        "pip_scale" => 0.33,
        "content" => { "command" => "ls" },
        "rendered" => nil
      }
    end

    let(:v2_hash) do
      {
        "version" => 2,
        "library" => "tutorial-series",
        "roughcut" => "tutorial_ep1",
        "entries" => [pip_entry]
      }
    end

    it "accepts version 2" do
      expect { described_class.from_hash(v2_hash) }.not_to raise_error
    end

    it "accepts pip entry with valid pip_corner and pip_scale" do
      expect { described_class.from_hash(v2_hash) }.not_to raise_error
    end

    it "defaults pip_corner and pip_scale to nil when omitted on a pip entry" do
      bare = pip_entry.dup
      bare.delete("pip_corner")
      bare.delete("pip_scale")
      expect { described_class.from_hash(v2_hash.merge("entries" => [bare])) }.not_to raise_error
    end

    it "rejects pip_corner outside the enum" do
      bad = pip_entry.merge("pip_corner" => "middle")
      expect {
        described_class.from_hash(v2_hash.merge("entries" => [bad]))
      }.to raise_error(ArgumentError, /pip_corner/)
    end

    it "rejects pip_scale outside 0.05..0.95" do
      bad = pip_entry.merge("pip_scale" => 1.2)
      expect {
        described_class.from_hash(v2_hash.merge("entries" => [bad]))
      }.to raise_error(ArgumentError, /pip_scale/)

      tiny = pip_entry.merge("pip_scale" => 0.01)
      expect {
        described_class.from_hash(v2_hash.merge("entries" => [tiny]))
      }.to raise_error(ArgumentError, /pip_scale/)
    end

    it "rejects pip_corner on a non-pip entry" do
      overlay_with_pip = pip_entry.merge("placement" => "overlay")
      expect {
        described_class.from_hash(v2_hash.merge("entries" => [overlay_with_pip]))
      }.to raise_error(ArgumentError, /pip_corner.*only valid.*pip/)
    end

    it "rejects pip_scale on a non-pip entry" do
      overlay_with_scale = pip_entry.merge("placement" => "cutaway").tap { |h| h.delete("pip_corner") }
      expect {
        described_class.from_hash(v2_hash.merge("entries" => [overlay_with_scale]))
      }.to raise_error(ArgumentError, /pip_scale.*only valid.*pip/)
    end

    it "accepts version 1 with a deprecation warning" do
      v1 = v2_hash.merge("version" => 1)
      expect { described_class.from_hash(v1) }.to output(/version 1.*deprecated/i).to_stderr
    end

    it "rejects unknown versions" do
      expect {
        described_class.from_hash(v2_hash.merge("version" => 99))
      }.to raise_error(ArgumentError, /version/)
    end
  end
```

- [ ] **Step 2: Run tests — expect failures**

```bash
bundle exec rspec spec/broll_manifest_spec.rb
```

Expected: the new examples fail (current code requires version == 1 exactly and rejects unknown keys silently or emits no warning).

- [ ] **Step 3: Implement schema v2 in `lib/buttercut/broll_manifest.rb`**

Replace the file with:

```ruby
require 'yaml'
require 'date'

class ButterCut
  # B-roll manifest emitted by the director and consumed by the render skill
  # and roughcut integration. One entry per generated graphic. See
  # templates/broll_template.yaml for the canonical schema example.
  class BrollManifest
    SCHEMA_VERSION = 2
    SUPPORTED_VERSIONS = [1, 2].freeze

    PLACEMENTS = %w[overlay cutaway pip].freeze
    PIP_CORNERS = %w[top_right top_left bottom_right bottom_left].freeze
    PIP_SCALE_MIN = 0.05
    PIP_SCALE_MAX = 0.95

    def self.from_hash(hash)
      raise ArgumentError, "manifest hash required" unless hash.is_a?(Hash)

      new(
        version: hash["version"],
        library: hash["library"],
        roughcut: hash["roughcut"],
        entries: hash["entries"]
      )
    end

    def self.load(path)
      from_hash(YAML.load_file(path, permitted_classes: [Date, Time, Symbol]))
    end

    def initialize(version:, library:, roughcut:, entries:)
      @version = version
      @library = library
      @roughcut = roughcut
      @entries = entries

      validate!
      warn_if_legacy_version!
    end

    attr_reader :version, :library, :roughcut, :entries

    def to_h
      {
        "version" => @version,
        "library" => @library,
        "roughcut" => @roughcut,
        "entries" => @entries
      }
    end

    def save(path)
      File.write(path, to_h.to_yaml)
    end

    private

    def validate!
      validate_version!
      validate_string!(@library, "library")
      unless @roughcut.is_a?(String)
        raise ArgumentError, "roughcut required (string, may be empty); got #{@roughcut.inspect}"
      end
      validate_entries!
    end

    def validate_version!
      unless SUPPORTED_VERSIONS.include?(@version)
        raise ArgumentError, "version must be one of #{SUPPORTED_VERSIONS.inspect}, got #{@version.inspect}"
      end
    end

    def warn_if_legacy_version!
      return unless @version == 1
      warn "[BrollManifest] version 1 is deprecated; please upgrade to version #{SCHEMA_VERSION}."
    end

    def validate_string!(value, field)
      raise ArgumentError, "#{field} required" if !value.is_a?(String) || value.empty?
    end

    def validate_non_negative_number!(value, field)
      raise ArgumentError, "#{field} must be a non-negative number, got #{value.inspect}" unless value.is_a?(Numeric) && value >= 0
    end

    def validate_entries!
      raise ArgumentError, "entries must be an array" unless @entries.is_a?(Array)

      @entries.each { |entry| validate_entry!(entry) }

      ids = @entries.map { |e| e["id"] }
      duplicates = ids.tally.select { |_, count| count > 1 }.keys
      unless duplicates.empty?
        raise ArgumentError, "entry ids must be unique, duplicates: #{duplicates.inspect}"
      end
    end

    def validate_entry!(entry)
      raise ArgumentError, "entry must be a hash" unless entry.is_a?(Hash)

      validate_string!(entry["id"], "entry id")
      id = entry["id"]
      validate_string!(entry["source_video"], "entry #{id} source_video")
      validate_string!(entry["template"], "entry #{id} template")

      validate_non_negative_number!(entry["start"], "entry #{id} start")
      validate_non_negative_number!(entry["end"], "entry #{id} end")
      unless entry["end"] > entry["start"]
        raise ArgumentError, "entry #{id} end (#{entry["end"]}) must be greater than start (#{entry["start"]})"
      end

      placement = entry["placement"]
      unless PLACEMENTS.include?(placement)
        raise ArgumentError, "entry #{id} placement #{placement.inspect} not in #{PLACEMENTS.inspect}"
      end

      validate_pip_fields!(entry, id, placement)

      if entry.key?("score") && !entry["score"].nil?
        score = entry["score"]
        unless score.is_a?(Numeric) && score >= 0 && score <= 1
          raise ArgumentError, "entry #{id} score must be in 0..1, got #{score.inspect}"
        end
      end

      content = entry["content"]
      raise ArgumentError, "entry #{id} content must be a hash" unless content.is_a?(Hash)
      raise ArgumentError, "entry #{id} content must not be empty" if content.empty?

      if entry.key?("rendered") && !entry["rendered"].nil?
        validate_string!(entry["rendered"], "entry #{id} rendered")
      end

      if entry.key?("notes") && !entry["notes"].nil? && !entry["notes"].is_a?(String)
        raise ArgumentError, "entry #{id} notes must be a string"
      end
    end

    def validate_pip_fields!(entry, id, placement)
      has_corner = entry.key?("pip_corner") && !entry["pip_corner"].nil?
      has_scale  = entry.key?("pip_scale")  && !entry["pip_scale"].nil?

      if placement != "pip"
        if has_corner
          raise ArgumentError, "entry #{id} pip_corner only valid when placement is pip"
        end
        if has_scale
          raise ArgumentError, "entry #{id} pip_scale only valid when placement is pip"
        end
        return
      end

      if has_corner && !PIP_CORNERS.include?(entry["pip_corner"])
        raise ArgumentError, "entry #{id} pip_corner #{entry["pip_corner"].inspect} not in #{PIP_CORNERS.inspect}"
      end

      if has_scale
        scale = entry["pip_scale"]
        unless scale.is_a?(Numeric) && scale >= PIP_SCALE_MIN && scale <= PIP_SCALE_MAX
          raise ArgumentError, "entry #{id} pip_scale must be in #{PIP_SCALE_MIN}..#{PIP_SCALE_MAX}, got #{scale.inspect}"
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run tests — expect green**

```bash
bundle exec rspec spec/broll_manifest_spec.rb
```

Expected: all green (existing v1 tests still pass; new v2 tests pass; v1 emits the deprecation warning).

- [ ] **Step 5: Commit**

```bash
git add lib/buttercut/broll_manifest.rb spec/broll_manifest_spec.rb
git commit -m "feat: BrollManifest schema v2 with pip_corner/pip_scale (#33)"
```

---

## Task 2: Recipe schema v3 — optional `broll` array

**Files:**
- Modify: `lib/buttercut/recipe.rb`
- Modify: `spec/recipe_spec.rb`

- [ ] **Step 1: Add failing tests**

Append inside `spec/recipe_spec.rb` (mirroring existing test style):

```ruby
  describe "schema v3 broll array" do
    let(:base_v3) do
      {
        "version" => 3,
        "library" => "tutorial-series",
        "timeline" => "tutorial_ep1",
        "clips" => [{ "index" => 1, "source_file" => "tutorial_01.mov" }]
      }
    end

    let(:broll_entry) do
      {
        "id" => "br-0001",
        "start" => 42.10,
        "end" => 47.80,
        "placement" => "overlay",
        "source" => "broll/br-0001.mp4",
        "source_video" => "tutorial_01.mov"
      }
    end

    it "accepts version 3" do
      expect { described_class.from_hash(base_v3) }.not_to raise_error
    end

    it "round-trips an optional broll array through to_h" do
      h = base_v3.merge("broll" => [broll_entry])
      recipe = described_class.from_hash(h)
      expect(recipe.to_h["broll"]).to eq([broll_entry])
    end

    it "omits broll from to_h when absent" do
      recipe = described_class.from_hash(base_v3)
      expect(recipe.to_h).not_to have_key("broll")
    end

    it "rejects malformed broll entries" do
      bad = base_v3.merge("broll" => [{ "id" => "br-0001" }])
      expect { described_class.from_hash(bad) }.to raise_error(ArgumentError, /broll/)
    end

    it "rejects placement outside the enum" do
      bad = base_v3.merge("broll" => [broll_entry.merge("placement" => "weird")])
      expect { described_class.from_hash(bad) }.to raise_error(ArgumentError, /placement/)
    end
  end
```

- [ ] **Step 2: Run tests — expect failures**

```bash
bundle exec rspec spec/recipe_spec.rb
```

Expected: new examples fail (`SCHEMA_VERSION` is 2, no `broll` handling).

- [ ] **Step 3: Implement schema v3 in `lib/buttercut/recipe.rb`**

Apply the following edits:

1. Bump constants near the top of the class:

```ruby
SCHEMA_VERSION = 3
SUPPORTED_VERSIONS = [1, 2, 3].freeze
BROLL_PLACEMENTS = %w[overlay cutaway pip].freeze
```

2. Extend `self.from_hash` to read `broll`:

```ruby
def self.from_hash(hash, fuse_library: nil)
  raise ArgumentError, "recipe hash required" unless hash.is_a?(Hash)

  new(
    version: hash["version"],
    library: hash["library"],
    timeline: hash["timeline"],
    clips: hash["clips"],
    render_preset: hash["render_preset"],
    powergrade: hash["powergrade"],
    transitions: hash.key?("transitions") ? hash["transitions"] : [],
    title_card: hash["title_card"],
    broll: hash.key?("broll") ? hash["broll"] : nil,
    fuse_library: fuse_library
  )
end
```

3. Update `initialize` signature + ivar:

```ruby
def initialize(version:, library:, timeline:, clips:, render_preset: nil, powergrade: nil, transitions: [], title_card: nil, broll: nil, fuse_library: nil)
  @version = version
  @library = library
  @timeline = timeline
  @clips = clips
  @render_preset = render_preset
  @powergrade = powergrade
  @transitions = transitions
  @title_card = title_card
  @broll = broll
  @fuse_library = fuse_library

  validate!
end
```

4. Extend `to_h` to emit `broll` when present:

```ruby
def to_h
  h = {
    "version" => @version,
    "library" => @library,
    "timeline" => @timeline
  }
  h["render_preset"] = @render_preset if @render_preset
  h["powergrade"] = @powergrade if @powergrade
  h["clips"] = @clips
  h["transitions"] = @transitions unless @transitions.empty?
  h["title_card"] = @title_card if @title_card
  h["broll"] = @broll if @broll && !@broll.empty?
  h
end
```

5. Add `validate_broll!` and call it from `validate!`:

```ruby
def validate!
  validate_version!
  validate_string!(@library, "library")
  validate_string!(@timeline, "timeline")
  validate_clips!
  validate_render_preset! if @render_preset
  validate_powergrade! if @powergrade
  validate_transitions!
  validate_title_card! if @title_card
  validate_broll! unless @broll.nil?
end

def validate_broll!
  raise ArgumentError, "broll must be an array" unless @broll.is_a?(Array)
  @broll.each_with_index do |entry, i|
    raise ArgumentError, "broll[#{i}] must be a hash" unless entry.is_a?(Hash)
    %w[id start end placement source source_video].each do |field|
      unless entry.key?(field) && !entry[field].nil?
        raise ArgumentError, "broll[#{i}] missing required field #{field.inspect}"
      end
    end
    validate_string!(entry["id"], "broll[#{i}] id")
    validate_string!(entry["source"], "broll[#{i}] source")
    validate_string!(entry["source_video"], "broll[#{i}] source_video")
    validate_non_negative_number!(entry["start"], "broll[#{i}] start")
    validate_non_negative_number!(entry["end"], "broll[#{i}] end")
    unless entry["end"] > entry["start"]
      raise ArgumentError, "broll[#{i}] end must be greater than start"
    end
    unless BROLL_PLACEMENTS.include?(entry["placement"])
      raise ArgumentError, "broll[#{i}] placement #{entry["placement"].inspect} not in #{BROLL_PLACEMENTS.inspect}"
    end
  end
end
```

- [ ] **Step 4: Run tests — expect green**

```bash
bundle exec rspec spec/recipe_spec.rb
```

Expected: all green (v1 + v2 still accepted because `SUPPORTED_VERSIONS` includes them; new v3 cases pass).

- [ ] **Step 5: Commit**

```bash
git add lib/buttercut/recipe.rb spec/recipe_spec.rb
git commit -m "feat: Recipe schema v3 with optional broll array (#33)"
```

---

## Task 3: `ButterCut::Overlay` value class

**Files:**
- Create: `lib/buttercut/overlay.rb`
- Create: `spec/buttercut/overlay_spec.rb`

- [ ] **Step 1: Write the failing test**

Create `spec/buttercut/overlay_spec.rb`:

```ruby
require 'spec_helper'
require 'buttercut/overlay'

RSpec.describe ButterCut::Overlay do
  let(:base) do
    {
      source: "/abs/broll/br-0001.mp4",
      source_id: "br-0001",
      start: 10.0,
      duration: 5.0,
      placement: "overlay"
    }
  end

  describe ".from_hash" do
    it "parses a minimal overlay" do
      o = described_class.from_hash(base)
      expect(o.source).to eq("/abs/broll/br-0001.mp4")
      expect(o.source_id).to eq("br-0001")
      expect(o.start).to eq(10.0)
      expect(o.duration).to eq(5.0)
      expect(o.placement).to eq("overlay")
      expect(o.pip?).to be(false)
    end

    it "parses pip with corner + scale" do
      o = described_class.from_hash(base.merge(placement: "pip", pip_corner: "top_right", pip_scale: 0.4))
      expect(o.pip?).to be(true)
      expect(o.pip_corner).to eq("top_right")
      expect(o.pip_scale).to eq(0.4)
    end

    it "defaults pip_corner=top_right and pip_scale=0.33 when placement is pip and fields missing" do
      o = described_class.from_hash(base.merge(placement: "pip"))
      expect(o.pip_corner).to eq("top_right")
      expect(o.pip_scale).to eq(0.33)
    end

    it "rejects placement outside the enum" do
      expect { described_class.from_hash(base.merge(placement: "weird")) }.to raise_error(ArgumentError, /placement/)
    end

    it "rejects non-positive duration" do
      expect { described_class.from_hash(base.merge(duration: 0)) }.to raise_error(ArgumentError, /duration/)
    end

    it "rejects pip fields on non-pip placement" do
      expect {
        described_class.from_hash(base.merge(pip_corner: "top_right"))
      }.to raise_error(ArgumentError, /pip_corner.*only valid.*pip/)
    end

    it "raises when source path is not absolute" do
      expect {
        described_class.from_hash(base.merge(source: "relative/path.mp4"))
      }.to raise_error(ArgumentError, /absolute/)
    end
  end

  describe "#pip_transform" do
    let(:pip) { described_class.from_hash(base.merge(placement: "pip", pip_corner: "top_right", pip_scale: 0.25)) }

    it "returns nil for non-pip overlays" do
      expect(described_class.from_hash(base).pip_transform).to be_nil
    end

    it "returns scale and a position fraction for pip" do
      t = pip.pip_transform
      expect(t[:scale]).to eq(0.25)
      # top_right with 0.25 scale: x positive, y negative (upward) in FCPXML's centered coord system.
      expect(t[:x]).to be > 0
      expect(t[:y]).to be > 0
      expect(t[:corner]).to eq("top_right")
    end

    it "computes opposite-sign x and y for opposite corners" do
      a = described_class.from_hash(base.merge(placement: "pip", pip_corner: "top_right", pip_scale: 0.25)).pip_transform
      b = described_class.from_hash(base.merge(placement: "pip", pip_corner: "bottom_left", pip_scale: 0.25)).pip_transform
      expect(a[:x]).to eq(-b[:x])
      expect(a[:y]).to eq(-b[:y])
    end
  end
end
```

- [ ] **Step 2: Run — expect LoadError / NameError**

```bash
bundle exec rspec spec/buttercut/overlay_spec.rb
```

Expected: fails because `lib/buttercut/overlay.rb` doesn't exist yet.

- [ ] **Step 3: Implement `lib/buttercut/overlay.rb`**

```ruby
require 'pathname'

class ButterCut
  # One b-roll placement on top of the V1 spine. Built by callers (typically
  # export_to_fcpxml.rb) from a BrollManifest entry; consumed by FCPX/FCP7.
  #
  # All overlays mute their own audio — the V1 audio bed continues underneath.
  class Overlay
    PLACEMENTS = %w[overlay cutaway pip].freeze
    PIP_CORNERS = %w[top_right top_left bottom_right bottom_left].freeze
    DEFAULT_PIP_CORNER = "top_right"
    DEFAULT_PIP_SCALE = 0.33

    # Margin from frame edge as fraction of half-frame, applied after scaling.
    # 0.05 = inset 5% of half-frame from the edge after scale.
    PIP_EDGE_MARGIN = 0.05

    attr_reader :source, :source_id, :start, :duration, :placement,
                :pip_corner, :pip_scale

    def self.from_hash(hash)
      raise ArgumentError, "overlay hash required" unless hash.is_a?(Hash)

      new(
        source: hash[:source] || hash["source"],
        source_id: hash[:source_id] || hash["source_id"],
        start: hash[:start] || hash["start"],
        duration: hash[:duration] || hash["duration"],
        placement: hash[:placement] || hash["placement"],
        pip_corner: hash[:pip_corner] || hash["pip_corner"],
        pip_scale: hash[:pip_scale] || hash["pip_scale"]
      )
    end

    def initialize(source:, source_id:, start:, duration:, placement:, pip_corner: nil, pip_scale: nil)
      raise ArgumentError, "source required" if source.nil? || source.empty?
      raise ArgumentError, "source must be an absolute path: #{source}" unless Pathname.new(source).absolute?
      raise ArgumentError, "source_id required" if source_id.nil? || source_id.empty?
      raise ArgumentError, "start must be a non-negative number" unless start.is_a?(Numeric) && start >= 0
      raise ArgumentError, "duration must be > 0" unless duration.is_a?(Numeric) && duration > 0
      raise ArgumentError, "placement #{placement.inspect} not in #{PLACEMENTS.inspect}" unless PLACEMENTS.include?(placement)

      if placement == "pip"
        @pip_corner = pip_corner || DEFAULT_PIP_CORNER
        @pip_scale = pip_scale.nil? ? DEFAULT_PIP_SCALE : pip_scale
        unless PIP_CORNERS.include?(@pip_corner)
          raise ArgumentError, "pip_corner #{@pip_corner.inspect} not in #{PIP_CORNERS.inspect}"
        end
        unless @pip_scale.is_a?(Numeric) && @pip_scale > 0 && @pip_scale < 1
          raise ArgumentError, "pip_scale must be in (0, 1), got #{@pip_scale.inspect}"
        end
      else
        if pip_corner
          raise ArgumentError, "pip_corner only valid when placement is pip"
        end
        if pip_scale
          raise ArgumentError, "pip_scale only valid when placement is pip"
        end
        @pip_corner = nil
        @pip_scale = nil
      end

      @source = source
      @source_id = source_id
      @start = start
      @duration = duration
      @placement = placement
    end

    def end_time
      @start + @duration
    end

    def pip?
      @placement == "pip"
    end

    # Returns { scale:, x:, y:, corner: } in FCPXML centered-fraction units, or
    # nil for non-pip overlays.
    #
    # Coordinate convention: 0,0 is frame center. Positive x = right, positive y
    # = up (FCPXML convention). Values are fractions of the frame: x=0.5 means
    # right edge, y=0.5 means top edge. We compute the corner offset so the
    # scaled clip's edge sits PIP_EDGE_MARGIN inside the frame edge.
    def pip_transform
      return nil unless pip?

      offset = (1.0 - @pip_scale) / 2.0 - PIP_EDGE_MARGIN
      sign_x = @pip_corner.end_with?("right") ? 1 : -1
      sign_y = @pip_corner.start_with?("top")  ? 1 : -1

      {
        scale: @pip_scale,
        x: sign_x * offset,
        y: sign_y * offset,
        corner: @pip_corner
      }
    end
  end
end
```

- [ ] **Step 4: Run — expect green**

```bash
bundle exec rspec spec/buttercut/overlay_spec.rb
```

Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add lib/buttercut/overlay.rb spec/buttercut/overlay_spec.rb
git commit -m "feat: ButterCut::Overlay value class for b-roll placement (#33)"
```

---

## Task 4: Plumb `overlays:` keyword through the factory and `EditorBase`

**Files:**
- Modify: `lib/buttercut.rb`
- Modify: `lib/buttercut/editor_base.rb`
- Modify: `spec/buttercut_spec.rb`

- [ ] **Step 1: Add failing test for the factory accepting `overlays:`**

Append inside the `describe '.new factory method'` block in `spec/buttercut_spec.rb`:

```ruby
    it 'accepts an optional overlays: keyword and exposes it via the editor' do
      overlay = {
        source: video_file_path,
        source_id: 'br-0001',
        start: 0.0,
        duration: 1.0,
        placement: 'overlay'
      }
      generator = ButterCut.new(clips, editor: :fcpx, overlays: [overlay])
      expect(generator.overlays.length).to eq(1)
      expect(generator.overlays.first).to be_a(ButterCut::Overlay)
      expect(generator.overlays.first.source_id).to eq('br-0001')
    end

    it 'defaults overlays to [] when omitted' do
      generator = ButterCut.new(clips, editor: :fcpx)
      expect(generator.overlays).to eq([])
    end
```

- [ ] **Step 2: Run — expect failure**

```bash
bundle exec rspec spec/buttercut_spec.rb
```

Expected: failure on the new examples (no `overlays:` parameter, no `#overlays` reader).

- [ ] **Step 3: Update `lib/buttercut.rb`**

Replace the factory method:

```ruby
require_relative 'buttercut/fcpx'
require_relative 'buttercut/fcp7'
require_relative 'buttercut/recipe'
require_relative 'buttercut/broll_manifest'
require_relative 'buttercut/broll_renderer'
require_relative 'buttercut/overlay'
require_relative 'buttercut/theme'

class ButterCut
  SUPPORTED_EDITORS = [:fcpx, :fcp7].freeze

  def self.new(clips, editor:, overlays: nil)
    raise ArgumentError, "editor: parameter is required" if editor.nil?

    unless SUPPORTED_EDITORS.include?(editor)
      raise ArgumentError, "Unsupported editor: #{editor.inspect}. Supported editors: #{SUPPORTED_EDITORS.map(&:inspect).join(', ')}"
    end

    case editor
    when :fcpx
      ButterCut::FCPX.new(clips, overlays: overlays)
    when :fcp7
      ButterCut::FCP7.new(clips, overlays: overlays)
    end
  end
end
```

- [ ] **Step 4: Update `EditorBase#initialize` to accept and normalize overlays**

In `lib/buttercut/editor_base.rb`, change `initialize` and add the reader:

```ruby
attr_reader :clips, :overlays, :initial_offset, :volume_adjustment

def initialize(clips, overlays: nil)
  raise ArgumentError, "No clips provided" if clips.nil? || clips.empty?

  clips.each_with_index do |clip, index|
    unless clip.is_a?(Hash)
      raise ArgumentError, "Clip at index #{index} must be a hash, got #{clip.class}"
    end
    unless clip.key?(:path)
      raise ArgumentError, "Clip at index #{index} must have a 'path' key"
    end
  end

  relative_paths = clips.select { |clip| !Pathname.new(clip[:path]).absolute? }
  unless relative_paths.empty?
    paths = relative_paths.map { |clip| clip[:path] }.join(', ')
    raise ArgumentError, "All video file paths must be absolute paths. Relative paths found: #{paths}"
  end

  @clips = clips
  @overlays = normalize_overlays(overlays)
  @initial_offset = DEFAULT_INITIAL_OFFSET
  @volume_adjustment = DEFAULT_VOLUME_ADJUSTMENT

  @metadata_cache = {}
  metadata_paths = @clips.map { |c| c[:path] } + @overlays.map(&:source)
  metadata_paths.uniq.each do |path|
    @metadata_cache[path] = extract_metadata_from_ffprobe(path)
  end
end

private

def normalize_overlays(raw)
  return [] if raw.nil? || raw.empty?
  raw.map do |o|
    o.is_a?(ButterCut::Overlay) ? o : ButterCut::Overlay.from_hash(o)
  end
end
```

(The `private` keyword is already present in the file; place `normalize_overlays` with the existing private methods.)

- [ ] **Step 5: Run tests — expect green**

```bash
bundle exec rspec spec/buttercut_spec.rb
```

Expected: green.

- [ ] **Step 6: Run the full suite to catch regressions in FCPX/FCP7 specs**

```bash
bundle exec rspec
```

Expected: green. If anything breaks, the only realistic cause is `FCPX.new(clips)` / `FCP7.new(clips)` callers that now hit the new keyword. Both subclasses inherit `EditorBase#initialize` so the `overlays:` kwarg flows through unchanged.

- [ ] **Step 7: Commit**

```bash
git add lib/buttercut.rb lib/buttercut/editor_base.rb spec/buttercut_spec.rb
git commit -m "feat: ButterCut.new(overlays:) keyword plumbed through EditorBase (#33)"
```

---

## Task 5: FCPX overlay emission

**Files:**
- Modify: `lib/buttercut/fcpx.rb`
- Create: `spec/buttercut/fcpx_overlay_spec.rb`

- [ ] **Step 1: Write the failing test**

Create `spec/buttercut/fcpx_overlay_spec.rb`:

```ruby
require 'spec_helper'
require 'nokogiri'
require 'buttercut'

RSpec.describe ButterCut::FCPX, "overlay emission" do
  let(:video_file_path) { File.expand_path('../fixtures/media/MVI_0323_720p.mov', __dir__) }
  let(:clips) { [{ path: video_file_path }] }
  let(:overlay) do
    {
      source: video_file_path,        # reuse media fixture as a stand-in MP4
      source_id: 'br-0001',
      start: 0.5,
      duration: 1.0,
      placement: 'overlay'
    }
  end

  def doc(overlays)
    xml = ButterCut.new(clips, editor: :fcpx, overlays: overlays).to_xml
    Nokogiri::XML(xml).remove_namespaces!
  end

  context "no overlays" do
    it "produces XML byte-identical to a generator without overlays" do
      a = ButterCut.new(clips, editor: :fcpx).to_xml
      b = ButterCut.new(clips, editor: :fcpx, overlays: []).to_xml
      # SecureRandom UUIDs differ; strip them.
      strip_uuids = ->(s) { s.gsub(/uid="[^"]+"/, 'uid="X"') }
      expect(strip_uuids.call(a)).to eq(strip_uuids.call(b))
    end
  end

  context "one overlay placement" do
    it "emits an asset for the overlay source" do
      d = doc([overlay])
      assets = d.xpath('//resources/asset')
      sources = assets.map { |a| a['src'] }
      expect(sources.any? { |s| s&.include?('MVI_0323_720p.mov') }).to be(true)
    end

    it "emits the overlay clip on lane=1, attached to the spine asset-clip" do
      d = doc([overlay])
      lane_clips = d.xpath('//spine//asset-clip[@lane="1"]')
      expect(lane_clips.length).to eq(1)
      expect(lane_clips.first['name']).to include('br-0001')
    end

    it "mutes the overlay audio with -96dB" do
      d = doc([overlay])
      lane_clip = d.xpath('//spine//asset-clip[@lane="1"]').first
      vol = lane_clip.xpath('./adjust-volume').first
      expect(vol['amount']).to eq('-96dB')
    end

    it "does not emit adjust-transform for non-pip overlays" do
      d = doc([overlay])
      lane_clip = d.xpath('//spine//asset-clip[@lane="1"]').first
      expect(lane_clip.xpath('./adjust-transform')).to be_empty
    end
  end

  context "pip placement" do
    let(:pip_overlay) { overlay.merge(placement: 'pip', pip_corner: 'top_right', pip_scale: 0.25) }

    it "emits adjust-transform with scale and position" do
      d = doc([pip_overlay])
      lane_clip = d.xpath('//spine//asset-clip[@lane="1"]').first
      tr = lane_clip.xpath('./adjust-transform').first
      expect(tr).not_to be_nil
      expect(tr['scale']).to match(/\A0\.25 0\.25\z/)
      # position is "x y"; both should be non-zero, x positive (right), y positive (top)
      x, y = tr['position'].split(' ').map(&:to_f)
      expect(x).to be > 0
      expect(y).to be > 0
    end
  end

  context "cutaway placement" do
    let(:cutaway) { overlay.merge(placement: 'cutaway') }

    it "emits the same lane=1 attachment as overlay (per design)" do
      d = doc([cutaway])
      lane_clips = d.xpath('//spine//asset-clip[@lane="1"]')
      expect(lane_clips.length).to eq(1)
    end
  end
end
```

- [ ] **Step 2: Run — expect failures**

```bash
bundle exec rspec spec/buttercut/fcpx_overlay_spec.rb
```

Expected: every example fails (no overlay emission yet).

- [ ] **Step 3: Implement overlay emission in `lib/buttercut/fcpx.rb`**

Update `to_xml`. The asset map must include overlay sources, and each spine clip must check whether overlays land within its time range — overlays attach as lane-1 connected clips inside their parent spine clip (FCPXML allows lane clips to extend beyond their parent).

Replace `to_xml`:

```ruby
def to_xml
  raise ArgumentError, "No clips provided" if clips.empty?

  asset_map = build_asset_map
  overlay_asset_map = build_overlay_asset_map(asset_map)
  timeline_frame_duration = format_frame_duration
  timeline_clips, sequence_duration = build_timeline_clips(asset_map, timeline_frame_duration)

  event_uid = generate_uuid
  project_uid = generate_uuid

  first_path = clips.first[:path]
  first_filename = get_filename(first_path)
  project_basename = get_basename(first_filename)
  event_name = project_basename
  timestamped_project_name = "#{project_basename} #{timestamp_suffix}"

  builder = Nokogiri::XML::Builder.new(encoding: 'utf-8') do |xml|
    xml.fcpxml(version: FCPXML_VERSION) do
      xml.resources do
        xml.format(
          id: FORMAT_ID,
          height: format_height,
          width: format_width,
          frameDuration: format_frame_duration,
          colorSpace: format_color_space
        )

        (asset_map.values + overlay_asset_map.values).each do |asset|
          xml.asset(
            id: asset[:asset_id],
            name: asset[:filename],
            uid: asset[:asset_uid],
            src: asset[:file_url],
            start: asset[:timecode],
            audioRate: asset[:audio_rate],
            hasAudio: '1',
            hasVideo: '1',
            format: FORMAT_ID,
            duration: asset[:asset_duration]
          )
        end
      end

      xml.library(location: './') do
        xml.event(name: event_name, uid: event_uid) do
          xml.project(name: timestamped_project_name, uid: project_uid, modDate: '2025-10-31 17:25:16 GMT-7') do
            xml.sequence(duration: sequence_duration, format: FORMAT_ID, tcStart: '0s', audioRate: '48k') do
              xml.spine do
                timeline_clips.each do |clip|
                  xml.send('asset-clip',
                    name: clip[:filename],
                    ref: clip[:asset_id],
                    start: clip[:start],
                    offset: clip[:timeline_offset],
                    duration: clip[:duration],
                    audioRole: 'dialogue'
                  ) do
                    emit_time_map(xml, clip)
                    xml.send('adjust-volume', amount: volume_adjustment)
                    emit_overlays_for_clip(xml, clip, overlay_asset_map)
                  end
                end
              end
            end
          end
        end
      end
    end
  end

  builder.to_xml
end
```

Add the new private helpers (place them with the other private methods):

```ruby
def build_overlay_asset_map(existing_asset_map)
  map = {}
  return map if overlays.empty?

  base_index = existing_asset_map.size
  overlays.each_with_index do |o, i|
    next if map.key?(o.source)
    asset_id = "r#{base_index + i + 2}" # r1 = format; clip assets are r2..; overlays follow
    metadata = extract_metadata(o.source)
    audio_stream = metadata['streams'].find { |s| s['codec_type'] == 'audio' }
    video_stream = metadata['streams'].find { |s| s['codec_type'] == 'video' }
    asset_duration_seconds = metadata['format']['duration'].to_f

    map[o.source] = {
      asset_id: asset_id,
      asset_uid: file_md5_uid(o.source),
      filename: get_filename(o.source),
      file_url: file_url_for(o.source),
      timecode: DEFAULT_START_TIME,
      audio_rate: audio_stream ? audio_stream['sample_rate'] : '48000',
      asset_duration: seconds_to_fraction(asset_duration_seconds, format_frame_duration),
      width: video_stream ? video_stream['width'] : nil,
      height: video_stream ? video_stream['height'] : nil
    }
  end
  map
end

def emit_overlays_for_clip(xml, clip, overlay_asset_map)
  return if overlays.empty?

  clip_start_seconds = fraction_to_seconds(clip[:timeline_offset])
  clip_end_seconds = clip_start_seconds + fraction_to_seconds(clip[:duration])

  overlays.each do |o|
    next unless overlay_overlaps?(o, clip_start_seconds, clip_end_seconds)
    asset = overlay_asset_map[o.source]
    next if asset.nil?

    relative_offset_seconds = o.start - clip_start_seconds
    offset_fraction = seconds_to_fraction(relative_offset_seconds + fraction_to_seconds(clip[:start]), format_frame_duration)
    duration_fraction = seconds_to_fraction(o.duration, format_frame_duration)

    xml.send('asset-clip',
      name: "#{o.source_id} (#{asset[:filename]})",
      ref: asset[:asset_id],
      lane: '1',
      offset: offset_fraction,
      start: '0s',
      duration: duration_fraction
    ) do
      xml.send('adjust-volume', amount: '-96dB')
      if (transform = o.pip_transform)
        xml.send('adjust-transform',
          scale: format('%g %g', transform[:scale], transform[:scale]),
          position: format('%g %g', transform[:x] * 100, transform[:y] * 100)
        )
      end
    end
  end
end

def overlay_overlaps?(overlay, clip_start_seconds, clip_end_seconds)
  overlay.start < clip_end_seconds && overlay.end_time > clip_start_seconds
end
```

- [ ] **Step 4: Verify the helpers exist on `EditorBase` (or add them)**

The helpers `seconds_to_fraction`, `fraction_to_seconds`, `file_md5_uid`, `file_url_for`, and `get_filename` should already exist on `EditorBase` (they're used in `build_asset_map` and `build_timeline_clips`). Open `lib/buttercut/editor_base.rb` and grep:

```bash
grep -nE 'def (seconds_to_fraction|fraction_to_seconds|file_md5_uid|file_url_for|get_filename)' lib/buttercut/editor_base.rb
```

If any helper is missing under that exact name (the codebase may use slightly different names — e.g. the FCPX file has `fraction_to_rational` and `rational_to_fraction`), adapt the calls in `emit_overlays_for_clip` to use the existing equivalents. Do NOT create duplicate helpers; reuse what's there. The two operations needed are:

1. seconds → FCPXML fraction string (e.g. `0.5` → `"1/2s"` aligned to the frame duration)
2. FCPXML fraction string → seconds (Float)

If only one direction exists, add the other in `editor_base.rb` next to its sibling.

- [ ] **Step 5: Run tests — expect green**

```bash
bundle exec rspec spec/buttercut/fcpx_overlay_spec.rb
```

Expected: all green. If the byte-identical test fails because adding overlay-asset code paths perturbs IDs/UUIDs even when overlays is empty, ensure `build_overlay_asset_map` returns an empty map when `overlays.empty?` (it does — line 1) and that `emit_overlays_for_clip` early-returns. The two should be no-ops on the empty path.

- [ ] **Step 6: Run the full suite**

```bash
bundle exec rspec
```

Expected: all green. Existing FCPX golden tests still pass.

- [ ] **Step 7: Commit**

```bash
git add lib/buttercut/fcpx.rb spec/buttercut/fcpx_overlay_spec.rb lib/buttercut/editor_base.rb
git commit -m "feat: FCPX emits b-roll overlays on lane=1 (#33)"
```

---

## Task 6: FCP7 / Resolve overlay emission

**Files:**
- Modify: `lib/buttercut/fcp7.rb`
- Create: `spec/buttercut/fcp7_overlay_spec.rb`

- [ ] **Step 1: Write the failing test**

Create `spec/buttercut/fcp7_overlay_spec.rb`:

```ruby
require 'spec_helper'
require 'nokogiri'
require 'buttercut'

RSpec.describe ButterCut::FCP7, "overlay emission" do
  let(:video_file_path) { File.expand_path('../fixtures/media/MVI_0323_720p.mov', __dir__) }
  let(:clips) { [{ path: video_file_path }] }
  let(:overlay) do
    {
      source: video_file_path,
      source_id: 'br-0001',
      start: 0.5,
      duration: 1.0,
      placement: 'overlay'
    }
  end

  def doc(overlays)
    xml = ButterCut.new(clips, editor: :fcp7, overlays: overlays).to_xml
    Nokogiri::XML(xml).remove_namespaces!
  end

  context "no overlays" do
    it "still emits exactly one video <track> and one audio <track>" do
      d = doc([])
      expect(d.xpath('//media/video/track').length).to eq(1)
      expect(d.xpath('//media/audio/track').length).to eq(1)
    end
  end

  context "one overlay" do
    it "emits a second video track containing the overlay clipitem" do
      d = doc([overlay])
      tracks = d.xpath('//media/video/track')
      expect(tracks.length).to eq(2)
      v2 = tracks[1]
      items = v2.xpath('./clipitem')
      expect(items.length).to eq(1)
      expect(items.first.xpath('./name').text).to include('br-0001')
    end

    it "places the clipitem at frame-aligned start and end on V2" do
      d = doc([overlay])
      v2 = d.xpath('//media/video/track')[1]
      item = v2.xpath('./clipitem').first
      start_frame = item.xpath('./start').text.to_i
      end_frame   = item.xpath('./end').text.to_i
      expect(end_frame).to be > start_frame
      expect(start_frame).to be >= 0
    end
  end

  context "pip overlay" do
    let(:pip_overlay) { overlay.merge(placement: 'pip', pip_corner: 'top_right', pip_scale: 0.25) }

    it "emits a Motion Basic Motion filter with Scale parameter" do
      d = doc([pip_overlay])
      v2 = d.xpath('//media/video/track')[1]
      item = v2.xpath('./clipitem').first
      filter_names = item.xpath('./filter/effect/name').map(&:text)
      expect(filter_names).to include('Basic Motion')
      scale_param = item.xpath('./filter/effect/parameter[name="Scale"]/value').first
      expect(scale_param).not_to be_nil
      expect(scale_param.text.to_f).to be_within(0.01).of(25.0) # FCP7 Scale is 0..100
    end
  end
end
```

- [ ] **Step 2: Run — expect failures**

```bash
bundle exec rspec spec/buttercut/fcp7_overlay_spec.rb
```

- [ ] **Step 3: Implement V2 track emission in `lib/buttercut/fcp7.rb`**

Inside `to_xml`, after the existing `xml.track do … end` block for video, add a conditional second track when `overlays.any?`:

Find this block:

```ruby
xml.video do
  xml.format do
    # …
  end
  xml.track do
    clip_payloads.each do |payload|
      build_video_clipitem(xml, payload)
    end
  end
end
```

Change to:

```ruby
xml.video do
  xml.format do
    # …existing format block kept verbatim
  end
  xml.track do
    clip_payloads.each do |payload|
      build_video_clipitem(xml, payload)
    end
  end
  build_overlay_video_track(xml, timeline_frame_duration) if overlays.any?
end
```

Then add the two private helpers below the existing private methods:

```ruby
def build_overlay_video_track(xml, timeline_frame_duration)
  xml.track do
    overlays.each_with_index do |overlay, i|
      build_overlay_clipitem(xml, overlay, i, timeline_frame_duration)
    end
  end
end

def build_overlay_clipitem(xml, overlay, index, timeline_frame_duration)
  metadata = extract_metadata(overlay.source)
  video_stream = metadata['streams'].find { |s| s['codec_type'] == 'video' }
  asset_duration_seconds = metadata['format']['duration'].to_f

  asset_rate_num, asset_rate_denom = (video_stream['r_frame_rate'] || '30/1').split('/').map(&:to_i)
  asset_timebase = (asset_rate_num.to_f / asset_rate_denom).round
  asset_ntsc = ntsc_flag_for(asset_rate_denom)

  start_frame = frames_for_seconds(overlay.start, timeline_frame_duration)
  duration_frame = frames_for_seconds(overlay.duration, timeline_frame_duration)
  end_frame = start_frame + duration_frame

  filename = File.basename(overlay.source)
  file_id = "file-overlay-#{overlay.source_id}"
  clip_id = "clipitem-overlay-#{overlay.source_id}"

  xml.clipitem(id: clip_id) do
    xml.name "#{overlay.source_id} (#{filename})"
    xml.enabled 'TRUE'
    xml.duration duration_frame
    xml.start start_frame
    xml.end_ end_frame
    xml.in_ 0
    xml.out duration_frame
    xml.file(id: file_id) do
      xml.name filename
      xml.pathurl file_url_for(overlay.source)
      xml.rate do
        xml.timebase asset_timebase
        xml.ntsc asset_ntsc
      end
      xml.duration frames_for_seconds(asset_duration_seconds, timeline_frame_duration)
      xml.media do
        xml.video do
          xml.samplecharacteristics do
            xml.rate do
              xml.timebase asset_timebase
              xml.ntsc asset_ntsc
            end
            xml.width video_stream['width']
            xml.height video_stream['height']
          end
        end
      end
    end
    if overlay.pip?
      build_basic_motion_filter(xml, overlay)
    end
  end
end

def build_basic_motion_filter(xml, overlay)
  transform = overlay.pip_transform
  return if transform.nil?

  xml.filter do
    xml.enabled 'TRUE'
    xml.start 0
    xml.end_ -1
    xml.effect do
      xml.name 'Basic Motion'
      xml.effectid 'basic'
      xml.effectcategory 'motion'
      xml.effecttype 'motion'
      xml.mediatype 'video'
      xml.parameter do
        xml.name 'Scale'
        xml.parameterid 'scale'
        xml.value (transform[:scale] * 100.0).round(2)
        xml.valuemin 0
        xml.valuemax 1000
      end
      xml.parameter do
        xml.name 'Center'
        xml.parameterid 'center'
        xml.value do
          xml.horiz transform[:x].round(4)
          xml.vert  (-transform[:y]).round(4) # FCP7 inverts y vs. FCPXML
        end
      end
    end
  end
end

def frames_for_seconds(seconds, timeline_frame_duration)
  num, denom = timeline_frame_duration.sub(/s\z/, '').split('/').map(&:to_i)
  fps = denom.to_f / num
  (seconds * fps).round
end
```

- [ ] **Step 4: Run tests — expect green**

```bash
bundle exec rspec spec/buttercut/fcp7_overlay_spec.rb
```

Expected: green. If `frames_for_fraction` already exists in `EditorBase` and converts a Rational/seconds value to frames, replace `frames_for_seconds` with the existing helper (use `Rational(seconds)` or whatever shape the existing helper accepts) — do NOT keep two helpers.

- [ ] **Step 5: Run full suite**

```bash
bundle exec rspec
```

Expected: green. Existing FCP7 golden tests should still pass because the new track is only emitted when `overlays.any?`.

- [ ] **Step 6: Commit**

```bash
git add lib/buttercut/fcp7.rb spec/buttercut/fcp7_overlay_spec.rb
git commit -m "feat: FCP7/Resolve emit V2 track for b-roll overlays (#33)"
```

---

## Task 7: Discover sibling broll.yaml in `export_to_fcpxml.rb`

**Files:**
- Modify: `.claude/skills/roughcut/export_to_fcpxml.rb`
- Create: `spec/buttercut/export_to_fcpxml_broll_spec.rb`
- Create: `spec/fixtures/broll_integration/sample_roughcut.yaml`
- Create: `spec/fixtures/broll_integration/sample_roughcut.broll.yaml`

The skill script currently runs as `__FILE__ == $PROGRAM_NAME`. We need to refactor its core logic into a class so we can unit-test it.

- [ ] **Step 1: Write the failing test**

Create `spec/fixtures/broll_integration/sample_roughcut.yaml` (use one of the existing media fixtures so ffprobe succeeds):

```yaml
description: "fixture rough cut for b-roll integration"
clips:
  - source_file: "MVI_0323_720p.mov"
    in_point: "00:00:00.00"
    out_point: "00:00:05.00"
    dialogue: ""
    visual_description: ""
metadata:
  created_date: ""
  total_duration: ""
```

Create `spec/fixtures/broll_integration/sample_roughcut.broll.yaml` — the `rendered:` value is filled in at runtime by the test (since the test resolves the absolute path to a fixture media file). Use a placeholder string:

```yaml
version: 2
library: fixture-library
roughcut: sample_roughcut
entries:
  - id: br-0001
    source_video: MVI_0323_720p.mov
    start: 1.0
    end: 2.0
    template: code-callout
    placement: overlay
    content:
      command: "git status"
    rendered: __FIXTURE_ABS_PATH__
```

Create `spec/buttercut/export_to_fcpxml_broll_spec.rb`:

```ruby
require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'yaml'
require 'nokogiri'

EXPORT_SCRIPT = File.expand_path('../../.claude/skills/roughcut/export_to_fcpxml.rb', __dir__)
require EXPORT_SCRIPT

RSpec.describe RoughcutExporter do
  let(:fixture_dir) { File.expand_path('../fixtures/broll_integration', __dir__) }
  let(:media_path) { File.expand_path('../fixtures/media/MVI_0323_720p.mov', __dir__) }
  let(:roughcut_yaml_src) { File.join(fixture_dir, 'sample_roughcut.yaml') }
  let(:broll_yaml_src) { File.join(fixture_dir, 'sample_roughcut.broll.yaml') }

  def with_library
    Dir.mktmpdir do |root|
      lib_dir = File.join(root, 'libraries', 'fixture-library')
      roughcut_dir = File.join(lib_dir, 'roughcuts')
      FileUtils.mkdir_p(roughcut_dir)

      FileUtils.cp(roughcut_yaml_src, File.join(roughcut_dir, 'sample_roughcut.yaml'))

      broll = YAML.load_file(broll_yaml_src)
      broll['entries'].first['rendered'] = media_path
      File.write(File.join(roughcut_dir, 'sample_roughcut.broll.yaml'), broll.to_yaml)

      File.write(File.join(lib_dir, 'library.yaml'), {
        'videos' => [{ 'path' => media_path }]
      }.to_yaml)

      yield root, File.join(roughcut_dir, 'sample_roughcut.yaml'), File.join(roughcut_dir, 'sample_roughcut.xml')
    end
  end

  it "discovers a sibling broll.yaml and emits an overlay clip in the XML" do
    with_library do |_root, roughcut, xml_out|
      RoughcutExporter.export(roughcut_path: roughcut, output_path: xml_out, editor: 'fcpx')
      doc = Nokogiri::XML(File.read(xml_out)).remove_namespaces!
      expect(doc.xpath('//spine//asset-clip[@lane="1"]').length).to eq(1)
    end
  end

  it "produces XML with no lane=1 clips when no broll.yaml is present" do
    with_library do |_root, roughcut, xml_out|
      File.delete(File.join(File.dirname(roughcut), 'sample_roughcut.broll.yaml'))
      RoughcutExporter.export(roughcut_path: roughcut, output_path: xml_out, editor: 'fcpx')
      doc = Nokogiri::XML(File.read(xml_out)).remove_namespaces!
      expect(doc.xpath('//spine//asset-clip[@lane="1"]')).to be_empty
    end
  end

  it "includes a broll array in the recipe.json" do
    with_library do |_root, roughcut, xml_out|
      RoughcutExporter.export(roughcut_path: roughcut, output_path: xml_out, editor: 'fcpx')
      recipe_path = xml_out.sub(/\.xml\z/, '.recipe.json')
      recipe = JSON.parse(File.read(recipe_path))
      expect(recipe['broll']).to be_an(Array)
      expect(recipe['broll'].first['id']).to eq('br-0001')
    end
  end

  it "skips entries with rendered: null and warns" do
    with_library do |_root, roughcut, xml_out|
      broll_path = File.join(File.dirname(roughcut), 'sample_roughcut.broll.yaml')
      broll = YAML.load_file(broll_path)
      broll['entries'].first['rendered'] = nil
      File.write(broll_path, broll.to_yaml)

      expect {
        RoughcutExporter.export(roughcut_path: roughcut, output_path: xml_out, editor: 'fcpx')
      }.to output(/skipping br-0001.*rendered/i).to_stderr

      doc = Nokogiri::XML(File.read(xml_out)).remove_namespaces!
      expect(doc.xpath('//spine//asset-clip[@lane="1"]')).to be_empty
    end
  end
end
```

- [ ] **Step 2: Run — expect failures**

```bash
bundle exec rspec spec/buttercut/export_to_fcpxml_broll_spec.rb
```

Expected: load error / NameError on `RoughcutExporter` (the script currently has no class).

- [ ] **Step 3: Refactor `.claude/skills/roughcut/export_to_fcpxml.rb` into a `RoughcutExporter` class**

Replace the file with:

```ruby
#!/usr/bin/env ruby
# Export rough cut YAML to editor XML using ButterCut.

require 'date'
require 'yaml'
require 'buttercut'
require_relative 'recipe_from_roughcut'
require_relative 'generate_apply_script'

class RoughcutExporter
  def self.export(roughcut_path:, output_path:, editor: 'fcpx')
    new(roughcut_path: roughcut_path, output_path: output_path, editor: editor).export
  end

  def initialize(roughcut_path:, output_path:, editor: 'fcpx')
    raise ArgumentError, "roughcut_path required" if roughcut_path.nil? || roughcut_path.empty?
    raise ArgumentError, "output_path required" if output_path.nil? || output_path.empty?
    @roughcut_path = roughcut_path
    @output_path = output_path
    @editor_choice = editor
  end

  def export
    raise "Rough cut file not found: #{@roughcut_path}" unless File.exist?(@roughcut_path)

    roughcut = YAML.load_file(@roughcut_path, permitted_classes: [Date, Time, Symbol])
    library_name = library_name_from_path(@roughcut_path)
    library_yaml_path = "libraries/#{library_name}/library.yaml"
    raise "Library file not found: #{library_yaml_path}" unless File.exist?(library_yaml_path)

    library_data = YAML.load_file(library_yaml_path, permitted_classes: [Date, Time, Symbol])
    video_paths = library_data['videos'].each_with_object({}) { |v, h| h[File.basename(v['path'])] = v['path'] }

    buttercut_clips = build_buttercut_clips(roughcut, video_paths)
    overlays = load_overlays
    editor_symbol = resolve_editor_symbol(@editor_choice)

    puts "Converting #{buttercut_clips.length} clips#{overlays.any? ? " (+#{overlays.length} overlays)" : ''} to #{editor_label(editor_symbol)} XML..."

    generator = ButterCut.new(buttercut_clips, editor: editor_symbol, overlays: overlays)
    generator.save(@output_path)
    puts "\n✓ Rough cut exported to: #{@output_path}"

    validate_fcpxml(@output_path) if editor_symbol == :fcpx

    recipe_path = @output_path.sub(/\.[^.]+\z/, '') + '.recipe.json'
    timeline_name = File.basename(@roughcut_path, File.extname(@roughcut_path))
    RecipeFromRoughcut.export(
      roughcut_path: @roughcut_path,
      recipe_path: recipe_path,
      library_name: library_name,
      timeline_name: timeline_name,
      broll_entries: broll_entries_for_recipe
    )
    puts "✓ Recipe exported to: #{recipe_path}"

    apply_path = @output_path.sub(/\.[^.]+\z/, '') + '_apply.py'
    GenerateApplyScript.generate(recipe_path: recipe_path, output_path: apply_path)
    puts "✓ Apply script generated: #{apply_path}"
  end

  private

  def library_name_from_path(path)
    m = path.match(%r{libraries/([^/]+)/roughcuts})
    raise "Could not extract library name from path: #{path}" unless m
    m[1]
  end

  def build_buttercut_clips(roughcut, video_paths)
    roughcut['clips'].map do |clip|
      source_file = clip['source_file']
      raise "Source file not found in library: #{source_file}" unless video_paths[source_file]
      start_at = timecode_to_seconds(clip['in_point'])
      out_point = timecode_to_seconds(clip['out_point'])
      duration = out_point - start_at
      entry = { path: video_paths[source_file], start_at: start_at.to_f, duration: duration.to_f }
      entry[:speed_ramps] = clip['speed_ramps'] if clip['speed_ramps']
      entry
    end
  end

  def broll_yaml_path
    @roughcut_path.sub(/\.[^.]+\z/, '') + '.broll.yaml'
  end

  def manifest
    return @manifest if defined?(@manifest)
    @manifest = File.exist?(broll_yaml_path) ? ButterCut::BrollManifest.load(broll_yaml_path) : nil
  end

  def load_overlays
    return [] if manifest.nil?

    manifest.entries.filter_map do |entry|
      if entry['rendered'].nil? || entry['rendered'].empty?
        warn "[export] skipping #{entry['id']}: rendered is empty"
        next nil
      end
      rendered_path = absolute_rendered_path(entry['rendered'])
      unless File.exist?(rendered_path)
        warn "[export] skipping #{entry['id']}: rendered file not found at #{rendered_path}"
        next nil
      end
      {
        source: rendered_path,
        source_id: entry['id'],
        start: entry['start'],
        duration: entry['end'] - entry['start'],
        placement: entry['placement'],
        pip_corner: entry['pip_corner'],
        pip_scale: entry['pip_scale']
      }
    end
  end

  def absolute_rendered_path(rendered)
    return rendered if File.absolute_path?(rendered)
    File.expand_path(rendered, File.dirname(File.dirname(@roughcut_path)))
  end

  def broll_entries_for_recipe
    return nil if manifest.nil?
    manifest.entries.filter_map do |entry|
      next nil if entry['rendered'].nil? || entry['rendered'].empty?
      {
        'id' => entry['id'],
        'start' => entry['start'],
        'end' => entry['end'],
        'placement' => entry['placement'],
        'source' => entry['rendered'],
        'source_video' => entry['source_video']
      }
    end
  end

  def timecode_to_seconds(timecode)
    parts = timecode.split(':')
    parts[0].to_i * 3600 + parts[1].to_i * 60 + parts[2].to_f
  end

  def resolve_editor_symbol(editor_choice)
    case editor_choice.downcase
    when 'fcpx', 'finalcutpro', 'finalcut', 'fcp' then :fcpx
    when 'premiere', 'premierepro', 'adobepremiere', 'resolve', 'davinci', 'davinciresolve' then :fcp7
    else raise "Unknown editor '#{editor_choice}'. Use 'fcpx', 'premiere', or 'resolve'"
    end
  end

  def editor_label(symbol)
    symbol == :fcpx ? "Final Cut Pro X" : "FCP7-compatible"
  end

  def validate_fcpxml(xml_path)
    dtd_v110 = File.expand_path('../../../dtd/FCPXMLv1_10.dtd', __dir__)
    dtd_v18  = File.expand_path('../../../dtd/FCPXMLv1_8.dtd', __dir__)
    dtd_path, dtd_label =
      if File.exist?(dtd_v110)
        [dtd_v110, "FCPXMLv1_10.dtd"]
      elsif File.exist?(dtd_v18)
        [dtd_v18, "FCPXMLv1_8.dtd (best-effort fallback for 1.10 output)"]
      end

    unless dtd_path && system('command -v xmllint > /dev/null 2>&1')
      puts "⚠ Skipping FCPXML DTD validation (no DTD or xmllint)."
      return
    end

    output = `xmllint --noout --dtdvalid "#{dtd_path}" "#{xml_path}" 2>&1`
    if $?.success?
      puts "✓ FCPXML validates against #{dtd_label}"
    else
      warn "✗ FCPXML failed DTD validation against #{dtd_label}:"
      warn output
      raise "FCPXML DTD validation failed"
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  if ARGV.length < 2 || ARGV.length > 3
    puts "Usage: #{$PROGRAM_NAME} <roughcut.yaml> <output.xml> [editor]"
    puts "  editor: fcpx (default), premiere, or resolve"
    exit 1
  end
  RoughcutExporter.export(
    roughcut_path: ARGV[0],
    output_path: ARGV[1],
    editor: ARGV[2] || 'fcpx'
  )
end
```

- [ ] **Step 4: Update `recipe_from_roughcut.rb` to accept `broll_entries:` and emit them**

In `.claude/skills/roughcut/recipe_from_roughcut.rb`:

1. Update the class method + initializer to accept `broll_entries:`:

```ruby
def self.export(roughcut_path:, recipe_path:, library_name:, timeline_name:, broll_entries: nil)
  new(
    roughcut_path: roughcut_path,
    recipe_path: recipe_path,
    library_name: library_name,
    timeline_name: timeline_name,
    broll_entries: broll_entries
  ).export
end

def initialize(roughcut_path:, recipe_path:, library_name:, timeline_name:, broll_entries: nil)
  raise ArgumentError, "roughcut_path required" if roughcut_path.nil? || roughcut_path.empty?
  raise ArgumentError, "recipe_path required" if recipe_path.nil? || recipe_path.empty?
  raise ArgumentError, "library_name required" if library_name.nil? || library_name.empty?
  raise ArgumentError, "timeline_name required" if timeline_name.nil? || timeline_name.empty?

  @roughcut_path = roughcut_path
  @recipe_path = recipe_path
  @library_name = library_name
  @timeline_name = timeline_name
  @broll_entries = broll_entries
end
```

2. In `build_hash`, bump version to 3 and attach the broll array if provided:

```ruby
def build_hash
  h = {
    "version" => ButterCut::Recipe::SCHEMA_VERSION,
    "library" => @library_name,
    "timeline" => @timeline_name,
    "clips" => build_clips
  }
  h["render_preset"] = stringify(roughcut["render_preset"]) if roughcut["render_preset"]
  h["powergrade"] = stringify(roughcut["powergrade"]) if roughcut["powergrade"]
  h["transitions"] = stringify(roughcut["transitions"]) if roughcut["transitions"]
  h["title_card"] = stringify(roughcut["title_card"]) if roughcut["title_card"]
  h["broll"] = @broll_entries if @broll_entries && !@broll_entries.empty?
  h
end
```

(`ButterCut::Recipe::SCHEMA_VERSION` is now 3, so this auto-bumps.)

- [ ] **Step 5: Run tests — expect green**

```bash
bundle exec rspec spec/buttercut/export_to_fcpxml_broll_spec.rb
```

Expected: green. If `recipe_from_roughcut_spec.rb` breaks because of the new kwarg, run it too:

```bash
bundle exec rspec spec/recipe_from_roughcut_spec.rb
```

Existing callers don't pass `broll_entries:`, and it has a default of `nil`, so existing tests should pass. If a test fails because the recipe version changed from 2 to 3, update that expectation in the test (the recipe is now v3 by design).

- [ ] **Step 6: Commit**

```bash
git add .claude/skills/roughcut/export_to_fcpxml.rb .claude/skills/roughcut/recipe_from_roughcut.rb spec/buttercut/export_to_fcpxml_broll_spec.rb spec/fixtures/broll_integration/
git commit -m "feat: discover sibling broll.yaml during XML export (#33)"
```

---

## Task 8: Apply script logs b-roll count

**Files:**
- Modify: `.claude/skills/roughcut/generate_apply_script.rb`
- Modify: `spec/generate_apply_script_spec.rb`

- [ ] **Step 1: Open the existing apply-script generator and find where it writes the Python preamble**

```bash
sed -n '1,80p' .claude/skills/roughcut/generate_apply_script.rb
```

Look for where the generated Python prints a startup message (e.g. `print("Applying recipe...")`). We'll add one extra line referencing `recipe.get('broll', [])`.

- [ ] **Step 2: Add a failing test**

In `spec/generate_apply_script_spec.rb`, add an example that asserts the generated Python contains a b-roll log line:

```ruby
it "logs the b-roll count when the recipe has a broll array" do
  recipe = JSON.parse(File.read('spec/fixtures/recipes/minimal.recipe.json'))
  recipe['broll'] = [{ 'id' => 'br-0001', 'start' => 1.0, 'end' => 2.0, 'placement' => 'overlay',
                       'source' => 'broll/br-0001.mp4', 'source_video' => 'a.mov' }]
  Dir.mktmpdir do |dir|
    recipe_path = File.join(dir, 'r.recipe.json')
    apply_path = File.join(dir, 'r_apply.py')
    File.write(recipe_path, JSON.pretty_generate(recipe))
    GenerateApplyScript.generate(recipe_path: recipe_path, output_path: apply_path)
    contents = File.read(apply_path)
    expect(contents).to match(/broll.*1.*clip/i)
  end
end
```

(If `spec/fixtures/recipes/minimal.recipe.json` doesn't exist, look at existing tests in `spec/generate_apply_script_spec.rb` for the pattern they use to build a recipe fixture and follow that.)

- [ ] **Step 3: Run — expect failure**

```bash
bundle exec rspec spec/generate_apply_script_spec.rb
```

- [ ] **Step 4: Edit `generate_apply_script.rb` to emit the log line**

Find the section where it composes the Python script body (it concatenates strings with `<<~PYTHON`). After the existing recipe-load preamble, append:

```python
broll_clips = recipe.get('broll', [])
if broll_clips:
    print(f"  • {len(broll_clips)} b-roll clip(s) present (placement is carried in the XML; nothing to apply here)")
```

Use Edit with enough surrounding context for a unique match — anchor on a string already present in the generator (e.g. the top-level `print("Applying recipe…"` line).

- [ ] **Step 5: Run — expect green**

```bash
bundle exec rspec spec/generate_apply_script_spec.rb
```

- [ ] **Step 6: Commit**

```bash
git add .claude/skills/roughcut/generate_apply_script.rb spec/generate_apply_script_spec.rb
git commit -m "feat: apply script logs b-roll clip count (#33)"
```

---

## Task 9: Template + docs updates

**Files:**
- Modify: `templates/broll_template.yaml`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update `templates/broll_template.yaml`**

Bump `version: 1` to `version: 2` in the canonical example, and document the pip fields. Locate the `term-card` example and replace the file's body with one that demonstrates each placement. Use Edit; the anchor string is `version: 1` (which appears once near the top).

Replace:

```yaml
version: 1
```

with:

```yaml
version: 2
```

Then locate the second sample entry (`id: br-0002`) and after the existing entries, append a new pip example:

```yaml
  - id: br-0003
    source_video: tutorial_01.mov
    start: 95.00
    end:   100.00
    template: code-callout
    placement: pip
    pip_corner: top_right     # top_right | top_left | bottom_right | bottom_left (default top_right)
    pip_scale: 0.33           # 0.05..0.95 fraction of frame (default 0.33)
    content:
      command: "ls -la"
    rendered: null
```

- [ ] **Step 2: Update `CLAUDE.md`**

Find the existing rough-cut artifacts paragraph that already contains "Manifest entries are rendered to MP4 via the `render-broll` skill". After that sentence, append:

```
Manifest entries with `rendered` populated are placed onto the timeline by the rough-cut export step (sibling-file convention `<roughcut>.broll.yaml`); each entry rides on V2 with muted audio so the V1 spine and audio bed are untouched.
```

Use Edit; anchor on the unique substring `the parent updates each entry's \`rendered\` field after the sub-agent returns.`

- [ ] **Step 3: Run full test suite**

```bash
bundle exec rspec
```

Expected: green.

- [ ] **Step 4: Commit**

```bash
git add templates/broll_template.yaml CLAUDE.md
git commit -m "docs: document broll v2 schema + roughcut integration (#33)"
```

---

## Task 10: End-to-end smoke test (manual)

**Files:** none.

- [ ] **Step 1: Run the full RSpec suite one more time**

```bash
bundle exec rspec
```

Expected: green.

- [ ] **Step 2: Sanity-export the fixture rough cut by hand**

```bash
mkdir -p /tmp/broll-integration-smoke/libraries/fixture-library/roughcuts
cp spec/fixtures/broll_integration/sample_roughcut.yaml /tmp/broll-integration-smoke/libraries/fixture-library/roughcuts/
cat > /tmp/broll-integration-smoke/libraries/fixture-library/roughcuts/sample_roughcut.broll.yaml <<EOF
version: 2
library: fixture-library
roughcut: sample_roughcut
entries:
  - id: br-0001
    source_video: MVI_0323_720p.mov
    start: 1.0
    end: 2.0
    template: code-callout
    placement: overlay
    content: { command: "git status" }
    rendered: $(pwd)/spec/fixtures/media/MVI_0323_720p.mov
EOF
cat > /tmp/broll-integration-smoke/libraries/fixture-library/library.yaml <<EOF
videos:
  - path: $(pwd)/spec/fixtures/media/MVI_0323_720p.mov
EOF

cd /tmp/broll-integration-smoke && \
  ruby -I "$OLDPWD/lib" "$OLDPWD/.claude/skills/roughcut/export_to_fcpxml.rb" \
    libraries/fixture-library/roughcuts/sample_roughcut.yaml \
    libraries/fixture-library/roughcuts/sample_roughcut.xml \
    fcpx
cd $OLDPWD

grep -c 'lane="1"' /tmp/broll-integration-smoke/libraries/fixture-library/roughcuts/sample_roughcut.xml
```

Expected: prints `1` (one lane-1 overlay clip in the output XML).

---

## Task 11: Open the PR

**Files:** none — repo state.

- [ ] **Step 1: Push branch**

```bash
git push -u origin feat/broll-integration
```

- [ ] **Step 2: Open PR against William-Hill/buttercut**

```bash
gh pr create -R William-Hill/buttercut --title "feat: roughcut integration consumes broll manifest (#33)" --body "$(cat <<'EOF'
## Summary
- Closes #33. Roughcut export now discovers a sibling `<roughcut>.broll.yaml` and places every entry with `rendered` populated onto a connected V2 lane on the timeline.
- All placements (overlay/cutaway/pip) ride on V2; b-roll audio is muted so the V1 audio bed continues underneath. Per the design spec, this is the chosen interpretation of "cutaway" — no V1 splice.
- PiP carries optional `pip_corner` + `pip_scale` driving an FCPXML `<adjust-transform>` or xmeml Motion `<filter>`.
- BrollManifest schema bumped 1 → 2; v1 still accepted with deprecation warning.
- Recipe schema bumped 2 → 3; recipe.json now carries an optional `broll` array (informational; the XML is authoritative for placement).

## Test plan
- [x] Unit: BrollManifest v2 pip validation, v1 deprecation warning
- [x] Unit: Recipe v3 broll array round-trip
- [x] Unit: ButterCut::Overlay value class + pip transform math
- [x] Unit: FCPX emits `lane="1"` connected clips, mute filter, adjust-transform for pip
- [x] Unit: FCP7 emits second `<track>`, Motion Basic Motion filter for pip
- [x] Integration: export_to_fcpxml discovers sibling broll.yaml, recipe.json contains broll array
- [x] No-regression: empty/absent broll.yaml produces XML byte-identical (modulo UUIDs) to today's output
- [x] Manual: smoke export of fixture rough cut + manifest, confirms one lane-1 clip in output

## Out of scope
- Director skill (#30) — this PR consumes manifests; doesn't author them
- Late-render / non-destructive swap-in-place (#34)
- True V1 splice for cutaways (deferred per design)
EOF
)"
```

---

## Self-Review

**Spec coverage:**
- Cutaway = V2 with audio bed preserved → Tasks 5, 6 (overlay emission identical for all three placements). ✓
- PiP `pip_corner` + `pip_scale` schema → Task 1; default values + validation → Task 3. ✓
- All b-roll audio muted → Tasks 5 (`-96dB` adjust-volume), 6 (no audio track on V2). ✓
- `ButterCut.new(overlays:)` API → Task 4. ✓
- FCPX lane="1" + adjust-transform → Task 5. ✓
- FCP7 second `<track>` + Motion filter → Task 6. ✓
- Resolve apply script logs b-roll count → Task 8. ✓
- BrollManifest v2 with v1 deprecation warning → Task 1. ✓
- Recipe v3 with optional broll array → Tasks 2 + 7 (export wires it through). ✓
- Sibling-file discovery → Task 7. ✓
- Empty/absent manifest = no regression → Task 5 has explicit byte-equivalence test; Task 7 has a no-broll-yaml example. ✓
- roughcut.yaml unchanged → no task touches it. ✓
- Template + CLAUDE.md doc updates → Task 9. ✓

**Placeholder scan:** all code blocks are concrete; no "TODO"/"TBD"/"add error handling". Task 8 references an existing fixture path — if it doesn't exist, the step instructs the engineer to follow the pattern of existing tests. Acceptable trade-off given uncertainty about that file's state.

**Type consistency:**
- `Overlay#pip_transform` returns `{ scale:, x:, y:, corner: }` — Task 3 defines, Task 5 (FCPX) consumes `:scale`/`:x`/`:y`, Task 6 (FCP7) consumes `:scale`/`:x`/`:y`. ✓
- `BrollManifest::SCHEMA_VERSION = 2`, `Recipe::SCHEMA_VERSION = 3` — internally consistent across Tasks 1, 2, 7, 9. ✓
- `RoughcutExporter.export(roughcut_path:, output_path:, editor:)` — signature in Task 7 matches CLI dispatch + test usage. ✓
- `RecipeFromRoughcut.export(... broll_entries:)` — signature defined and called identically in Task 7. ✓

**Open variance from spec:** The spec called the helper file `lib/buttercut/overlay_emitter.rb`; I implemented it as `lib/buttercut/overlay.rb` (a value class) with emission logic kept inside each generator. Reason: FCPX uses `lane=` attributes attached to spine clips while FCP7 uses a separate `<track>` — the DOM emission is too divergent to share, but the data-shape + pip-transform math benefits from being in a value class. Documented at Task 3.
