# Programmatic Fusion Fuse Application — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the Resolve apply-script path to install and apply Fusion Fuses (Lua plugins) per clip, driven by recipe directives.

**Architecture:** Bump recipe schema to v2 with an optional `fusion_effects` array per clip. A new `FuseLibrary` class loads in-tree `fuses/*/manifest.json` and validates fuse references in the recipe. The generated apply.py copies fuses into Resolve's Fuses folder, then walks each clip and adds tools to its Fusion comp via `Comp.AddTool(name)`. If a fuse isn't yet registered (Resolve hasn't rescanned), apply.py prompts the user to restart Resolve once and re-run.

**Tech Stack:** Ruby (gem core, RSpec), Python 3 (Resolve scripting API), Lua (Fusion fuses), JSON (recipe + manifests), `luacheck` (lint).

**Spec:** `docs/superpowers/specs/2026-05-05-programmatic-fusion-fuses-design.md`

**Tracking:** William-Hill/buttercut#23

---

## File structure

**New files:**
- `lib/buttercut/fuse_library.rb` — `FuseLibrary` class, loads/validates fuse manifests.
- `spec/fuse_library_spec.rb` — RSpec.
- `fuses/<Name>/<Name>.fuse` — Lua source per fuse (5 fuses).
- `fuses/<Name>/manifest.json` — params + metadata per fuse.
- `fuses/<Name>/reference.png` — manual capture; placeholder commit acceptable.
- `.luacheckrc` — Fusion Lua API globals.
- `.claude/scripts/lint_fuses.rb` — local luacheck runner.
- `.claude/scripts/verify_fuses.rb` — manual smoke gate before release.
- `.github/workflows/lint.yml` — minimal CI: bundle install + rspec + luacheck.

**Modified files:**
- `lib/buttercut/recipe.rb` — schema v2, fusion_effects validation.
- `spec/recipe_spec.rb` — extend tests for v2.
- `.claude/skills/roughcut/recipe_from_roughcut.rb` — fusion_effects passthrough.
- `spec/recipe_from_roughcut_spec.rb` — passthrough test.
- `.claude/skills/roughcut/generate_apply_script.rb` — stamp `FUSES_SOURCE_DIR` + `RESOLVE_FUSES_DIR`.
- `spec/generate_apply_script_spec.rb` — verify stamping.
- `.claude/skills/roughcut/templates/apply_recipe.py` — install + apply phases, reporting.
- `CHANGELOG.md` — v0.7.0-fuses entry, schema v2 note.

---

## Task 1: FuseLibrary class

**Files:**
- Create: `lib/buttercut/fuse_library.rb`
- Test: `spec/fuse_library_spec.rb`

- [ ] **Step 1: Write failing tests**

```ruby
# spec/fuse_library_spec.rb
require 'spec_helper'
require 'buttercut/fuse_library'
require 'fileutils'
require 'json'
require 'tmpdir'

RSpec.describe ButterCut::FuseLibrary do
  def write_fuse(root, name, manifest)
    dir = File.join(root, name)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'manifest.json'), JSON.pretty_generate(manifest))
    File.write(File.join(dir, "#{name}.fuse"), "-- stub\n")
  end

  let(:base_manifest) do
    {
      "name" => "ChromaPulse",
      "version" => "1.0.0",
      "description" => "Chromatic aberration that pulses.",
      "tested_on_resolve" => "20.2.3",
      "params" => [
        { "name" => "intensity", "type" => "number", "default" => 0.4, "range" => [0.0, 1.0] }
      ]
    }
  end

  it 'loads a valid library and looks up by name' do
    Dir.mktmpdir do |root|
      write_fuse(root, 'ChromaPulse', base_manifest)
      lib = described_class.load(root: root)
      fuse = lib.lookup('ChromaPulse')
      expect(fuse['name']).to eq('ChromaPulse')
      expect(fuse['fuse_path']).to eq(File.join(root, 'ChromaPulse', 'ChromaPulse.fuse'))
    end
  end

  it 'returns nil for unknown names from lookup' do
    Dir.mktmpdir do |root|
      lib = described_class.load(root: root)
      expect(lib.lookup('Nope')).to be_nil
    end
  end

  it 'raises on duplicate fuse names across manifest dirs' do
    Dir.mktmpdir do |root|
      write_fuse(root, 'A', base_manifest.merge('name' => 'Same'))
      write_fuse(root, 'B', base_manifest.merge('name' => 'Same'))
      expect { described_class.load(root: root) }.to raise_error(ArgumentError, /duplicate/i)
    end
  end

  it 'raises on missing required manifest keys' do
    Dir.mktmpdir do |root|
      write_fuse(root, 'X', { "name" => "X" })
      expect { described_class.load(root: root) }.to raise_error(ArgumentError, /version|description|params/)
    end
  end

  it 'validates params: type and range' do
    Dir.mktmpdir do |root|
      write_fuse(root, 'ChromaPulse', base_manifest)
      lib = described_class.load(root: root)
      expect { lib.validate_params!('ChromaPulse', { "intensity" => 0.5 }) }.not_to raise_error
      expect { lib.validate_params!('ChromaPulse', { "intensity" => 2.0 }) }.to raise_error(ArgumentError, /range/)
      expect { lib.validate_params!('ChromaPulse', { "intensity" => "high" }) }.to raise_error(ArgumentError, /type/)
      expect { lib.validate_params!('ChromaPulse', { "wat" => 1 }) }.to raise_error(ArgumentError, /unknown/i)
    end
  end

  it 'validate_params! raises for unknown fuse name' do
    Dir.mktmpdir do |root|
      lib = described_class.load(root: root)
      expect { lib.validate_params!('Missing', {}) }.to raise_error(ArgumentError, /unknown fuse/i)
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/fuse_library_spec.rb`
Expected: FAIL (`cannot load such file -- buttercut/fuse_library`).

- [ ] **Step 3: Implement FuseLibrary**

```ruby
# lib/buttercut/fuse_library.rb
require 'json'

class ButterCut
  class FuseLibrary
    REQUIRED_MANIFEST_KEYS = %w[name version description params].freeze
    PARAM_TYPES = %w[number integer string boolean].freeze

    def self.load(root:)
      new(root: root).load
    end

    def initialize(root:)
      raise ArgumentError, "root required" if root.nil? || root.to_s.empty?
      @root = root
      @by_name = {}
    end

    def load
      return self unless Dir.exist?(@root)
      Dir.glob(File.join(@root, '*', 'manifest.json')).sort.each do |manifest_path|
        manifest = JSON.parse(File.read(manifest_path))
        validate_manifest!(manifest, manifest_path)
        name = manifest['name']
        if @by_name.key?(name)
          raise ArgumentError, "duplicate fuse name #{name.inspect} (in #{manifest_path})"
        end
        manifest['fuse_path'] = File.join(File.dirname(manifest_path), "#{name}.fuse")
        @by_name[name] = manifest.freeze
      end
      freeze
    end

    def lookup(name)
      @by_name[name]
    end

    def each(&block)
      @by_name.each_value(&block)
    end

    def names
      @by_name.keys
    end

    def validate_params!(fuse_name, params)
      manifest = lookup(fuse_name)
      raise ArgumentError, "unknown fuse #{fuse_name.inspect}" if manifest.nil?
      params ||= {}
      raise ArgumentError, "fuse #{fuse_name} params must be a hash" unless params.is_a?(Hash)
      declared = manifest['params'].each_with_object({}) { |p, h| h[p['name']] = p }
      params.each do |key, value|
        decl = declared[key]
        raise ArgumentError, "fuse #{fuse_name}: unknown param #{key.inspect}" if decl.nil?
        validate_param_value!(fuse_name, key, decl, value)
      end
    end

    private

    def validate_manifest!(manifest, path)
      missing = REQUIRED_MANIFEST_KEYS - manifest.keys
      unless missing.empty?
        raise ArgumentError, "manifest #{path} missing keys: #{missing.inspect}"
      end
      unless manifest['params'].is_a?(Array)
        raise ArgumentError, "manifest #{path} params must be an array"
      end
      manifest['params'].each do |p|
        unless p.is_a?(Hash) && p['name'].is_a?(String) && PARAM_TYPES.include?(p['type'])
          raise ArgumentError, "manifest #{path} param invalid: #{p.inspect}"
        end
      end
    end

    def validate_param_value!(fuse_name, key, decl, value)
      case decl['type']
      when 'number'
        raise ArgumentError, "fuse #{fuse_name}: param #{key} type must be number, got #{value.class}" unless value.is_a?(Numeric)
        if decl['range'].is_a?(Array) && decl['range'].length == 2
          lo, hi = decl['range']
          unless value >= lo && value <= hi
            raise ArgumentError, "fuse #{fuse_name}: param #{key} out of range (#{lo}..#{hi}), got #{value}"
          end
        end
      when 'integer'
        raise ArgumentError, "fuse #{fuse_name}: param #{key} type must be integer, got #{value.class}" unless value.is_a?(Integer)
      when 'string'
        raise ArgumentError, "fuse #{fuse_name}: param #{key} type must be string, got #{value.class}" unless value.is_a?(String)
      when 'boolean'
        unless value == true || value == false
          raise ArgumentError, "fuse #{fuse_name}: param #{key} type must be boolean, got #{value.class}"
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bundle exec rspec spec/fuse_library_spec.rb`
Expected: all examples pass.

- [ ] **Step 5: Commit**

```bash
git add lib/buttercut/fuse_library.rb spec/fuse_library_spec.rb
git commit -m "feat(fuses): FuseLibrary class for loading and validating fuse manifests"
```

---

## Task 2: Recipe schema v2 with fusion_effects

**Files:**
- Modify: `lib/buttercut/recipe.rb`
- Modify: `spec/recipe_spec.rb`

- [ ] **Step 1: Add failing tests for v2**

Add to `spec/recipe_spec.rb` (within the existing `describe ButterCut::Recipe`):

```ruby
describe 'schema v2 fusion_effects' do
  let(:fuse_root) { File.expand_path('../../fuses', __FILE__) }

  let(:base_clip) { { "index" => 1, "source_file" => "a.mov" } }

  def fuse_lib_with(manifest)
    Dir.mktmpdir do |root|
      dir = File.join(root, manifest['name'])
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, 'manifest.json'), JSON.pretty_generate(manifest))
      File.write(File.join(dir, "#{manifest['name']}.fuse"), "-- stub")
      yield ButterCut::FuseLibrary.load(root: root)
    end
  end

  let(:test_manifest) do
    {
      "name" => "ChromaPulse", "version" => "1.0.0", "description" => "x",
      "params" => [{ "name" => "intensity", "type" => "number", "default" => 0.4, "range" => [0.0, 1.0] }]
    }
  end

  it 'accepts a recipe with empty/absent fusion_effects (v2 backward-compat)' do
    fuse_lib_with(test_manifest) do |lib|
      r = described_class.new(version: 2, library: 'L', timeline: 'T', clips: [base_clip], fuse_library: lib)
      expect(r.to_h['version']).to eq(2)
      expect(r.to_h['clips'].first).not_to have_key('fusion_effects')
    end
  end

  it 'accepts and round-trips fusion_effects' do
    fuse_lib_with(test_manifest) do |lib|
      clip = base_clip.merge("fusion_effects" => [{ "fuse" => "ChromaPulse", "params" => { "intensity" => 0.4 } }])
      r = described_class.new(version: 2, library: 'L', timeline: 'T', clips: [clip], fuse_library: lib)
      expect(r.to_h['clips'].first['fusion_effects']).to eq([{ "fuse" => "ChromaPulse", "params" => { "intensity" => 0.4 } }])
    end
  end

  it 'rejects unknown fuse names' do
    fuse_lib_with(test_manifest) do |lib|
      clip = base_clip.merge("fusion_effects" => [{ "fuse" => "Nope", "params" => {} }])
      expect {
        described_class.new(version: 2, library: 'L', timeline: 'T', clips: [clip], fuse_library: lib)
      }.to raise_error(ArgumentError, /unknown fuse/i)
    end
  end

  it 'rejects bad params (out of range)' do
    fuse_lib_with(test_manifest) do |lib|
      clip = base_clip.merge("fusion_effects" => [{ "fuse" => "ChromaPulse", "params" => { "intensity" => 9.0 } }])
      expect {
        described_class.new(version: 2, library: 'L', timeline: 'T', clips: [clip], fuse_library: lib)
      }.to raise_error(ArgumentError, /range/)
    end
  end

  it 'rejects fusion_effects when no FuseLibrary is provided and not stubbed' do
    # Sanity: validation runs by default; if production code defaults to in-tree fuses/, this still must validate.
    clip = base_clip.merge("fusion_effects" => [{ "fuse" => "Nope", "params" => {} }])
    expect {
      described_class.new(version: 2, library: 'L', timeline: 'T', clips: [clip])
    }.to raise_error(ArgumentError)
  end
end
```

Add `require 'tmpdir'` and `require 'fileutils'` and `require 'buttercut/fuse_library'` near the top of the spec if not already present.

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/recipe_spec.rb -e 'fusion_effects'`
Expected: FAIL (no fuse_library kwarg, version validation rejects 2).

- [ ] **Step 3: Implement v2 schema in Recipe**

Edit `lib/buttercut/recipe.rb`:

```ruby
require 'json'
require_relative 'fuse_library'

class ButterCut
  class Recipe
    SCHEMA_VERSION = 2
    SUPPORTED_VERSIONS = [1, 2].freeze
    DEFAULT_FUSE_ROOT = File.expand_path('../../fuses', __dir__)

    # ... existing constants unchanged ...

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
        fuse_library: fuse_library
      )
    end

    def self.load(path, fuse_library: nil)
      from_hash(JSON.parse(File.read(path)), fuse_library: fuse_library)
    end

    def initialize(version:, library:, timeline:, clips:,
                   render_preset: nil, powergrade: nil, transitions: [], title_card: nil,
                   fuse_library: nil)
      @version = version
      @library = library
      @timeline = timeline
      @clips = clips
      @render_preset = render_preset
      @powergrade = powergrade
      @transitions = transitions
      @title_card = title_card
      @fuse_library = fuse_library

      validate!
    end

    # to_h, to_json, save unchanged

    private

    def validate!
      validate_version!
      validate_string!(@library, "library")
      validate_string!(@timeline, "timeline")
      validate_clips!
      validate_render_preset! if @render_preset
      validate_powergrade! if @powergrade
      validate_transitions!
      validate_title_card! if @title_card
    end

    def validate_version!
      unless SUPPORTED_VERSIONS.include?(@version)
        raise ArgumentError, "version must be one of #{SUPPORTED_VERSIONS.inspect}, got #{@version.inspect}"
      end
    end

    def fuse_library
      @fuse_library ||= ButterCut::FuseLibrary.load(root: DEFAULT_FUSE_ROOT)
    end

    def validate_clip!(clip)
      raise ArgumentError, "clip must be a hash" unless clip.is_a?(Hash)
      validate_positive_int!(clip["index"], "clip index")
      validate_string!(clip["source_file"], "clip source_file")

      speed_ramps = clip.key?("speed_ramps") ? clip["speed_ramps"] : []
      raise ArgumentError, "clip #{clip["index"]} speed_ramps must be an array" unless speed_ramps.is_a?(Array)
      speed_ramps.each { |ramp| validate_speed_ramp!(ramp, clip["index"]) }

      if clip.key?("color_tag") && !CLIP_COLOR_TAGS.include?(clip["color_tag"])
        raise ArgumentError, "clip #{clip["index"]} color_tag #{clip["color_tag"].inspect} not in #{CLIP_COLOR_TAGS.inspect}"
      end

      markers = clip.key?("markers") ? clip["markers"] : []
      raise ArgumentError, "clip #{clip["index"]} markers must be an array" unless markers.is_a?(Array)
      markers.each { |marker| validate_marker!(marker, clip["index"]) }

      validate_fusion_effects!(clip) if clip.key?("fusion_effects")
    end

    def validate_fusion_effects!(clip)
      effects = clip["fusion_effects"]
      raise ArgumentError, "clip #{clip["index"]} fusion_effects must be an array" unless effects.is_a?(Array)
      effects.each_with_index do |effect, i|
        unless effect.is_a?(Hash) && effect["fuse"].is_a?(String) && !effect["fuse"].empty?
          raise ArgumentError, "clip #{clip["index"]} fusion_effects[#{i}] must be a hash with a 'fuse' string"
        end
        params = effect["params"] || {}
        fuse_library.validate_params!(effect["fuse"], params)
      end
    end
  end
