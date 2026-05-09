#!/usr/bin/env ruby
# Export rough cut YAML to editor XML using ButterCut.

require 'date'
require 'fileutils'
require 'pathname'
require 'yaml'
require 'buttercut'
require_relative 'recipe_from_roughcut'
require_relative 'generate_apply_script'

class RoughcutExporter
  def self.export(roughcut_path:, output_path:, editor: 'fcpx', skip_render: false)
    new(roughcut_path: roughcut_path, output_path: output_path, editor: editor, skip_render: skip_render).export
  end

  def initialize(roughcut_path:, output_path:, editor: 'fcpx', skip_render: false)
    raise ArgumentError, "roughcut_path required" if roughcut_path.nil? || roughcut_path.empty?
    raise ArgumentError, "output_path required" if output_path.nil? || output_path.empty?
    @roughcut_path = roughcut_path
    @output_path = output_path
    @editor_choice = editor
    @skip_render = skip_render || ENV['BUTTERCUT_SKIP_BROLL_RENDER'] == '1'
  end

  def export
    raise "Rough cut file not found: #{@roughcut_path}" unless File.exist?(@roughcut_path)

    roughcut = YAML.load_file(@roughcut_path, permitted_classes: [Date, Time, Symbol])
    library_name = library_name_from_path(@roughcut_path)
    library_yaml_path = "libraries/#{library_name}/library.yaml"
    raise "Library file not found: #{library_yaml_path}" unless File.exist?(library_yaml_path)

    library_data = YAML.load_file(library_yaml_path, permitted_classes: [Date, Time, Symbol])
    video_paths = library_data['videos'].each_with_object({}) { |v, h| h[File.basename(v['path'])] = v['path'] }
    @library_name = library_name
    @library_data = library_data

    render_unrendered_entries! unless @skip_render

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
      unless video_paths[source_file]
        raise "Source file not found in library: #{source_file}. Refusing to export — silently skipping a clip would break recipe.json clip indices."
      end
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

  # Late-render: any manifest entry whose `rendered` is empty OR whose
  # rendered MP4 is missing on disk gets rendered now via Hyperframes,
  # and the manifest is updated in-place. This is the "render at export
  # time" half of issue #34. The other half (swap-in-place) is handled
  # by BrollRenderer's idempotent overwrite of the same MP4 path.
  def render_unrendered_entries!
    return if manifest.nil?

    needs_render = manifest.entries.select { |e| entry_needs_render?(e) }
    return if needs_render.empty?

    output_dir = File.join(library_root, 'broll')
    FileUtils.mkdir_p(output_dir)
    theme = @library_data['theme'] || {}

    puts "Rendering #{needs_render.length} b-roll entr#{needs_render.length == 1 ? 'y' : 'ies'} via Hyperframes..."
    needs_render.each_with_index do |entry, i|
      print "  [#{i + 1}/#{needs_render.length}] #{entry['id']} (#{entry['template']})... "
      mp4_path = ButterCut::BrollRenderer.render(
        entry: entry,
        theme: theme,
        output_dir: output_dir,
        hyperframes_dir: hyperframes_dir
      )
      entry['rendered'] = relative_to_library(mp4_path)
      manifest.save(broll_yaml_path)
      puts "✓ #{entry['rendered']}"
    end
  end

  def entry_needs_render?(entry)
    rendered = entry['rendered']
    return true if rendered.nil? || rendered.to_s.empty?
    !File.exist?(absolute_rendered_path(rendered))
  end

  def library_root
    File.dirname(File.dirname(@roughcut_path))
  end

  def relative_to_library(path)
    Pathname.new(File.expand_path(path)).relative_path_from(Pathname.new(File.expand_path(library_root))).to_s
  end

  def hyperframes_dir
    @hyperframes_dir ||= File.expand_path('../../../hyperframes', __dir__)
  end

  def manifest
    return @manifest if defined?(@manifest)
    @manifest = File.exist?(broll_yaml_path) ? ButterCut::BrollManifest.load(broll_yaml_path) : nil
  end

  def valid_entries
    return @valid_entries if defined?(@valid_entries)
    @valid_entries = (manifest&.entries || []).filter_map do |entry|
      if entry['rendered'].nil? || entry['rendered'].to_s.empty?
        warn "[export] skipping #{entry['id']}: rendered is empty"
        next nil
      end
      rendered_path = absolute_rendered_path(entry['rendered'])
      unless File.exist?(rendered_path)
        warn "[export] skipping #{entry['id']}: rendered file not found at #{rendered_path}"
        next nil
      end
      entry.merge('_resolved_path' => rendered_path)
    end
  end

  def load_overlays
    valid_entries.map do |entry|
      {
        source: entry['_resolved_path'],
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
    # Resolve relative to the library root (parent of roughcuts/).
    File.expand_path(rendered, File.dirname(File.dirname(@roughcut_path)))
  end

  def broll_entries_for_recipe
    return nil if manifest.nil?
    valid_entries.map do |entry|
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
    # Tests can opt out by setting BUTTERCUT_SKIP_DTD=1.
    if ENV['BUTTERCUT_SKIP_DTD'] == '1'
      puts "⚠ Skipping FCPXML DTD validation (BUTTERCUT_SKIP_DTD=1)."
      return
    end

    dtd_v110 = File.expand_path('../../../dtd/FCPXMLv1_10.dtd', __dir__)
    dtd_v18  = File.expand_path('../../../dtd/FCPXMLv1_8.dtd', __dir__)
    dtd_path, dtd_label =
      if File.exist?(dtd_v110)
        [dtd_v110, "FCPXMLv1_10.dtd"]
      elsif File.exist?(dtd_v18)
        [dtd_v18, "FCPXMLv1_8.dtd (best-effort fallback for 1.10 output)"]
      end

    unless dtd_path
      puts "⚠ No FCPXML DTD found in dtd/; skipping validation."
      return
    end

    unless system('command -v xmllint > /dev/null 2>&1')
      puts "⚠ xmllint not found; skipping validation."
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
  args = ARGV.reject { |a| a == '--no-render' }
  skip_render = ARGV.include?('--no-render')
  if args.length < 2 || args.length > 3
    puts "Usage: #{$PROGRAM_NAME} <roughcut.yaml> <output.xml> [editor] [--no-render]"
    puts "  editor: fcpx (default), premiere, or resolve"
    puts "  --no-render: skip the Hyperframes b-roll late-render pass"
    exit 1
  end
  begin
    RoughcutExporter.export(
      roughcut_path: args[0],
      output_path: args[1],
      editor: args[2] || 'fcpx',
      skip_render: skip_render
    )
  rescue => e
    warn "Error: #{e.message}"
    exit 1
  end
end
