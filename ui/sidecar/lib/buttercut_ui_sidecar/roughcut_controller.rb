# frozen_string_literal: true

require "json"
require "open3"
require "pathname"
require "securerandom"
require "set"
require "time"
require "yaml"

require_relative "analysis_job"
require_relative "anthropic_client"
require_relative "brief_store"
require_relative "presence"

module ButtercutUiSidecar
  # UI-driven rough cut: combine visual transcripts → Sonnet YAML → existing export script.
  class RoughcutController
    COMBINED_TRANSCRIPT_MAX_BYTES = 900_000
    MODEL = AnthropicClient::VISION_MODEL
    PREREQ_KEYS = %w[transcript visual_transcript summary].freeze

    def self.prerequisites_report(library_data)
      missing = []
      (library_data["videos"] || []).each do |v|
        base = File.basename(v["path"].to_s)
        absent = PREREQ_KEYS.reject { |k| Presence.present?(v[k]) }
        missing << { "video" => base, "missing" => absent } unless absent.empty?
      end
      { ok: missing.empty?, missing: missing }
    end

    def self.build_combined_visual_ndjson(library_data:, lib_dir:)
      lines = []
      (library_data["videos"] || []).each do |v|
        fn = v["visual_transcript"]
        next unless Presence.present?(fn)

        path = safe_visual_transcript_path(lib_dir, fn)
        next unless path.file?

        obj = JSON.parse(path.read)
        obj["video_path"] = v["path"].to_s if obj["video_path"].to_s.empty?
        lines << JSON.generate(obj)
      end
      lines.join("\n") + "\n"
    end

    # Reject absolute paths and directory traversal in library.yaml visual_transcript refs.
    def self.safe_visual_transcript_path(lib_dir, fn)
      s = fn.to_s
      raise "invalid_visual_transcript_ref:#{fn}" if Pathname.new(s).absolute?
      raise "invalid_visual_transcript_ref:#{fn}" if s != File.basename(s)

      transcripts_dir = lib_dir.join("transcripts").expand_path
      path = transcripts_dir.join(s).expand_path
      unless path.to_s.start_with?(transcripts_dir.to_s + File::SEPARATOR)
        raise "invalid_visual_transcript_ref:#{fn}"
      end

      path
    end

    def self.video_basenames(library_data)
      (library_data["videos"] || []).map { |v| File.basename(v["path"].to_s) }.to_set
    end

    def self.valid_clip_timecode?(tc)
      parts = tc.to_s.split(":")
      return false unless parts.length == 3

      parts.all? { |p| p.match?(/\A\d+(\.\d+)?\z/) }
    end

    def self.timecode_to_seconds(tc)
      parts = tc.to_s.split(":")
      return 0.0 if parts.length < 3

      parts[0].to_i * 3600 + parts[1].to_i * 60 + parts[2].to_f
    end

    def self.format_timecode(total_seconds)
      t = total_seconds.to_f
      h = (t / 3600).floor
      m = ((t - h * 3600) / 60).floor
      s = t - (h * 3600) - (m * 60)
      format("%02d:%02d:%05.2f", h, m, s)
    end

    def initialize(libraries_root:, repo_root:, notifier:, registry:, client:)
      raise ArgumentError, "libraries_root required" if libraries_root.nil? || libraries_root.to_s.empty?
      raise ArgumentError, "repo_root required" if repo_root.nil? || repo_root.to_s.empty?
      raise ArgumentError, "notifier required" if notifier.nil?
      raise ArgumentError, "registry required" if registry.nil?
      raise ArgumentError, "client required" if client.nil?

      @libraries_root = Pathname.new(libraries_root)
      @repo_root = Pathname.new(repo_root)
      @notifier = notifier
      @registry = registry
      @client = client
    end

    # Raises StandardError if prerequisites, brief, or size checks fail.
    def validate_and_start!(library:, brief_id:)
      lib_dir = @libraries_root.join(library)
      raise "library.yaml not found" unless lib_dir.join("library.yaml").file?

      library_data = YAML.safe_load(
        lib_dir.join("library.yaml").read,
        permitted_classes: [Date, Time],
        aliases: true
      ) || {}

      pre = self.class.prerequisites_report(library_data)
      raise "roughcut_prerequisites: #{JSON.generate(pre[:missing])}" unless pre[:ok]

      store = BriefStore.new(libraries_root: @libraries_root.to_s, library: library)
      brief = store.get(brief_id)
      raise "unknown_brief: #{brief_id}" if brief.nil?

      combined = self.class.build_combined_visual_ndjson(library_data: library_data, lib_dir: lib_dir)
      raise "no_visual_transcripts" if combined.strip.empty?

      bytes = combined.bytesize
      if bytes > COMBINED_TRANSCRIPT_MAX_BYTES
        raise "combined_transcript_too_large: #{bytes} bytes (max #{COMBINED_TRANSCRIPT_MAX_BYTES})"
      end

      job_id = "job-#{SecureRandom.hex(6)}"
      job = AnalysisJob.new(id: job_id, library: library)
      @registry.put(job_id, job)

      prompt_text = brief["prompt"].to_s
      target = Integer(brief["target_duration_seconds"])

      Thread.new do
        run_job(job: job, library: library, lib_dir: lib_dir, library_data: library_data,
                combined_ndjson: combined, prompt_text: prompt_text, target_duration: target)
      rescue StandardError => e
        warn "[roughcut #{job_id}] FAILED #{e.class}: #{e.message}"
        warn e.backtrace.first(8).map { |l| "  #{l}" }.join("\n") if e.backtrace
        notify_failed(job_id, e.message)
      ensure
        @registry.delete(job_id)
      end

      { job_id: job_id }
    end

    private

    def notify_failed(job_id, message)
      @notifier.notify("roughcut_job_failed", job_id: job_id, message: message)
    end

    def run_job(job:, library:, lib_dir:, library_data:, combined_ndjson:, prompt_text:, target_duration:)
      job_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      log = ->(step, **details) {
        elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - job_started_at).round(2)
        suffix = details.empty? ? "" : " " + details.map { |k, v| "#{k}=#{v}" }.join(" ")
        warn "[roughcut #{job.id} +#{elapsed}s] #{step}#{suffix}"
      }

      log.call("starting", library: library, target_s: target_duration)

      if job.canceled?
        log.call("canceled_before_start")
        @notifier.notify("roughcut_job_failed", job_id: job.id, message: "canceled")
        return
      end

      @notifier.notify("roughcut_job_started", job_id: job.id, library: library)
      @notifier.notify("roughcut_phase", job_id: job.id, phase: "model", message: "Generating rough cut YAML…")

      system_instructions = roughcut_prompt_template
      user_blob = build_user_message(
        library_data: library_data,
        combined_ndjson: combined_ndjson,
        prompt_text: prompt_text,
        target_duration: target_duration
      )
      log.call("prompt_built",
               system_bytes: system_instructions.bytesize,
               user_bytes: user_blob.bytesize,
               clips_in_lib: (library_data["videos"] || []).length)

      log.call("anthropic_request_send", model: MODEL, max_tokens: 24_576)
      api_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = @client.messages_create(
        model: MODEL,
        max_tokens: 24_576,
        temperature: 0.2,
        system: system_instructions,
        messages: [{ role: "user", content: user_blob }]
      )
      api_elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - api_started).round(2)
      body = AnthropicClient.message_body_text(response)
      log.call("anthropic_response", api_seconds: api_elapsed, body_bytes: body.bytesize)

      yaml_text = extract_yaml_fence(body)
      log.call("yaml_extracted", yaml_bytes: yaml_text.bytesize)

      rough = YAML.safe_load(yaml_text, permitted_classes: [Date, Time, Symbol]) || {}
      (rough["clips"] || []).each { |c| c["dialogue"] = "" unless c.key?("dialogue") }
      log.call("yaml_parsed", clip_count: (rough["clips"] || []).length)

      validate_roughcut_shape!(rough, library_data)
      log.call("validated")

      enrich_metadata!(rough)
      ts = Time.now.utc.strftime("%Y%m%d_%H%M%S")
      stem = "roughcut_ui_#{ts}"
      roughcuts_dir = lib_dir.join("roughcuts")
      roughcuts_dir.mkpath
      yaml_path = roughcuts_dir.join("#{stem}.yaml")
      yaml_path.write(YAML.dump(stringify_keys_deep(rough)))
      log.call("yaml_written", path: yaml_path.to_s)

      editor = resolve_editor_flag(library_data)
      xml_path = roughcuts_dir.join(editor == "fcpx" ? "#{stem}.fcpxml" : "#{stem}.xml")

      @notifier.notify("roughcut_phase", job_id: job.id, phase: "export", message: "Exporting XML and recipe…")
      log.call("export_start", editor: editor, xml: xml_path.to_s)
      export!(yaml_path: yaml_path, xml_path: xml_path, editor: editor)
      log.call("export_done")

      xml_base = xml_path.to_s.sub(/\.[^.]+\z/, "")
      recipe_path = "#{xml_base}.recipe.json"
      apply_path = "#{xml_base}_apply.py"
      clips = (rough["clips"] || []).map do |c|
        {
          "source_file" => c["source_file"].to_s,
          "in_point" => c["in_point"].to_s,
          "out_point" => c["out_point"].to_s
        }
      end

      @notifier.notify(
        "roughcut_job_done",
        job_id: job.id,
        library: library,
        yaml_path: yaml_path.expand_path.to_s,
        xml_path: xml_path.expand_path.to_s,
        recipe_path: Pathname.new(recipe_path).expand_path.to_s,
        apply_path: Pathname.new(apply_path).expand_path.to_s,
        clips: clips
      )
      log.call("done", clip_count: clips.length)
    end

    def export!(yaml_path:, xml_path:, editor:)
      script = @repo_root.join(".claude/skills/roughcut", "export_to_fcpxml.rb")
      raise "export script missing: #{script}" unless script.file?

      gemfile = @repo_root.join("Gemfile").to_s
      cmd = ["bundle", "exec", "ruby", script.to_s, yaml_path.expand_path.to_s, xml_path.expand_path.to_s, editor]
      out = nil
      status = nil
      Dir.chdir(@repo_root.to_s) do
        out, status = Open3.capture2e({ "BUNDLE_GEMFILE" => gemfile }, *cmd)
      end
      raise "export_failed: #{out.to_s.strip}" unless status.success?
    end

    def resolve_editor_flag(library_data)
      raw = library_data["editor"].to_s.strip.downcase
      return normalize_editor_token(raw) unless raw.empty?

      settings = @libraries_root.join("settings.yaml")
      if settings.file?
        s = YAML.safe_load(settings.read, permitted_classes: [Date, Time], aliases: true) || {}
        raw2 = s["editor"].to_s.strip.downcase
        return normalize_editor_token(raw2) unless raw2.empty?
      end
      "fcpx"
    end

    def normalize_editor_token(raw)
      return "fcpx" if raw.match?(/fcpx|final\s*cut|finalcut/)
      return "premiere" if raw.match?(/premiere|adobe/)
      return "resolve" if raw.match?(/resolve|davinci/)

      "fcpx"
    end

    def roughcut_prompt_template
      path = Pathname.new(__dir__).join("../../prompts/roughcut_from_transcript.md")
      raise "roughcut prompt missing: #{path}" unless path.file?

      path.read
    end

    def build_user_message(library_data:, combined_ndjson:, prompt_text:, target_duration:)
      ctx = []
      ctx << "footage_summary: #{library_data['footage_summary']}" if library_data["footage_summary"]
      ctx << "user_context: #{library_data['user_context']}" if library_data["user_context"]
      <<~MSG
        USER_BRIEF:
        #{prompt_text}

        TARGET_DURATION_SECONDS: #{target_duration}

        #{ctx.join("\n")}

        COMBINED_VISUAL_TRANSCRIPTS_NDJSON:
        #{combined_ndjson}
      MSG
    end

    def extract_yaml_fence(text)
      body = text.to_s
      if (m = body.match(/```(?:yaml|yml)\s*\n([\s\S]*?)```/mi))
        return m[1].strip
      end

      body.scan(/```[^\n\r]*\r?\n([\s\S]*?)```/m).each do |(inner)|
        begin
          candidate = inner&.strip
          next if candidate.nil? || candidate.empty?

          parsed = YAML.safe_load(candidate, permitted_classes: [Date, Time, Symbol], aliases: true)
          return candidate if parsed.is_a?(Hash) && parsed["clips"].is_a?(Array) && !parsed["clips"].empty?
        rescue Psych::SyntaxError, ArgumentError
          next
        end
      end

      body.strip
    end

    def validate_roughcut_shape!(rough, library_data)
      clips = rough["clips"]
      raise "roughcut_missing_clips" unless clips.is_a?(Array) && !clips.empty?

      allowed = self.class.video_basenames(library_data)

      clips.each_with_index do |c, i|
        raise "clip #{i} missing source_file" unless Presence.present?(c["source_file"])
        raise "clip #{i} missing in_point" unless Presence.present?(c["in_point"])
        raise "clip #{i} missing out_point" unless Presence.present?(c["out_point"])
        raise "clip #{i} missing dialogue" unless c.key?("dialogue")
        raise "clip #{i} missing visual_description" unless Presence.present?(c["visual_description"])

        base = File.basename(c["source_file"].to_s)
        raise "clip #{i} invalid_source_file" unless allowed.include?(base)

        unless self.class.valid_clip_timecode?(c["in_point"]) && self.class.valid_clip_timecode?(c["out_point"])
          raise "clip #{i} invalid_timecode"
        end

        t_in = self.class.timecode_to_seconds(c["in_point"])
        t_out = self.class.timecode_to_seconds(c["out_point"])
        raise "clip #{i} invalid_time_range" unless t_out > t_in
      end
    end

    def enrich_metadata!(rough)
      clips = rough["clips"] || []
      total = clips.sum do |c|
        self.class.timecode_to_seconds(c["out_point"]) - self.class.timecode_to_seconds(c["in_point"])
      end
      rough["metadata"] ||= {}
      rough["metadata"]["created_date"] = Time.now.utc.strftime("%Y-%m-%d %H:%M:%S")
      rough["metadata"]["total_duration"] = self.class.format_timecode(total)
    end

    def stringify_keys_deep(obj)
      case obj
      when Hash
        obj.each_with_object({}) { |(k, v), h| h[k.to_s] = stringify_keys_deep(v) }
      when Array
        obj.map { |e| stringify_keys_deep(e) }
      else
        obj
      end
    end
  end
end