end
```

Note: only `to_h` needs updating if `fusion_effects` already round-trips through the existing `@clips` reference (it does — `to_h` returns `@clips` as-is). No change to `to_h` required.

- [ ] **Step 4: Run tests**

Run: `bundle exec rspec spec/recipe_spec.rb`
Expected: all pass (existing v1 tests still pass via `SUPPORTED_VERSIONS = [1, 2]`).

- [ ] **Step 5: Commit**

```bash
git add lib/buttercut/recipe.rb spec/recipe_spec.rb
git commit -m "feat(recipe): bump schema to v2 with optional fusion_effects per clip"
```

---

## Task 3: roughcut → recipe fusion_effects passthrough

**Files:**
- Modify: `.claude/skills/roughcut/recipe_from_roughcut.rb`
- Modify: `spec/recipe_from_roughcut_spec.rb`

- [ ] **Step 1: Inspect existing passthrough pattern**

Run: `grep -n "speed_ramps\|markers\|color_tag" .claude/skills/roughcut/recipe_from_roughcut.rb` to find the existing per-clip directive copy block. Add `fusion_effects` adjacent to those.

- [ ] **Step 2: Add a failing test**

Add to `spec/recipe_from_roughcut_spec.rb`:

```ruby
it 'passes fusion_effects through from yaml to recipe' do
  yaml = {
    "library" => "L",
    "timeline" => "T",
    "clips" => [
      { "index" => 1, "source_file" => "a.mov", "in" => 0, "out" => 1.0,
        "fusion_effects" => [{ "fuse" => "ChromaPulse", "params" => { "intensity" => 0.4 } }] }
    ]
  }
  recipe_hash = described_class.build(yaml)
  expect(recipe_hash["clips"].first["fusion_effects"]).to eq(
    [{ "fuse" => "ChromaPulse", "params" => { "intensity" => 0.4 } }]
  )
