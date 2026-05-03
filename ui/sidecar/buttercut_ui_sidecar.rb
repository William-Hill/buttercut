#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "yaml"
require "time"
require "pathname"

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
    yaml_path = @libraries_root.join(name, "library.yaml")
    raise ArgumentError, "library not found: #{name}" unless yaml_path.file?

    data = YAML.safe_load(yaml_path.read, permitted_classes: [Date, Time], aliases: true) || {}
    videos = (data["videos"] || []).map { |v| video_entry(v) }

    {
      name: data["library_name"] || name,
      footage_summary: data["footage_summary"] || "",
      video_paths_root: longest_common_parent(videos.map { |v| v[:path] }),
      videos: videos
    }
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
    common.join(File::SEPARATOR)
  end

  def get_clip_transcripts(library, video)
    yaml_path = @libraries_root.join(library, "library.yaml")
    raise ArgumentError, "library not found: #{library}" unless yaml_path.file?

    data = YAML.safe_load(yaml_path.read, permitted_classes: [Date, Time], aliases: true) || {}
    entry = (data["videos"] || []).find { |v| File.basename(v["path"].to_s) == video }
    raise ArgumentError, "video not found in #{library}: #{video}" if entry.nil?

    lib_dir = @libraries_root.join(library)
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
