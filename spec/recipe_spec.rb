require 'spec_helper'
require 'json'
require 'tmpdir'
require 'fileutils'
require 'buttercut/fuse_library'

RSpec.describe ButterCut::Recipe do
  let(:valid_hash) do
    {
      "version" => 1,
      "library" => "march-30-workout",
      "timeline" => "highlight-reel_20260430_184655",
      "render_preset" => {
        "format" => "mp4",
        "codec" => "h264",
        "resolution" => "1080p",
        "bitrate_kbps" => 25000
      },
      "powergrade" => { "name" => "GymBlueOrange-v1", "apply_to" => "all" },
      "clips" => [
        {
          "index" => 3,
          "source_file" => "medicine-ball-slams.mp4",
          "speed_ramps" => [
            { "at" => 1.5, "speed" => 200, "ease" => "ease-out" },
            { "at" => 2.5, "speed" => 100, "ease" => "ease-in" }
          ],
          "color_tag" => "Orange",
          "markers" => [{ "at" => 1.8, "name" => "impact", "color" => "Red" }]
        },
        { "index" => 4, "source_file" => "rest.mp4" },
        { "index" => 11, "source_file" => "jump-rope.mp4" },
        { "index" => 12, "source_file" => "hero-closer.mp4" }
      ],
      "transitions" => [
        { "between" => [3, 4], "type" => "dip_to_color", "color" => "black", "duration_frames" => 4 },
        { "between" => [11, 12], "type" => "dip_to_color", "color" => "white", "duration_frames" => 4 }
      ],
      "title_card" => {
        "at_clip" => 12,
        "text" => "{{user_handle}}",
        "fade_in_at" => 0.5,
        "fade_in_frames" => 6
      }
    }
  end

  describe '.from_hash' do
    it 'round-trips a canonical recipe without loss' do
      recipe = described_class.from_hash(valid_hash)
      expect(recipe.to_h).to eq(valid_hash)
    end

    it 'round-trips through JSON file save/load' do
      recipe = described_class.from_hash(valid_hash)
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'recipe.json')
        recipe.save(path)
        loaded = described_class.load(path)
        expect(loaded.to_h).to eq(valid_hash)
        expect(JSON.parse(File.read(path))).to eq(valid_hash)
      end
    end

    it 'accepts a minimal recipe (no optional fields)' do
      minimal = {
        "version" => 1,
        "library" => "lib",
        "timeline" => "t",
        "clips" => [{ "index" => 1, "source_file" => "a.mp4" }]
      }
      expect(described_class.from_hash(minimal).to_h).to eq(minimal)
    end
  end

  describe 'version validation' do
    it 'rejects an unknown version' do
      expect {
        described_class.from_hash(valid_hash.merge("version" => 3))
      }.to raise_error(ArgumentError, /version/)
    end

    it 'rejects a missing version' do
      expect {
        described_class.from_hash(valid_hash.reject { |k, _| k == "version" })
      }.to raise_error(ArgumentError, /version/)
    end
  end

  describe 'top-level validation' do
    it 'rejects a missing library' do
      expect {
        described_class.from_hash(valid_hash.merge("library" => ""))
      }.to raise_error(ArgumentError, /library/)
    end

    it 'rejects a missing timeline' do
      expect {
        described_class.from_hash(valid_hash.merge("timeline" => nil))
      }.to raise_error(ArgumentError, /timeline/)
    end

    it 'rejects empty clips' do
      expect {
        described_class.from_hash(valid_hash.merge("clips" => []))
      }.to raise_error(ArgumentError, /clips/)
    end
  end

  describe 'clip validation' do
    it 'rejects a clip without an index' do
      bad = valid_hash.dup
      bad["clips"] = [{ "source_file" => "x.mp4" }]
      expect { described_class.from_hash(bad) }.to raise_error(ArgumentError, /index/)
    end

    it 'rejects a clip with a non-positive index' do
      bad = valid_hash.dup
      bad["clips"] = [{ "index" => 0, "source_file" => "x.mp4" }]
      expect { described_class.from_hash(bad) }.to raise_error(ArgumentError, /index/)
    end

    it 'rejects a clip with empty source_file' do
      bad = valid_hash.dup
      bad["clips"] = [{ "index" => 1, "source_file" => "" }]
      expect { described_class.from_hash(bad) }.to raise_error(ArgumentError, /source_file/)
    end

    it 'rejects an unknown color_tag' do
      bad = valid_hash.dup
      bad["clips"] = [{ "index" => 1, "source_file" => "x.mp4", "color_tag" => "Mauve" }]
      bad["transitions"] = []
      bad.delete("title_card")
      expect { described_class.from_hash(bad) }.to raise_error(ArgumentError, /color_tag/)
    end
  end

  describe 'duplicate clip indices' do
    it 'rejects clips with duplicate index values' do
      bad = valid_hash.dup
      bad["clips"] = [
        { "index" => 1, "source_file" => "a.mp4" },
        { "index" => 1, "source_file" => "b.mp4" }
      ]
      bad["transitions"] = []
      bad.delete("title_card")
      expect { described_class.from_hash(bad) }.to raise_error(ArgumentError, /duplicate/i)
    end
  end

  describe 'array-typed fields on clips' do
    it 'rejects non-array speed_ramps' do
      bad = valid_hash.dup
      bad["clips"] = [{ "index" => 1, "source_file" => "x.mp4", "speed_ramps" => "fast" }]
      bad["transitions"] = []
      bad.delete("title_card")
      expect { described_class.from_hash(bad) }.to raise_error(ArgumentError, /speed_ramps.*array/)
    end

    it 'rejects null speed_ramps' do
      bad = valid_hash.dup
      bad["clips"] = [{ "index" => 1, "source_file" => "x.mp4", "speed_ramps" => nil }]
      bad["transitions"] = []
      bad.delete("title_card")
      expect { described_class.from_hash(bad) }.to raise_error(ArgumentError, /speed_ramps.*array/)
    end

    it 'rejects null markers' do
      bad = valid_hash.dup
      bad["clips"] = [{ "index" => 1, "source_file" => "x.mp4", "markers" => nil }]
      bad["transitions"] = []
      bad.delete("title_card")
      expect { described_class.from_hash(bad) }.to raise_error(ArgumentError, /markers.*array/)
    end

    it 'rejects non-array markers' do
      bad = valid_hash.dup
      bad["clips"] = [{ "index" => 1, "source_file" => "x.mp4", "markers" => 1 }]
      bad["transitions"] = []
      bad.delete("title_card")
      expect { described_class.from_hash(bad) }.to raise_error(ArgumentError, /markers.*array/)
    end
  end

  describe 'speed_ramp validation' do
    it 'rejects speed of 0' do
      bad = valid_hash.dup
      bad["clips"] = [{
        "index" => 1, "source_file" => "x.mp4",
        "speed_ramps" => [{ "at" => 0.0, "speed" => 0, "ease" => "linear" }]
      }]
      bad["transitions"] = []
      bad.delete("title_card")
      expect { described_class.from_hash(bad) }.to raise_error(ArgumentError, /speed/)
    end

    it 'rejects negative at' do
      bad = valid_hash.dup
      bad["clips"] = [{
        "index" => 1, "source_file" => "x.mp4",
        "speed_ramps" => [{ "at" => -0.1, "speed" => 100, "ease" => "linear" }]
      }]
      bad["transitions"] = []
      bad.delete("title_card")
      expect { described_class.from_hash(bad) }.to raise_error(ArgumentError, /at/)
    end

    it 'rejects unknown ease' do
      bad = valid_hash.dup
      bad["clips"] = [{
        "index" => 1, "source_file" => "x.mp4",
        "speed_ramps" => [{ "at" => 0.0, "speed" => 100, "ease" => "bouncy" }]
      }]
      bad["transitions"] = []
      bad.delete("title_card")
      expect { described_class.from_hash(bad) }.to raise_error(ArgumentError, /ease/)
    end
  end

  describe 'marker validation' do
    it 'rejects an unknown marker color' do
      bad = valid_hash.dup
      bad["clips"] = [{
        "index" => 1, "source_file" => "x.mp4",
        "markers" => [{ "at" => 0.0, "name" => "x", "color" => "Chartreuse" }]
      }]
      bad["transitions"] = []
      bad.delete("title_card")
      expect { described_class.from_hash(bad) }.to raise_error(ArgumentError, /marker.*color/i)
    end

    it 'rejects an empty marker name' do
      bad = valid_hash.dup
      bad["clips"] = [{
        "index" => 1, "source_file" => "x.mp4",
        "markers" => [{ "at" => 0.0, "name" => "", "color" => "Red" }]
      }]
      bad["transitions"] = []
      bad.delete("title_card")
      expect { described_class.from_hash(bad) }.to raise_error(ArgumentError, /marker.*name/i)
    end
  end

  describe 'transition validation' do
    it 'rejects between referencing a clip that does not exist' do
      bad = valid_hash.dup
      bad["transitions"] = [
        { "between" => [3, 4], "type" => "dip_to_color", "color" => "black", "duration_frames" => 4 },
        { "between" => [99, 100], "type" => "dip_to_color", "color" => "black", "duration_frames" => 4 }
      ]
      expect { described_class.from_hash(bad) }.to raise_error(ArgumentError, /transition.*99/)
    end

    it 'rejects non-adjacent between' do
      bad = valid_hash.dup
      bad["transitions"] = [
        { "between" => [3, 11], "type" => "dip_to_color", "color" => "black", "duration_frames" => 4 }
      ]
      bad.delete("title_card")
      expect { described_class.from_hash(bad) }.to raise_error(ArgumentError, /adjacent/i)
    end

    it 'rejects non-positive duration_frames' do
      bad = valid_hash.dup
      bad["transitions"] = [
        { "between" => [3, 4], "type" => "dip_to_color", "color" => "black", "duration_frames" => 0 }
      ]
      bad.delete("title_card")
      expect { described_class.from_hash(bad) }.to raise_error(ArgumentError, /duration_frames/)
    end

    it 'rejects unknown transition type' do
      bad = valid_hash.dup
      bad["transitions"] = [
        { "between" => [3, 4], "type" => "wipe", "duration_frames" => 4 }
      ]
      bad.delete("title_card")
      expect { described_class.from_hash(bad) }.to raise_error(ArgumentError, /transition.*type/i)
    end

    it 'rejects unknown dip color' do
      bad = valid_hash.dup
      bad["transitions"] = [
        { "between" => [3, 4], "type" => "dip_to_color", "color" => "purple", "duration_frames" => 4 }
      ]
      bad.delete("title_card")
      expect { described_class.from_hash(bad) }.to raise_error(ArgumentError, /dip.*color/i)
    end
  end

  describe 'title_card validation' do
    it 'rejects at_clip referencing a missing clip index' do
      bad = valid_hash.dup
      bad["title_card"] = bad["title_card"].merge("at_clip" => 999)
      expect { described_class.from_hash(bad) }.to raise_error(ArgumentError, /title_card.*999/)
    end

    it 'rejects non-positive fade_in_frames' do
      bad = valid_hash.dup
      bad["title_card"] = bad["title_card"].merge("fade_in_frames" => 0)
      expect { described_class.from_hash(bad) }.to raise_error(ArgumentError, /fade_in_frames/)
    end
  end

  describe 'render_preset validation' do
    it 'rejects non-positive bitrate_kbps' do
      bad = valid_hash.dup
      bad["render_preset"] = bad["render_preset"].merge("bitrate_kbps" => 0)
      expect { described_class.from_hash(bad) }.to raise_error(ArgumentError, /bitrate_kbps/)
    end

    it 'rejects empty codec' do
      bad = valid_hash.dup
      bad["render_preset"] = bad["render_preset"].merge("codec" => "")
      expect { described_class.from_hash(bad) }.to raise_error(ArgumentError, /codec/)
    end
  end

  describe 'powergrade validation' do
    it 'accepts apply_to with explicit clip indices' do
      good = valid_hash.dup
      good["powergrade"] = { "name" => "X", "apply_to" => [3, 4] }
      expect(described_class.from_hash(good).to_h["powergrade"]["apply_to"]).to eq([3, 4])
    end

    it 'rejects apply_to referencing a missing clip' do
      bad = valid_hash.dup
      bad["powergrade"] = { "name" => "X", "apply_to" => [3, 999] }
      expect { described_class.from_hash(bad) }.to raise_error(ArgumentError, /powergrade.*999/)
    end

    it 'rejects unknown apply_to string' do
      bad = valid_hash.dup
      bad["powergrade"] = { "name" => "X", "apply_to" => "some" }
      expect { described_class.from_hash(bad) }.to raise_error(ArgumentError, /apply_to/)
    end
  end

  describe 'schema v2 fusion_effects' do
    let(:base_clip) { { "index" => 1, "source_file" => "a.mov" } }

    let(:test_manifest) do
      {
        "name" => "ChromaPulse", "version" => "1.0.0", "description" => "x",
        "params" => [{ "name" => "intensity", "type" => "number", "default" => 0.4, "range" => [0.0, 1.0] }]
      }
    end

    def fuse_lib_with(manifest)
      Dir.mktmpdir do |root|
        dir = File.join(root, manifest['name'])
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, 'manifest.json'), JSON.pretty_generate(manifest))
        File.write(File.join(dir, "#{manifest['name']}.fuse"), "-- stub")
        yield ButterCut::FuseLibrary.load(root: root)
      end
    end

    it 'accepts a v2 recipe with absent fusion_effects' do
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
  end

  describe 'schema v1 backward compat' do
    it 'still loads v1 recipes' do
      r = described_class.new(version: 1, library: 'L', timeline: 'T',
                              clips: [{ "index" => 1, "source_file" => "a.mov" }])
      expect(r.to_h['version']).to eq(1)
    end
  end
end