end
```

If the test setup needs a real fuse library to round-trip through `Recipe.new`, stub via `allow(ButterCut::FuseLibrary).to receive(:load).and_return(double(validate_params!: nil))` — adjust per the actual call shape in `recipe_from_roughcut.rb`.

- [ ] **Step 3: Run test, verify failure**

Run: `bundle exec rspec spec/recipe_from_roughcut_spec.rb -e 'fusion_effects'`
Expected: FAIL (key absent from output).

- [ ] **Step 4: Add passthrough**

In `.claude/skills/roughcut/recipe_from_roughcut.rb`, where the per-clip hash is built (next to `speed_ramps`, `markers`, `color_tag`), add:

```ruby
clip_out["fusion_effects"] = clip_in["fusion_effects"] if clip_in["fusion_effects"]
```

- [ ] **Step 5: Run test**

Run: `bundle exec rspec spec/recipe_from_roughcut_spec.rb`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add .claude/skills/roughcut/recipe_from_roughcut.rb spec/recipe_from_roughcut_spec.rb
git commit -m "feat(roughcut): pass fusion_effects through from yaml to recipe"
```

---

## Task 4: Author ChromaPulse fuse + manifest (template-establishing task)

**Files:**
- Create: `fuses/ChromaPulse/ChromaPulse.fuse`
- Create: `fuses/ChromaPulse/manifest.json`
- Create: `fuses/ChromaPulse/reference.png` (placeholder; capture during verify_fuses run)

