#!/usr/bin/env ruby
# Build a ButterCut::Recipe (and its JSON file) from a rough-cut YAML.
#
# The YAML is the source of truth: clips are numbered 1..N by YAML order,
# and editorial directives (speed_ramps, color_tag, markers, transitions,
# title_card, render_preset, powergrade) are read off the same document.

require 'date'
require 'yaml'
require 'buttercut'

class RecipeFromRoughcut
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

  def export
    recipe = build_recipe
    recipe.save(@recipe_path)
    @recipe_path
  end

  def build_recipe
    ButterCut::Recipe.from_hash(build_hash)
  end

  private

  def roughcut
    @roughcut ||= YAML.load_file(@roughcut_path, permitted_classes: [Date, Time, Symbol])
  end

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

  def build_clips
    raw_clips = roughcut["clips"]
    raise ArgumentError, "roughcut must have a clips array" unless raw_clips.is_a?(Array) && !raw_clips.empty?

    raw_clips.each_with_index.map do |clip, i|
      entry = {
        "index" => i + 1,
        "source_file" => clip["source_file"]
      }
      entry["speed_ramps"] = stringify(clip["speed_ramps"]) if clip.key?("speed_ramps")
      entry["color_tag"] = clip["color_tag"] if clip.key?("color_tag")
      entry["markers"] = stringify(clip["markers"]) if clip.key?("markers")
      entry["fusion_effects"] = stringify(clip["fusion_effects"]) if clip.key?("fusion_effects")
      entry
    end
  end

  # YAML round-trips with string keys by default, but nested hashes loaded from
  # YAML may have symbol keys depending on author style. Normalize to strings so
  # the output JSON matches the Recipe schema exactly.
  def stringify(obj)
    case obj
    when Hash
      obj.each_with_object({}) { |(k, v), h| h[k.to_s] = stringify(v) }
    when Array
      obj.map { |v| stringify(v) }
    else
      obj
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  if ARGV.length != 2
    warn "Usage: #{$PROGRAM_NAME} <roughcut.yaml> <output.recipe.json>"
    exit 1
  end

  roughcut_path = ARGV[0]
  recipe_path = ARGV[1]

  unless File.exist?(roughcut_path)
    warn "Error: Rough cut file not found: #{roughcut_path}"
    exit 1
  end

  library_match = roughcut_path.match(%r{libraries/([^/]+)/roughcuts})
  unless library_match
    warn "Error: Could not extract library name from path: #{roughcut_path}"
    exit 1
  end
  library_name = library_match[1]
  timeline_name = File.basename(roughcut_path, File.extname(roughcut_path))

  RecipeFromRoughcut.export(
    roughcut_path: roughcut_path,
    recipe_path: recipe_path,
    library_name: library_name,
    timeline_name: timeline_name
  )
  puts "✓ Recipe exported to: #{recipe_path}"
end
