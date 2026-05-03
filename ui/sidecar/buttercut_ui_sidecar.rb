#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "pathname"
require "time"
require "yaml"

class ButtercutUiSidecar
  def self.run(libraries_root:, io_in: $stdin, io_out: $stdout)
    new(libraries_root: libraries_root, io_in: io_in, io_out: io_out).run
  end

  def initialize(libraries_root:, io_in:, io_out:)
    raise ArgumentError, "libraries_root required" if libraries_root.nil? || libraries_root.to_s.empty?

    @libraries_root = Pathname.new(libraries_root)
    @io_in = io_in
    @io_out = io_out
    @io_out.sync = true
  end

  def run
    @io_in.each_line do |line|
      line = line.strip
      next if line.empty?

      handle_line(line)
    end
  end

  private

  def handle_line(line)
    request = JSON.parse(line)
    id = request["id"]
    method = request["method"]
    params = request["params"] || {}

    result = dispatch(method, params)
    respond(id: id, result: result)
  rescue JSON::ParserError => e
    respond_error(id: nil, code: -32700, message: "parse error: #{e.message}")
  rescue UnknownMethod => e
    respond_error(id: id, code: -32601, message: e.message)
  rescue StandardError => e
    respond_error(id: id, code: -32000, message: "#{e.class}: #{e.message}")
  end

  def dispatch(method, params)
    case method
    when "ping"           then "pong"
    when "list_libraries" then list_libraries
    when "get_library"    then get_library(params.fetch("name"))
    when "get_clip_transcripts"
      get_clip_transcripts(params.fetch("library"), params.fetch("video"))
    when "get_or_generate_thumbnail"
      get_or_generate_thumbnail(params.fetch("library"), params.fetch("video"))
    else raise UnknownMethod, "unknown method: #{method}"
    end
  end

  def list_libraries
    Pathname.glob(@libraries_root.join("*", "library.yaml")).filter_map do |yaml_path|
      summarize_library(yaml_path)
    rescue Errno::ENOENT, Errno::EISDIR, Psych::Exception, TypeError => e
      warn "[sidecar] skipping #{yaml_path}: #{e.class}: #{e.message}"
      nil
    end.sort_by { |lib| -Time.parse(lib[:last_touched_at]).to_i }
  end

  def summarize_library(yaml_path)
    data = YAML.safe_load(yaml_path.read, permitted_classes: [Date, Time], aliases: true) || {}
    {
      name: data["library_name"] || yaml_path.parent.basename.to_s,
      video_count: (data["videos"] || []).length,
      last_touched_at: yaml_path.mtime.utc.iso8601
    }
  end

  def get_library(name)
    data = load_library_yaml(name)
    videos = (data["videos"] || []).map { |v| video_entry(v) }

    {
      name: data["library_name"] || name,
      footage_summary: data["footage_summary"] || "",
      video_paths_root: longest_common_parent(videos.map { |v| v[:path] }),
      videos: videos
    }
  end

  # Resolves a library name to its canonical directory under @libraries_root.
  # Rejects names that escape the root via "../", absolute paths, or symlinks
  # — protects against path traversal in load_library_yaml, get_clip_transcripts,
  # and get_or_generate_thumbnail.
  def library_dir(name)
    root = @libraries_root.expand_path
    dir = root.join(name).expand_path
    root_prefix = root.to_s + File::SEPARATOR
    raise ArgumentError, "invalid library name: #{name}" unless dir.to_s.start_with?(root_prefix)
    dir
  end

  def load_library_yaml(name)
    yaml_path = library_dir(name).join("library.yaml")
    raise ArgumentError, "library not found: #{name}" unless yaml_path.file?
    YAML.safe_load(yaml_path.read, permitted_classes: [Date, Time], aliases: true) || {}
  end

  # Library entries are matched by basename. If two videos in different source
  # folders share a filename, only the first is reachable — known limitation
  # of the basename-as-id contract used throughout the sidecar.
  def find_video_entry(library_data, library_name, video)
    entry = (library_data["videos"] || []).find { |v| File.basename(v["path"].to_s) == video }
    raise ArgumentError, "video not found in #{library_name}: #{video}" if entry.nil?
    entry
  end

  def video_entry(v)
    path = v["path"].to_s
    {
      filename: File.basename(path),
      path: path,
      duration_seconds: parse_duration(v["duration"]),
      has_audio_transcript: present?(v["transcript"]),
      has_visual_transcript: present?(v["visual_transcript"]),
      has_summary: present?(v["summary"])
    }
  end

  def present?(value)
    !value.nil? && !value.to_s.empty?
  end

  def parse_duration(value)
    return 0 if value.nil? || value.to_s.empty?
    parts = value.to_s.split(":").map(&:to_f)
    case parts.length
    when 3 then (parts[0] * 3600 + parts[1] * 60 + parts[2]).to_i
    when 2 then (parts[0] * 60 + parts[1]).to_i
    else parts[0].to_i
    end
  end

  def longest_common_parent(paths)
    return "" if paths.empty?
    parents = paths.map { |p| File.dirname(p).split(File::SEPARATOR) }
    common = parents.first.dup
    parents.each do |segs|
      common.length.times do |i|
        if segs[i] != common[i]
          common = common[0...i]
          break
        end
      end
    end
    # Absolute paths split to a leading "" segment; if only that survives,
    # return "/" so the frontend doesn't treat the result as falsy.
    return File::SEPARATOR if common == [""]
    common.join(File::SEPARATOR)
  end

  def get_clip_transcripts(library, video)
    entry = find_video_entry(load_library_yaml(library), library, video)
    lib_dir = library_dir(library)
    {
      audio: read_json_if_set(lib_dir.join("transcripts"), entry["transcript"]),
      visual: read_json_if_set(lib_dir.join("transcripts"), entry["visual_transcript"]),
      summary: read_text_if_set(lib_dir.join("summaries"), entry["summary"])
    }
  end

  def read_json_if_set(dir, name)
    return nil unless present?(name)
    path = dir.join(name)
    return nil unless path.file?
    JSON.parse(path.read)
  rescue JSON::ParserError => e
    raise "transcript parse error in #{path}: #{e.message}"
  end

  def read_text_if_set(dir, name)
    return nil unless present?(name)
    path = dir.join(name)
    path.file? ? path.read : nil
  end

  def get_or_generate_thumbnail(library, video)
    entry = find_video_entry(load_library_yaml(library), library, video)

    cache_dir = library_dir(library).join("thumbnails")
    cache_dir.mkpath
    out_path = cache_dir.join("#{File.basename(video, ".*")}.jpg")
    return { path: out_path.to_s } if out_path.file?

    source = Pathname.new(entry["path"].to_s)
    raise "source video missing: #{video} (expected at #{source})" unless source.file?

    cmd = ["ffmpeg", "-y", "-loglevel", "error", "-ss", "1", "-i", source.to_s,
           "-frames:v", "1", "-q:v", "4", out_path.to_s]
    _stdout, stderr, status = Open3.capture3(*cmd)
    unless status.success? && out_path.file?
      out_path.delete if out_path.file?
      raise "ffmpeg failed for #{video}: #{stderr.strip}"
    end

    { path: out_path.to_s }
  end

  def respond(id:, result:)
    @io_out.puts JSON.generate(jsonrpc: "2.0", id: id, result: result)
  end

  def respond_error(id:, code:, message:)
    @io_out.puts JSON.generate(jsonrpc: "2.0", id: id, error: { code: code, message: message })
  end

  class UnknownMethod < StandardError; end
end

if __FILE__ == $PROGRAM_NAME
  libraries_root = ARGV[0]
  if libraries_root.nil? || libraries_root.empty?
    warn "usage: buttercut_ui_sidecar.rb <libraries_root>"
    exit 1
  end

  ButtercutUiSidecar.run(libraries_root: libraries_root)
end