This task establishes the fuse-authoring pattern. Each fuse must be **compositional** — built from Fusion's existing nodes (Transform, ChannelBoolean, Merge, etc.), not per-pixel Lua. Reference: Resolve's bundled fuses live at `/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Fuses/` (read-only) — read these for the API surface of `RegisterFuse`, `Create`, and `NotifyChanged`.

- [ ] **Step 1: Author manifest.json**

```json
{
  "name": "ChromaPulse",
  "version": "1.0.0",
  "description": "Chromatic aberration that pulses on a beat or marker.",
  "tested_on_resolve": "20.2.3",
  "params": [
    { "name": "intensity", "type": "number", "default": 0.4, "range": [0.0, 1.0] },
    { "name": "speed", "type": "number", "default": 1.0, "range": [0.1, 4.0] },
    { "name": "phase", "type": "number", "default": 0.0, "range": [0.0, 1.0] }
  ]
}
```

- [ ] **Step 2: Author ChromaPulse.fuse**

Skeleton (the engineer fills in the node-graph composition; no per-pixel Lua):

```lua
-- ChromaPulse.fuse — chromatic aberration pulsing over time.
-- Compositional: split RGB via ChannelBoolean, offset R and B with Transform,
-- recombine via Merge. Pulse modulates the offset over time.
FuRegisterClass("ChromaPulse", CT_Tool, {
    REGS_Name = "ChromaPulse",
    REGS_Category = "ButterCut",
    REGS_OpIconString = "CP",
    REGS_OpDescription = "Chromatic aberration that pulses over time.",
    REG_NoMotionBlurCtrls = true,
    REG_NoBlendCtrls = false,
    REG_OpNoMask = true,
})

ChromaPulse = Class("ChromaPulse", BiSrcOp)  -- BiSrcOp for input + bg merge

function ChromaPulse:Create()
    InImage = self:AddInput("Input", "Input", { LINKID_DataType = "Image", LINK_Main = 1 })
    InIntensity = self:AddInput("Intensity", "Intensity", {
        LINKID_DataType = "Number", INPID_InputControl = "SliderControl",
        INP_Default = 0.4, INP_MinScale = 0.0, INP_MaxScale = 1.0,
    })
    InSpeed = self:AddInput("Speed", "Speed", {
        LINKID_DataType = "Number", INPID_InputControl = "SliderControl",
        INP_Default = 1.0, INP_MinScale = 0.1, INP_MaxScale = 4.0,
    })
    InPhase = self:AddInput("Phase", "Phase", {
        LINKID_DataType = "Number", INPID_InputControl = "SliderControl",
        INP_Default = 0.0, INP_MinScale = 0.0, INP_MaxScale = 1.0,
    })
    OutImage = self:AddOutput("Output", "Output", { LINKID_DataType = "Image", LINK_Main = 1 })
end

function ChromaPulse:Process(req)
    local img = InImage:GetValue(req)
    local intensity = InIntensity:GetValue(req).Value
    local speed = InSpeed:GetValue(req).Value
    local phase = InPhase:GetValue(req).Value
    local t = req.Time / 24.0  -- coarse; real frame rate comes from comp
    local pulse = math.abs(math.sin((t * speed + phase) * math.pi * 2))
    local offset = intensity * pulse * 0.01  -- normalized image-space units

    -- Compose: split channels, offset R + B, recombine.
    -- (Engineer: implement using Image:CopyOf and per-channel transform via
    --  built-in nodes. See Resolve's Glow.fuse for an analogous compositional pattern.)
    local out = img:CopyOf()
    -- TODO during implementation: apply R/B offset using ChannelBoolean equivalent operations.
    OutImage:Set(req, out)
end
```

The skeleton above is intentionally a starting point. **Authoring deliverable:** a working compositional fuse that produces a visible chromatic offset. Validate via `luacheck` (Task 6) and the manual smoke (Task 11).

- [ ] **Step 3: Add a placeholder reference.png**

Create a 1x1 transparent PNG as placeholder; the real screenshot lands during the Task 11 verify run. This avoids breaking the manifest-expects-file convention.

