#!/usr/bin/env ruby
# frozen_string_literal: true

require "base64"
require "json"
require "open3"
require "pathname"
require "time"
require "yaml"

require_relative "lib/buttercut_ui_sidecar/limits"
require_relative "lib/buttercut_ui_sidecar/notifier"
require_relative "lib/buttercut_ui_sidecar/settings_store"
require_relative "lib/buttercut_ui_sidecar/anthropic_client"
require_relative "lib/buttercut_ui_sidecar/video_inspector"
require_relative "lib/buttercut_ui_sidecar/library_creator"
require_relative "lib/buttercut_ui_sidecar/job_registry"
require_relative "lib/buttercut_ui_sidecar/analysis_job"
require_relative "lib/buttercut_ui_sidecar/analysis_controller"
require_relative "lib/buttercut_ui_sidecar/transcript_editor"
require_relative "lib/buttercut_ui_sidecar/transcript_finder"
require_relative "lib/buttercut_ui_sidecar/library_replacer"
require_relative "lib/buttercut_ui_sidecar/stages/transcribe"
require_relative "lib/buttercut_ui_sidecar/stages/analyze"
require_relative "lib/buttercut_ui_sidecar/stages/summarize"

module ButtercutUiSidecar
  def self.run(libraries_root:, io_in: $stdin, io_out: $stdout)
    Dispatcher.new(libraries_root: libraries_root, io_in: io_in, io_out: io_out).run
  end

  class Dispatcher
    def initialize(libraries_root:, io_in:, io_out:)
      raise ArgumentError, "libraries_root required" if libraries_root.nil? || libraries_root.to_s.empty?

      @libraries_root = Pathname.new(libraries_root)
      @io_in = io_in
      @io_out = io_out
      @io_out.sync = true

      @settings = ButtercutUiSidecar::SettingsStore.new(libraries_root: @libraries_root.to_s)
      @notifier = ButtercutUiSidecar::Notifier.new(io: @io_out)
      @inspector = ButtercutUiSidecar::VideoInspector.new
      @creator = ButtercutUiSidecar::LibraryCreator.new(libraries_root: @libraries_root.to_s)
      @registry = ButtercutUiSidecar::JobRegistry.new
      @transcript_mutex = Mutex.new
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
    rescue ButtercutUiSidecar::LibraryCreator::LibraryExists => e
      respond_error(id: id, code: -32011, message: "library_exists: #{e.message}")
    rescue ButtercutUiSidecar::TranscriptEditor::TokenCountViolation => e
      respond_error(id: id, code: -32013, message: "token_count_violation: #{e.message}")
    rescue StandardError => e
      case e.message
      when /\Amissing_api_key(\z|:)/
        respond_error(id: id, code: -32010, message: "missing_api_key")
      when /\Ainvalid_api_key/
        respond_error(id: id, code: -32012, message: e.message)
      else
        respond_error(id: id, code: -32000, message: "#{e.class}: #{e.message}")
      end
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
      when "has_api_key"
        { configured: @settings.configured? }
      when "set_api_key"
        set_api_key(params.fetch("key"))
      when "inspect_video_paths"
        @inspector.inspect(params.fetch("paths"))
      when "create_library"
        @creator.create!(
          name: params.fetch("name"),
          language: params.fetch("language"),
          language_code: params.fetch("language_code"),
          refinement: params.fetch("refinement"),
          videos: params.fetch("videos")
        )
      when "start_analysis"
        controller = build_controller_or_raise!
        job_id = controller.start!(library: params.fetch("library"))
        { job_id: job_id }
      when "cancel_job"
        job = @registry.get(params.fetch("job_id"))
        job&.cancel!
        {}
      when "retry_unit"
        raise StandardError, "retry_unit is not yet supported in M2 minimum scope; re-run start_analysis to resume."
      when "apply_transcript_edit"
        edit = symbolize_edit(params.fetch("edit"))
        result = @transcript_mutex.synchronize do
          ButtercutUiSidecar::TranscriptEditor.apply(
            libraries_root: @libraries_root.to_s,
            library: params.fetch("library"),
            clip: params.fetch("clip"),
            edit: edit
          )
        end
        # Emit a notification so the frontend's transcript_edited listener fires
        # for clip-scope edits too (mirrors LibraryReplacer's per-clip notifications).
        # Fixes review issue I3 — uniform event emission.
        @notifier.notify("transcript_edited",
          library: params.fetch("library"), clip: params.fetch("clip"), edit_count: result[:edit_count])
        result
      when "find_transcript_matches"
        matches = ButtercutUiSidecar::TranscriptFinder.find(
          libraries_root: @libraries_root.to_s,
          library: params.fetch("library"),
          tokens: params.fetch("tokens"),
          scope: params.fetch("scope").to_sym,
          clip: params["clip"]
        )
        { matches: matches }
      when "apply_library_replace"
        ButtercutUiSidecar::LibraryReplacer.apply(
          libraries_root: @libraries_root.to_s,
          library: params.fetch("library"),
          old_tokens: params.fetch("old_tokens"),
          new_tokens: params.fetch("new_tokens"),
          trust: params.fetch("trust"),
          notifier: @notifier,
          mutex: @transcript_mutex
        )
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
      root = Pathname.new(File.realpath(root)) if root.directory?
      candidate = root.join(name)
      dir = candidate.exist? ? File.realpath(candidate) : candidate.expand_path
      dir = Pathname.new(dir) if dir.is_a?(String)
      root_prefix = root.to_s + File::SEPARATOR
      raise ArgumentError, "invalid library name: #{name}" unless dir.to_s.start_with?(root_prefix)
      dir
    end

    def load_library_yaml(name)
      yaml_path = library_dir(name).join("library.yaml")
      raise ArgumentError, "library not found: #{name}" unless yaml_path.file?
      YAML.safe_load(yaml_path.read, permitted_classes: [Date, Time], aliases: true) || {}
    end

    def find_video_entry(library_data, library_name, video)
      videos = library_data["videos"] || []
      entry = videos.find { |v| v["path"].to_s == video }
      entry ||= videos.find { |v| File.basename(v["path"].to_s) == video }
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

    def set_api_key(key)
      client = ButtercutUiSidecar::AnthropicClient.new(api_key: key)
      client.validate_key!
      @settings.write_api_key!(key)
      { ok: true }
    rescue ButtercutUiSidecar::AnthropicClient::InvalidApiKey => e
      raise StandardError, "invalid_api_key: #{e.message}"
    end

    def build_controller_or_raise!
      api_key = @settings.api_key
      raise StandardError, "missing_api_key" if api_key.nil?

      client = ButtercutUiSidecar::AnthropicClient.new(api_key: api_key)

      vision = lambda do |frames, prompt|
        content = frames.map do |f|
          {
            type: "image",
            source: {
              type: "base64",
              media_type: "image/jpeg",
              data: Base64.strict_encode64(File.binread(f))
            }
          }
        end
        content << {
          type: "text",
          text: "#{prompt}\n\nReturn ONLY a JSON object of the form {\"segments\": [...]}, no prose."
        }
        response = client.messages_create(
          model: ButtercutUiSidecar::AnthropicClient::VISION_MODEL,
          max_tokens: 4096,
          messages: [{ role: "user", content: content }]
        )
        text = ButtercutUiSidecar::AnthropicClient.message_body_text(response)
        json_slice = text[/\{.*\}/m]
        raise "vision model returned no JSON object" if json_slice.nil? || json_slice.empty?

        JSON.parse(json_slice)
      end

      haiku = lambda do |prompt|
        response = client.messages_create(
          model: ButtercutUiSidecar::AnthropicClient::HAIKU_MODEL,
          max_tokens: 1024,
          messages: [{ role: "user", content: prompt }]
        )
        ButtercutUiSidecar::AnthropicClient.message_body_text(response)
      end

      ButtercutUiSidecar::AnalysisController.new(
        libraries_root: @libraries_root.to_s,
        notifier: @notifier,
        registry: @registry,
        transcribe: ButtercutUiSidecar::Stages::Transcribe.new,
        analyze: ButtercutUiSidecar::Stages::Analyze.new(vision: vision),
        summarize: ButtercutUiSidecar::Stages::Summarize.new(haiku: haiku),
        whisper_model: read_whisper_model
      )
    end

    def read_whisper_model
      path = @libraries_root.join("settings.yaml")
      return "small" unless path.file?

      data = YAML.safe_load(path.read, permitted_classes: [Date, Time], aliases: true) || {}
      data["whisper_model"] || "small"
    end

    def respond(id:, result:)
      @io_out.puts JSON.generate(jsonrpc: "2.0", id: id, result: result)
    end

    def respond_error(id:, code:, message:)
      @io_out.puts JSON.generate(jsonrpc: "2.0", id: id, error: { code: code, message: message })
    end

    def symbolize_edit(edit)
      {
        segment_index: edit.fetch("segment_index"),
        word_index: edit.fetch("word_index"),
        old_tokens: edit.fetch("old_tokens"),
        new_tokens: edit.fetch("new_tokens")
      }
    end

  class UnknownMethod < StandardError; end
  end
end

if __FILE__ == $PROGRAM_NAME
  libraries_root = ARGV[0]
  if libraries_root.nil? || libraries_root.empty?
    warn "usage: buttercut_ui_sidecar.rb <libraries_root>"
    exit 1
  end

  ButtercutUiSidecar.run(libraries_root: libraries_root)
end
