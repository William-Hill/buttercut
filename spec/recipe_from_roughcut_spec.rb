require 'spec_helper'
require 'tmpdir'
require 'yaml'
require 'json'

require_relative '../.claude/skills/roughcut/recipe_from_roughcut'

RSpec.describe RecipeFromRoughcut do
  def write_yaml(dir, name, hash)
    path = File.join(dir, name)
    File.write(path, YAML.dump(hash))
    path
  end

  let(:full_roughcut) do
    {
      "description" => "highlight reel",
      "clips" => [
        { "source_file" => "opener.mp4", "in_point" => "00:00:00.00", "out_point" => "00:00:02.50" },
        { "source_file" => "energy_a_1.mp4", "in_point" => "00:00:00.00", "out_point" => "00:00:02.50" },
        {
          "source_file" => "medicine-ball-slams.mp4",
          "in_point" => "00:00:01.50",
          "out_point" => "00:00:04.00",
          "speed_ramps" => [
            { "at" => 0.0, "speed" => 200, "ease" => "ease-out" },
            { "at" => 1.0, "speed" => 100, "ease" => "ease-in" }
          ],
          "color_tag" => "Orange",
          "markers" => [{ "at" => 0.3, "name" => "impact", "color" => "Red" }]
        },
        { "source_file" => "hero.mp4", "in_point" => "00:00:00.00", "out_point" => "00:00:03.00" }
      ],
      "transitions" => [
        { "between" => [3, 4], "type" => "dip_to_color", "color" => "white", "duration_frames" => 4 }
      ],
      "title_card" => {
        "at_clip" => 4, "text" => "{{user_handle}}", "fade_in_at" => 0.5, "fade_in_frames" => 6
      },
      "render_preset" => {
        "format" => "mp4", "codec" => "h264", "resolution" => "1080p", "bitrate_kbps" => 25000
      },
      "powergrade" => { "name" => "GymBlueOrange-v1", "apply_to" => "all" }
    }
  end

  it 'builds a valid Recipe from a directive-rich rough cut YAML' do
    Dir.mktmpdir do |dir|
      yaml_path = write_yaml(dir, "highlight-reel.yaml", full_roughcut)
      recipe_path = File.join(dir, "highlight-reel.recipe.json")

      described_class.export(
        roughcut_path: yaml_path,
        recipe_path: recipe_path,
        library_name: "march-30-workout",
        timeline_name: "highlight-reel_20260430_184655"
      )

      h = JSON.parse(File.read(recipe_path))
      expect(h["version"]).to eq(1)
      expect(h["library"]).to eq("march-30-workout")
      expect(h["timeline"]).to eq("highlight-reel_20260430_184655")
      expect(h["clips"].map { |c| c["index"] }).to eq([1, 2, 3, 4])
      expect(h["clips"][2]["speed_ramps"].first).to eq({ "at" => 0.0, "speed" => 200, "ease" => "ease-out" })
      expect(h["clips"][2]["color_tag"]).to eq("Orange")
      expect(h["clips"][2]["markers"]).to eq([{ "at" => 0.3, "name" => "impact", "color" => "Red" }])
      expect(h["transitions"]).to eq([{ "between" => [3, 4], "type" => "dip_to_color", "color" => "white", "duration_frames" => 4 }])
      expect(h["title_card"]["at_clip"]).to eq(4)
      expect(h["render_preset"]["bitrate_kbps"]).to eq(25000)
      expect(h["powergrade"]).to eq({ "name" => "GymBlueOrange-v1", "apply_to" => "all" })
    end
  end

  it 'produces a minimal-but-valid recipe when the rough cut has no directives' do
    minimal = {
      "clips" => [
        { "source_file" => "a.mp4", "in_point" => "00:00:00.00", "out_point" => "00:00:01.00" },
        { "source_file" => "b.mp4", "in_point" => "00:00:00.00", "out_point" => "00:00:01.00" }
      ]
    }

    Dir.mktmpdir do |dir|
      yaml_path = write_yaml(dir, "cut.yaml", minimal)
      recipe_path = File.join(dir, "cut.recipe.json")

      described_class.export(
        roughcut_path: yaml_path,
        recipe_path: recipe_path,
        library_name: "lib",
        timeline_name: "t"
      )

      h = JSON.parse(File.read(recipe_path))
      expect(h.keys).to contain_exactly("version", "library", "timeline", "clips")
      expect(h["clips"]).to eq([
        { "index" => 1, "source_file" => "a.mp4" },
        { "index" => 2, "source_file" => "b.mp4" }
      ])
    end
  end

  it 'requires roughcut_path, recipe_path, library_name, and timeline_name' do
    expect {
      described_class.new(roughcut_path: "", recipe_path: "x", library_name: "y", timeline_name: "z")
    }.to raise_error(ArgumentError, /roughcut_path/)
    expect {
      described_class.new(roughcut_path: "x", recipe_path: nil, library_name: "y", timeline_name: "z")
    }.to raise_error(ArgumentError, /recipe_path/)
    expect {
      described_class.new(roughcut_path: "x", recipe_path: "y", library_name: "", timeline_name: "z")
    }.to raise_error(ArgumentError, /library_name/)
    expect {
      described_class.new(roughcut_path: "x", recipe_path: "y", library_name: "z", timeline_name: nil)
    }.to raise_error(ArgumentError, /timeline_name/)
  end

  it 'raises if the rough cut has no clips' do
    Dir.mktmpdir do |dir|
      yaml_path = write_yaml(dir, "empty.yaml", { "clips" => [] })
      recipe_path = File.join(dir, "empty.recipe.json")
      expect {
        described_class.export(
          roughcut_path: yaml_path, recipe_path: recipe_path,
          library_name: "l", timeline_name: "t"
        )
      }.to raise_error(ArgumentError, /clips/)
    end
  end

  it 'propagates Recipe validation errors (e.g. invalid color_tag)' do
    bad = {
      "clips" => [{ "source_file" => "a.mp4", "color_tag" => "Mauve" }]
    }
    Dir.mktmpdir do |dir|
      yaml_path = write_yaml(dir, "bad.yaml", bad)
      expect {
        described_class.export(
          roughcut_path: yaml_path,
          recipe_path: File.join(dir, "bad.recipe.json"),
          library_name: "l", timeline_name: "t"
        )
      }.to raise_error(ArgumentError, /color_tag/)
    end
  end
end