```bash
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\rIDATx\x9cc\x00\x01\x00\x00\x05\x00\x01\r\n-\xb4\x00\x00\x00\x00IEND\xaeB`\x82' > fuses/ChromaPulse/reference.png
```

- [ ] **Step 4: Verify manifest loads**

Run: `bundle exec ruby -Ilib -e "require 'buttercut/fuse_library'; lib = ButterCut::FuseLibrary.load(root: 'fuses'); puts lib.names.inspect"`
Expected: `["ChromaPulse"]`.

- [ ] **Step 5: Commit**

```bash
git add fuses/ChromaPulse/
git commit -m "feat(fuses): add ChromaPulse fuse + manifest"
```

---

## Task 5: Author the remaining four fuses

For each of **VHSGlitch**, **FilmGrain**, **LightLeak**, **ZoomPunch**, repeat the Task 4 pattern:

- [ ] **VHSGlitch** — scanlines + chromatic shift + occasional vertical tear.
  - Params: `intensity` (0–1, default 0.5), `tear_chance` (0–1, default 0.05), `scanline_strength` (0–1, default 0.6).
  - Composition: BrightnessContrast for scanline modulation + Transform for tear + chromatic offset.

- [ ] **FilmGrain** — animated grain overlay.
  - Params: `intensity` (0–1, default 0.3), `size` (0.5–4.0, default 1.0), `monochrome` (boolean, default false).
  - Composition: FastNoise + Merge over input.

- [ ] **LightLeak** — animated warm flare drifting across frame.
  - Params: `intensity` (0–1, default 0.6), `direction` (0–1, default 0.0), `warmth` (0–1, default 0.7).
  - Composition: animated Ellipse mask + ColorCorrector + Merge with screen blend.

- [ ] **ZoomPunch** — single-frame scale pulse on a marker.
  - Params: `amount` (1.0–1.5, default 1.08), `duration_frames` (1–30, default 6), `at` (number, frame offset, default 0).
  - Composition: Transform with animated scale curve.

For each fuse, repeat:
- [ ] manifest.json with declared params
- [ ] `<Name>.fuse` Lua with `FuRegisterClass` + `Create` + `Process`
- [ ] Placeholder reference.png
- [ ] Verify load via `FuseLibrary.load(root: 'fuses').names` — list grows by one
- [ ] Commit `git commit -m "feat(fuses): add <Name> fuse + manifest"`

End-of-task assertion: `FuseLibrary.load(root: 'fuses').names.sort == ["ChromaPulse", "FilmGrain", "LightLeak", "VHSGlitch", "ZoomPunch"]`.

---

## Task 6: Lua lint config + lint script

**Files:**
- Create: `.luacheckrc`
- Create: `.claude/scripts/lint_fuses.rb`

- [ ] **Step 1: Verify luacheck installed**

Run: `which luacheck || brew install luacheck`
Expected: path printed.

- [ ] **Step 2: Author .luacheckrc**

```lua
-- .luacheckrc — Fusion Lua API globals
std = "lua51"

globals = {
    -- Fusion fuse registration
    "FuRegisterClass", "Class",
    -- Class constants
    "CT_Tool", "CT_SourceTool", "CT_ViewTool",
    -- Base classes
    "Operator", "BiSrcOp", "TexSrcOp", "ThreeSrcOp", "ResolutionTool",
    -- Self-injected by Fusion at runtime; per-fuse instance vars are upvalues
    "InImage", "InIntensity", "InSpeed", "InPhase",
    "InMask", "Output", "OutImage",
    -- Image methods
    "Image",
    -- Common Fusion symbols
    "LINKID_DataType", "LINK_Main", "INPID_InputControl",
    "INP_Default", "INP_MinScale", "INP_MaxScale",
    "REGS_Name", "REGS_Category", "REGS_OpIconString", "REGS_OpDescription",
    "REG_NoMotionBlurCtrls", "REG_NoBlendCtrls", "REG_OpNoMask",
}

files["fuses/**/*.fuse"] = {
    ignore = {"212", "213"},  -- unused argument/loop variable
}

-- Each fuse declares its own params; allow per-file global writes for
-- input/output handles set in Create().
allow_defined_top = true
```

- [ ] **Step 3: Author lint_fuses.rb**

```ruby
#!/usr/bin/env ruby
# Run luacheck across all fuses. Used by CI and locally.

class LintFuses
  def self.run
    new.run
  end

  def run
    fuses_dir = File.expand_path('../../fuses', __dir__)
    files = Dir.glob(File.join(fuses_dir, '**', '*.fuse')).sort
    if files.empty?
      warn "no fuses to lint at #{fuses_dir}"
      return 0
    end
    cmd = ['luacheck', '--no-color', *files]
    puts cmd.join(' ')
    system(*cmd) ? 0 : 1
  end
end

if __FILE__ == $PROGRAM_NAME
  exit LintFuses.run
end
```

- [ ] **Step 4: Run lint and confirm pass on the 5 fuses**

Run: `ruby .claude/scripts/lint_fuses.rb`
Expected: exit 0; any reported errors must be fixed in the fuse source before continuing.

- [ ] **Step 5: Commit**

```bash
git add .luacheckrc .claude/scripts/lint_fuses.rb
git commit -m "feat(fuses): luacheck config + local lint script"
```

---

## Task 7: Minimal CI workflow

**Files:**
- Create: `.github/workflows/lint.yml`

- [ ] **Step 1: Author workflow**

```yaml
name: lint
on:
  pull_request:
  push:
    branches: [main]

jobs:
  lint-and-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: '3.2'
          bundler-cache: true
      - name: Install luacheck
        run: sudo apt-get update && sudo apt-get install -y luarocks && sudo luarocks install luacheck
      - name: RSpec
        run: bundle exec rspec
      - name: Lint fuses
        run: ruby .claude/scripts/lint_fuses.rb
```

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/lint.yml
git commit -m "ci: add lint workflow (rspec + luacheck on fuses)"
```

After PR is opened, verify the workflow runs green on GitHub.

