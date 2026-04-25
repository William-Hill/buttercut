#!/usr/bin/env ruby
# frozen_string_literal: true

# Single-pass ffmpeg render so audio and video share one filter_complex
# timeline — a two-stage extract+concat-demuxer pipeline drifts A/V across
# clip boundaries because of AAC priming and stream-duration mismatches.

require 'fileutils'
require 'shellwords'
require 'tmpdir'
require 'yaml'

class RoughcutVideoExporter
  def self.export(roughcut_path:, output_path: nil)
    new(roughcut_path: roughcut_path, output_path: output_path).export
  end

  def initialize(roughcut_path:, output_path: nil)
    raise ArgumentError, 'roughcut_path is required' if roughcut_path.nil? || roughcut_path.empty?
    raise ArgumentError, "Roughcut not found: #{roughcut_path}" unless File.exist?(roughcut_path)

    @roughcut_path = roughcut_path
    @output_path = output_path || default_output_path
  end

  def export
    load_roughcut
    load_library
    build_input_index
    detect_target_specs
    detect_input_audio
    render
    report
    @output_path
  end

  private

  def load_roughcut
    @roughcut = YAML.load_file(@roughcut_path, permitted_classes: [Date, Time, Symbol])
    raise "Roughcut has no clips: #{@roughcut_path}" if @roughcut['clips'].nil? || @roughcut['clips'].empty?
  end

  def load_library
    library_yaml = "libraries/#{library_name}/library.yaml"
    raise "Library not found: #{library_yaml}" unless File.exist?(library_yaml)

    library_data = YAML.load_file(library_yaml, permitted_classes: [Date, Time, Symbol])
    @video_paths = library_data['videos'].each_with_object({}) do |video, h|
      h[File.basename(video['path'])] = video['path']
    end
  end

  def library_name
    @library_name ||= begin
      match = @roughcut_path.match(%r{libraries/([^/]+)/roughcuts})
      raise "Could not extract library name from path: #{@roughcut_path}" unless match

      match[1]
    end
  end

  def build_input_index
    @unique_sources = []
    @input_index = {}
    @roughcut['clips'].each do |clip|
      src = source_path_for(clip)
      next if @input_index.key?(src)

      @input_index[src] = @unique_sources.size
      @unique_sources << src
    end
  end

  def detect_target_specs
    first = source_path_for(@roughcut['clips'].first)
    probe = `ffprobe -v error -select_streams v:0 -show_entries stream=width,height,r_frame_rate -of csv=s=,:p=0 #{Shellwords.escape(first)}`.strip
    raise "ffprobe failed for #{first}" if probe.empty?

    width, height, fps = probe.split(',')
    num, den = fps.split('/')
    @target_width = width.to_i
    @target_height = height.to_i
    @target_fps = (num.to_f / den.to_f).round
    puts "Target: #{@target_width}x#{@target_height} @ #{@target_fps}fps"
  end

  def detect_input_audio
    @has_audio = {}
    @unique_sources.each do |src|
      result = `ffprobe -v error -select_streams a:0 -show_entries stream=codec_type -of csv=p=0 #{Shellwords.escape(src)}`.strip
      @has_audio[src] = (result == 'audio')
    end
  end

  def render
    FileUtils.mkdir_p(File.dirname(@output_path))
    filter_script = write_filter_script

    cmd = ['ffmpeg', '-y', '-loglevel', 'error', '-stats']
    @unique_sources.each { |s| cmd << '-i' << s }
    cmd += [
      '-filter_complex_script', filter_script,
      '-map', '[v]', '-map', '[a]',
      '-c:v', 'libx264', '-preset', 'ultrafast', '-crf', '23',
      '-c:a', 'aac', '-b:a', '128k', '-ar', '48000', '-ac', '2',
      '-movflags', '+faststart',
      '-write_tmcd', '0', '-map_metadata', '-1',
      @output_path
    ]

    puts "Rendering #{@roughcut['clips'].size} clips from #{@unique_sources.size} sources..."
    run_ffmpeg(cmd)
  ensure
    File.delete(filter_script) if filter_script && File.exist?(filter_script)
  end

  def write_filter_script
    script = build_filter_complex
    path = File.join(Dir.tmpdir, "export_video_#{Process.pid}_#{Time.now.to_i}.filter")
    File.write(path, script)
    path
  end

  def build_filter_complex
    parts = []
    concat_inputs = []
    vf = "scale=#{@target_width}:#{@target_height}:force_original_aspect_ratio=decrease," \
         "pad=#{@target_width}:#{@target_height}:(ow-iw)/2:(oh-ih)/2,setsar=1," \
         "fps=#{@target_fps}"

    @roughcut['clips'].each_with_index do |clip, i|
      src = source_path_for(clip)
      idx = @input_index[src]
      in_pt = timecode_to_seconds(clip['in_point'])
      out_pt = timecode_to_seconds(clip['out_point'])

      parts << "[#{idx}:v]trim=start=#{in_pt}:end=#{out_pt},setpts=PTS-STARTPTS,#{vf}[v#{i}]"
      parts << if @has_audio[src]
                 "[#{idx}:a]atrim=start=#{in_pt}:end=#{out_pt},asetpts=PTS-STARTPTS," \
                 "aformat=sample_rates=48000:channel_layouts=stereo[a#{i}]"
               else
                 "anullsrc=sample_rate=48000:channel_layout=stereo,atrim=duration=#{out_pt - in_pt},asetpts=PTS-STARTPTS[a#{i}]"
               end
      concat_inputs << "[v#{i}][a#{i}]"
    end

    parts << "#{concat_inputs.join}concat=n=#{@roughcut['clips'].size}:v=1:a=1[v][a]"
    parts.join(";\n")
  end

  def report
    size_mb = (File.size(@output_path) / 1024.0 / 1024.0).round(1)
    puts "\n✓ Video exported to: #{@output_path} (#{size_mb} MB)"
  end

  def source_path_for(clip)
    path = @video_paths[clip['source_file']]
    raise "Source file not in library: #{clip['source_file']}" unless path
    raise "Source file missing on disk: #{path}" unless File.exist?(path)

    path
  end

  def run_ffmpeg(cmd)
    success = system(*cmd)
    raise "ffmpeg failed: #{cmd.join(' ')}" unless success
  end

  def timecode_to_seconds(timecode)
    h, m, s = timecode.split(':')
    h.to_i * 3600 + m.to_i * 60 + s.to_f
  end

  def default_output_path
    base = File.basename(@roughcut_path, '.yaml')
    timestamp = Time.now.strftime('%Y%m%d_%H%M%S')
    "libraries/#{library_name}/roughcuts/#{base}_preview_#{timestamp}.mp4"
  end
end

if __FILE__ == $PROGRAM_NAME
  if ARGV.empty? || ARGV.length > 2
    warn "Usage: #{$PROGRAM_NAME} <roughcut.yaml> [output.mp4]"
    exit 1
  end

  RoughcutVideoExporter.export(roughcut_path: ARGV[0], output_path: ARGV[1])
end