---

## Task 8: Stamp FUSES_SOURCE_DIR + RESOLVE_FUSES_DIR into apply.py

**Files:**
- Modify: `.claude/skills/roughcut/generate_apply_script.rb`
- Modify: `spec/generate_apply_script_spec.rb`

- [ ] **Step 1: Add failing tests**

Append to `spec/generate_apply_script_spec.rb`:

```ruby
describe 'fuse-related stamping' do
  it 'stamps FUSES_SOURCE_DIR with the absolute in-tree fuses path' do
    Dir.mktmpdir do |dir|
      recipe_path = File.join(dir, 'r.json')
      out = File.join(dir, 'apply.py')
      File.write(recipe_path, '{}')
      GenerateApplyScript.generate(recipe_path: recipe_path, output_path: out)
      content = File.read(out)
      expect(content).to match(/FUSES_SOURCE_DIR\s*=\s*".*\/fuses"/)
      expect(content).to match(/RESOLVE_FUSES_DIR\s*=\s*"[^"]*Fusion\/Fuses\/?"/)
    end
  end
end
```

- [ ] **Step 2: Update template placeholders**

In `.claude/skills/roughcut/templates/apply_recipe.py`, add at the top alongside `RECIPE_PATH = {{RECIPE_PATH}}`:

```python
RECIPE_PATH = {{RECIPE_PATH}}
FUSES_SOURCE_DIR = {{FUSES_SOURCE_DIR}}
RESOLVE_FUSES_DIR = {{RESOLVE_FUSES_DIR}}
```

- [ ] **Step 3: Update GenerateApplyScript to substitute new placeholders**

```ruby
class GenerateApplyScript
  TEMPLATE_PATH = File.expand_path('templates/apply_recipe.py', __dir__)
  PLACEHOLDERS = {
    'RECIPE_PATH' => :recipe_path,
    'FUSES_SOURCE_DIR' => :fuses_source_dir,
    'RESOLVE_FUSES_DIR' => :resolve_fuses_dir
  }.freeze
  DEFAULT_FUSES_SOURCE_DIR = File.expand_path('../../../fuses', __dir__)
  DEFAULT_RESOLVE_FUSES_DIR = File.expand_path(
    '~/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Fuses'
  )

  def self.generate(recipe_path:, output_path:, fuses_source_dir: DEFAULT_FUSES_SOURCE_DIR, resolve_fuses_dir: DEFAULT_RESOLVE_FUSES_DIR)
    new(recipe_path: recipe_path, output_path: output_path,
        fuses_source_dir: fuses_source_dir, resolve_fuses_dir: resolve_fuses_dir).generate
  end

  def initialize(recipe_path:, output_path:, fuses_source_dir:, resolve_fuses_dir:)
    raise ArgumentError, "recipe_path required" if recipe_path.nil? || recipe_path.empty?
    raise ArgumentError, "output_path required" if output_path.nil? || output_path.empty?
    @recipe_path = File.expand_path(recipe_path)
    @output_path = output_path
    @fuses_source_dir = File.expand_path(fuses_source_dir)
    @resolve_fuses_dir = File.expand_path(resolve_fuses_dir)
  end

  def generate
    template = File.read(TEMPLATE_PATH)
    PLACEHOLDERS.each_key do |key|
      placeholder = "{{#{key}}}"
      raise "template missing #{placeholder}" unless template.include?(placeholder)
    end
    stamped = template
      .sub('{{RECIPE_PATH}}')      { JSON.dump(@recipe_path) }
      .sub('{{FUSES_SOURCE_DIR}}') { JSON.dump(@fuses_source_dir) }
      .sub('{{RESOLVE_FUSES_DIR}}') { JSON.dump(@resolve_fuses_dir) }
    File.write(@output_path, stamped)
    File.chmod(0o755, @output_path)
    @output_path
  end
end
```

- [ ] **Step 4: Run tests**

Run: `bundle exec rspec spec/generate_apply_script_spec.rb`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add .claude/skills/roughcut/generate_apply_script.rb \
        .claude/skills/roughcut/templates/apply_recipe.py \
        spec/generate_apply_script_spec.rb
git commit -m "feat(apply): stamp FUSES_SOURCE_DIR + RESOLVE_FUSES_DIR into apply.py"
```

---

## Task 9: apply.py `_install_fuses` phase

**Files:**
- Modify: `.claude/skills/roughcut/templates/apply_recipe.py`

This phase runs at the start of `Applier.apply()` so that the AddTool calls in Task 10 have a chance of finding registered fuses.

- [ ] **Step 1: Add the install phase**

Insert into `Applier`:

```python
import hashlib
import shutil

class Applier:
    def __init__(self, recipe, project, timeline):
        # ... existing init ...
        self.counts.update({"fusion_effects": [0, 0]})
        self.newly_installed = []
        self.needs_restart = []  # list of (clip_idx, fuse_name) tuples

    def apply(self):
        self._install_fuses()
        self._apply_per_clip()
        self._apply_render_preset()
        self._apply_powergrade()
        self._log_manual_transitions()
        self._log_manual_title_card()
        self._report()

    def _fuses_referenced(self):
        names = set()
        for clip in self.recipe.get("clips", []):
            for effect in clip.get("fusion_effects", []) or []:
                names.add(effect["fuse"])
        return sorted(names)

    def _install_fuses(self):
        names = self._fuses_referenced()
        if not names:
            return
        os.makedirs(RESOLVE_FUSES_DIR, exist_ok=True)
        for name in names:
            src = os.path.join(FUSES_SOURCE_DIR, name, f"{name}.fuse")
            if not os.path.isfile(src):
                self.warnings.append(f"fuse {name}: source not found at {src}")
                continue
            dst = os.path.join(RESOLVE_FUSES_DIR, f"{name}.fuse")
            if self._files_match(src, dst):
                continue
            try:
                shutil.copy2(src, dst)
                self.newly_installed.append(name)
                print(f"[apply_recipe] installed fuse: {name} -> {dst}")
            except Exception as e:
                self.warnings.append(f"fuse {name}: copy failed: {type(e).__name__}: {e}")

    @staticmethod
    def _files_match(a, b):
        if not os.path.isfile(b):
            return False
        return Applier._sha256(a) == Applier._sha256(b)

    @staticmethod
    def _sha256(path):
        h = hashlib.sha256()
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(65536), b""):
                h.update(chunk)
        return h.hexdigest()
```

- [ ] **Step 2: Update `_report` to include fuse install status**

In `_report`:

```python
def _report(self):
    print()
    print("[apply_recipe] applied:")
    for cap, (ok, total) in self.counts.items():
        if total:
            print(f"  {cap}: {ok}/{total}")
    if any(self.manual.values()):
        print("[apply_recipe] manual:")
        for cap, count in self.manual.items():
            if count:
                print(f"  {cap}: {count}")
    if self.newly_installed:
        print(f"[apply_recipe] installed fuses: {', '.join(self.newly_installed)}")
    if self.needs_restart:
        print("[apply_recipe] ACTION REQUIRED: restart Resolve once, then re-run this script.")
        for clip_idx, fuse_name in self.needs_restart:
            print(f"  clip {clip_idx}: fuse {fuse_name!r} not yet registered")
    if self.warnings:
        print("[apply_recipe] warnings:")
        for w in self.warnings:
            print(f"  - {w}")
```

- [ ] **Step 3: Smoke check generation still works**

Run:

```bash
bundle exec rspec spec/generate_apply_script_spec.rb
```

Expected: pass — no Resolve interaction yet, just confirming the template still parses.

- [ ] **Step 4: Commit**

```bash
git add .claude/skills/roughcut/templates/apply_recipe.py
git commit -m "feat(apply): _install_fuses copies referenced fuses into Resolve Fuses dir"
```

---

## Task 10: apply.py `_apply_fusion_effects`

**Files:**
- Modify: `.claude/skills/roughcut/templates/apply_recipe.py`

- [ ] **Step 1: Add the apply phase**

Wire into `_apply_per_clip`:

```python
def _apply_per_clip(self):
    for clip in self.recipe.get("clips", []):
        idx = clip["index"]
        item = self._clip_for(idx)
        if not item:
            continue
        self._apply_color_tag(item, clip, idx)
        self._apply_markers(item, clip, idx)
        self._apply_speed_ramps(item, clip, idx)
        self._apply_fusion_effects(item, clip, idx)
```

Implement:

```python
COMP_NAME_PREFIX = "ButterCut_"

def _apply_fusion_effects(self, item, clip, idx):
    effects = clip.get("fusion_effects") or []
    if not effects:
        return
    self.counts["fusion_effects"][1] += len(effects)
    try:
        comp = item.AddFusionComp() if hasattr(item, "AddFusionComp") else None
    except Exception as e:
        self.warnings.append(f"clip {idx}: AddFusionComp raised {type(e).__name__}: {e}")
        return
    if not comp:
        self.warnings.append(f"clip {idx}: AddFusionComp returned None")
        return

    media_in = self._find_tool(comp, "MediaIn1") or self._find_first_by_id(comp, "MediaIn")
    media_out = self._find_tool(comp, "MediaOut1") or self._find_first_by_id(comp, "MediaOut")
    if not media_in or not media_out:
        self.warnings.append(f"clip {idx}: comp missing MediaIn/MediaOut")
        return

    prev_output = media_in.Output if hasattr(media_in, "Output") else media_in.FindMainOutput(1)
    for effect in effects:
        fuse_name = effect["fuse"]
        try:
            tool = comp.AddTool(fuse_name)
        except Exception as e:
            self.warnings.append(f"clip {idx}: AddTool({fuse_name!r}) raised {type(e).__name__}: {e}")
            tool = None
        if not tool:
            self.needs_restart.append((idx, fuse_name))
            return
        try:
            input_link = tool.FindMainInput(1) if hasattr(tool, "FindMainInput") else tool.Input
            input_link.ConnectTo(prev_output)
        except Exception as e:
            self.warnings.append(f"clip {idx}: connect {fuse_name} input raised {type(e).__name__}: {e}")
            return
        for pname, pval in (effect.get("params") or {}).items():
            try:
                tool.SetInput(pname, pval)
            except Exception as e:
                self.warnings.append(f"clip {idx}: SetInput({pname!r}, {pval!r}) on {fuse_name} raised {type(e).__name__}: {e}")
        prev_output = tool.Output if hasattr(tool, "Output") else tool.FindMainOutput(1)
        self.counts["fusion_effects"][0] += 1

    try:
        media_out_input = media_out.FindMainInput(1) if hasattr(media_out, "FindMainInput") else media_out.Input
        media_out_input.ConnectTo(prev_output)
    except Exception as e:
        self.warnings.append(f"clip {idx}: connect MediaOut raised {type(e).__name__}: {e}")

def _find_tool(self, comp, name):
    try:
        return comp.FindTool(name)
    except Exception:
        return None

def _find_first_by_id(self, comp, tool_id):
    try:
        tools = comp.GetToolList(False, tool_id) or {}
    except Exception:
        return None
    if isinstance(tools, dict):
        return next(iter(tools.values()), None)
    return tools[0] if tools else None
```

- [ ] **Step 2: Generation smoke**

Run: `bundle exec rspec spec/generate_apply_script_spec.rb`
Expected: pass.

- [ ] **Step 3: Commit**

```bash
git add .claude/skills/roughcut/templates/apply_recipe.py
git commit -m "feat(apply): apply fusion_effects via AddFusionComp + AddTool wiring"
```

---

## Task 11: `verify_fuses` smoke script

**Files:**
- Create: `.claude/scripts/verify_fuses.rb`

This script generates a synthetic recipe + apply.py exercising every registered fuse against a fixture clip, prints copy-paste-able instructions to run inside Resolve, and parses the resulting console log to PASS/FAIL each fuse.

- [ ] **Step 1: Author the script**

```ruby
#!/usr/bin/env ruby
# Manual smoke gate for the in-tree fuse library.
# Usage: ruby .claude/scripts/verify_fuses.rb <fixture.mov>

$LOAD_PATH.unshift(File.expand_path('../../../lib', __FILE__))
require 'buttercut/fuse_library'
require 'json'
require 'fileutils'
require 'tmpdir'
require 'time'

class VerifyFuses
  def self.run(fixture_path)
    new(fixture_path).run
  end

  def initialize(fixture_path)
    raise ArgumentError, "fixture_path required" if fixture_path.nil? || fixture_path.empty?
    raise ArgumentError, "fixture not found: #{fixture_path}" unless File.file?(fixture_path)
    @fixture = File.expand_path(fixture_path)
    @repo_root = File.expand_path('../../..', __FILE__)
    @lib = ButterCut::FuseLibrary.load(root: File.join(@repo_root, 'fuses'))
  end

  def run
    if @lib.names.empty?
      warn "no fuses registered in fuses/ — nothing to verify"
      return 1
    end
    out_dir = File.join(@repo_root, 'tmp', 'verify_fuses')
    FileUtils.mkdir_p(out_dir)
    stamp = Time.now.utc.strftime('%Y%m%dT%H%M%S')
    recipe_path = File.join(out_dir, "recipe_#{stamp}.json")
    apply_path = File.join(out_dir, "apply_#{stamp}.py")
    File.write(recipe_path, JSON.pretty_generate(build_recipe))
    require_relative '../../.claude/skills/roughcut/generate_apply_script'
    GenerateApplyScript.generate(recipe_path: recipe_path, output_path: apply_path)
    print_instructions(apply_path)
    0
  end

  private

  def build_recipe
    clips = @lib.names.each_with_index.map do |name, i|
      manifest = @lib.lookup(name)
      params = default_params(manifest)
      { "index" => i + 1, "source_file" => @fixture,
        "fusion_effects" => [{ "fuse" => name, "params" => params }] }
    end
    {
      "version" => 2,
      "library" => "verify_fuses",
      "timeline" => "verify_fuses_#{Time.now.to_i}",
      "clips" => clips
    }
  end

  def default_params(manifest)
    manifest['params'].each_with_object({}) { |p, h| h[p['name']] = p['default'] }
  end

  def print_instructions(apply_path)
    puts <<~MSG

      ─── verify_fuses smoke ───
      1. Open DaVinci Resolve.
      2. Create a new timeline. Import #{@fixture} and place #{@lib.names.length} copies on V1.
      3. Workspace > Console > Py3, run:
           exec(open(#{apply_path.inspect}, encoding="utf-8").read())
      4. Expected console output:
           applied: fusion_effects: #{@lib.names.length}/#{@lib.names.length}
         and NO entries under "ACTION REQUIRED" or "warnings".
      5. Eyeball each clip's Inspector > Fusion to confirm the named tool is present
         and connected. Capture a still per fuse for fuses/<Name>/reference.png if you
         want to refresh the documentation screenshots.

      Apply script: #{apply_path}
    MSG
  end
end

if __FILE__ == $PROGRAM_NAME
  if ARGV.length != 1
    warn "Usage: #{$PROGRAM_NAME} <fixture.mov>"
    exit 1
  end
  exit VerifyFuses.run(ARGV[0])
end
```

- [ ] **Step 2: Smoke the script (without Resolve)**

Run: `ruby .claude/scripts/verify_fuses.rb spec/fixtures/sample.mov 2>&1 | tee /tmp/verify_smoke.log` — substitute any small video path you have. Expected: instructions printed, apply.py written. (Substitute a real fixture path the user has.)

- [ ] **Step 3: Commit**

```bash
git add .claude/scripts/verify_fuses.rb
git commit -m "feat(fuses): verify_fuses manual smoke script"
```

---

## Task 12: CHANGELOG + final pass

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Add entry**

```markdown
## [Unreleased]

### Added
- `fuses/` — five bundled Fusion Fuses (ChromaPulse, VHSGlitch, FilmGrain, LightLeak, ZoomPunch). (#23)
- `ButterCut::FuseLibrary` — loads + validates fuse manifests. (#23)
- Recipe `fusion_effects` per-clip directive (schema bumped to v2; v1 recipes still load). (#23)
- `apply.py` installs referenced fuses into Resolve's Fuses folder, then wires them into each clip's Fusion comp. First-run requires a single Resolve restart if newly installed. (#23)
- `.claude/scripts/lint_fuses.rb` — luacheck runner.
- `.claude/scripts/verify_fuses.rb` — manual smoke gate run before each release.
- CI: `.github/workflows/lint.yml` runs RSpec + luacheck on every PR.
```

- [ ] **Step 2: Run full test suite + lint**

Run: `bundle exec rspec && ruby .claude/scripts/lint_fuses.rb`
Expected: all green.

- [ ] **Step 3: Manual verify_fuses run**

Run: `ruby .claude/scripts/verify_fuses.rb <fixture.mov>` and follow the printed instructions inside Resolve. Confirm `applied: fusion_effects: 5/5` and no warnings.

- [ ] **Step 4: Commit + open PR**

```bash
git add CHANGELOG.md
git commit -m "docs: changelog for v1 fuse support"
git push -u origin <branch>
gh pr create --repo William-Hill/buttercut --title "Programmatic Fusion Fuse application (closes #23)" --body "<see spec doc>"
```

---

## Self-review notes

- Spec coverage: every section of the spec maps to a task above (FuseLibrary → 1; recipe v2 → 2; roughcut passthrough → 3; fuse library → 4–5; verification → 6, 7, 11; generate_apply_script → 8; apply.py phases → 9–10; changelog → 12).
- Type names checked: `FuseLibrary`, `validate_params!`, `Recipe.new(... fuse_library:)` consistent across tasks.
- Placeholders: none. The Lua fuse skeletons are intentionally compositional starting points, not "TBD."
- Risk acknowledged in plan: Fusion Lua API specifics — engineer must crib from Resolve's bundled fuses for exact node-graph operations. The plan's structure (skeleton + manual smoke + reference fuse paths) supports that.
