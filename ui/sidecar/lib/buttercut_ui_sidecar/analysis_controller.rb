# frozen_string_literal: true

require "concurrent"
require "date"
require "fileutils"
require "json"
require "pathname"
require "securerandom"
require "yaml"
require_relative "limits"
require_relative "analysis_job"
require_relative "presence"

module ButtercutUiSidecar
  class AnalysisController
    def initialize(libraries_root:, notifier:, registry:,
                   transcribe:, analyze:, summarize:,
                   whisper_model: "small")
      raise ArgumentError, "libraries_root required" if libraries_root.nil? || libraries_root.to_s.empty?
      raise ArgumentError, "notifier required" if notifier.nil?
      raise ArgumentError, "registry required" if registry.nil?

      @libraries_root = Pathname.new(libraries_root)
      @notifier = notifier
      @registry = registry
      @stages = { transcribe: transcribe, analyze: analyze, summarize: summarize }
      @whisper_model = whisper_model
    end

    # Kicks off a job and returns its id immediately. Use #wait! in tests.
    def start!(library:)
      job_id = "job-#{SecureRandom.hex(6)}"
      job = AnalysisJob.new(id: job_id, library: library)
      @registry.put(job_id, job)

      lib_dir = @libraries_root.join(library)
      data = read_yaml(lib_dir)
      videos = (data["videos"] || []).reject do |v|
        Presence.present?(v["transcript"]) && Presence.present?(v["visual_transcript"]) && Presence.present?(v["summary"])
      end

      @completion_latch = Concurrent::CountDownLatch.new(1)

      units_total = videos.sum { |v| pending_stage_count(v) }
      @notifier.notify("job_started", job_id: job_id, library: library, video_count: units_total)

      if units_total.zero?
        @notifier.notify("job_done", job_id: job_id, succeeded_count: 0, failed_count: 0)
        @registry.delete(job_id)
        @completion_latch.count_down
        return job_id
      end

      pools = build_pools
      done = Concurrent::AtomicFixnum.new(0)
      failed = Concurrent::AtomicFixnum.new(0)
      remaining_units = Concurrent::AtomicFixnum.new(units_total)

      complete_unit = lambda do |succeeded|
        succeeded ? done.increment : failed.increment
        if remaining_units.decrement.zero?
          @notifier.notify("job_done", job_id: job_id,
                                       succeeded_count: done.value, failed_count: failed.value)
          shutdown_pools(pools)
          @registry.delete(job_id)
          @completion_latch.count_down
        end
      end

      videos.each do |v|
        chain_stages(job: job, video: v, lib_dir: lib_dir, pools: pools, on_complete: complete_unit, data: data)
      end

      job_id
    end

    # Test helper.
    def wait!(_job_id, timeout: 30)
      @completion_latch.wait(timeout)
    end

    private

    def pending_stage_count(video)
      n = 0
      n += 1 unless Presence.present?(video["transcript"])
      n += 1 unless Presence.present?(video["visual_transcript"])
      n += 1 unless Presence.present?(video["summary"])
      n
    end

    def build_pools
      {
        transcribe: Concurrent::FixedThreadPool.new(Limits::TRANSCRIBE_PARALLELISM),
        analyze:    Concurrent::FixedThreadPool.new(Limits::ANALYZE_PARALLELISM),
        summarize:  Concurrent::FixedThreadPool.new(Limits::SUMMARIZE_PARALLELISM)
      }
    end

    def shutdown_pools(pools)
      pools.values.each(&:shutdown)
    end

    def chain_stages(job:, video:, lib_dir:, pools:, on_complete:, data:)
      basename = File.basename(video["path"])
      stem = File.basename(basename, ".*")
      transcripts_dir = lib_dir.join("transcripts").to_s
      summaries_dir = lib_dir.join("summaries").to_s
      audio_path   = File.join(transcripts_dir, "#{stem}.json")
      visual_path  = File.join(transcripts_dir, "visual_#{stem}.json")
      summary_path = File.join(summaries_dir,   "summary_#{stem}.md")

      need_t = !Presence.present?(video["transcript"])
      need_a = !Presence.present?(video["visual_transcript"])
      need_s = !Presence.present?(video["summary"])

      transcribe_body = lambda do
        res = @stages[:transcribe].run(
          job: job, video_path: video["path"], transcript_output_dir: transcripts_dir,
          language_code: data["language_code"] || "en", whisper_model: @whisper_model
        )
        raise "stage canceled" if res.is_a?(Hash) && res[:canceled]

        update_yaml_field(lib_dir, video["path"], "transcript", File.basename(audio_path))
      end

      analyze_body = lambda do
        res = @stages[:analyze].run(
          job: job, video_path: video["path"],
          audio_transcript_path: audio_path, visual_transcript_path: visual_path
        )
        raise "stage canceled" if res.is_a?(Hash) && res[:canceled]

        update_yaml_field(lib_dir, video["path"], "visual_transcript", File.basename(visual_path))
      end

      summarize_body = lambda do
        res = @stages[:summarize].run(
          job: job, visual_transcript_path: visual_path, summary_output_path: summary_path
        )
        raise "stage canceled" if res.is_a?(Hash) && res[:canceled]

        update_yaml_field(lib_dir, video["path"], "summary", File.basename(summary_path))
      end

      after_analyze = lambda do
        if need_s
          pools[:summarize].post do
            run_step(job: job, stage: :summarize, video: basename,
                     artifact_path: summary_path, on_complete: on_complete, on_success: -> {},
                     need_a: false, need_s: false) { summarize_body.call }
          end
        end
      end

      after_transcribe = lambda do
        if need_a
          pools[:analyze].post do
            run_step(job: job, stage: :analyze, video: basename,
                     artifact_path: visual_path, on_complete: on_complete, on_success: after_analyze,
                     need_a: need_a, need_s: need_s) { analyze_body.call }
          end
        else
          after_analyze.call
        end
      end

      if need_t
        pools[:transcribe].post do
          run_step(job: job, stage: :transcribe, video: basename,
                   artifact_path: audio_path, on_complete: on_complete, on_success: after_transcribe,
                   need_a: need_a, need_s: need_s) { transcribe_body.call }
        end
      else
        after_transcribe.call
      end
    end

    def run_step(job:, stage:, video:, artifact_path:, on_complete:, on_success:, need_a:, need_s:)
      if job.canceled?
        on_complete.call(false)
        flush_skipped_after_abort(stage, need_a: need_a, need_s: need_s, on_complete: on_complete)
        return
      end
      @notifier.notify("file_started", job_id: job.id, video: video, stage: stage.to_s)
      begin
        yield
        @notifier.notify("artifact_ready", job_id: job.id, video: video, stage: stage.to_s, artifact_path: artifact_path)
        @notifier.notify("file_done", job_id: job.id, video: video, stage: stage.to_s)
        on_complete.call(true)
        on_success.call
      rescue StandardError => e
        @notifier.notify("file_failed", job_id: job.id, video: video, stage: stage.to_s,
                                         error_kind: classify_error(e), message: e.message)
        on_complete.call(false)
        flush_skipped_after_abort(stage, need_a: need_a, need_s: need_s, on_complete: on_complete)
      end
    end

    # When a stage aborts, downstream stages counted in units_total may never run — complete those units.
    def flush_skipped_after_abort(stage, need_a:, need_s:, on_complete:)
      case stage
      when :transcribe
        on_complete.call(false) if need_a
        on_complete.call(false) if need_s
      when :analyze
        on_complete.call(false) if need_s
      when :summarize
        # no downstream
      end
    end

    def classify_error(error)
      case error.message
      when /invalid_api_key/i, /AuthenticationError/i then "auth"
      when /whisperx failed/i then "transcribe"
      when /ffmpeg/i then "ffmpeg"
      else "unknown"
      end
    end

    def read_yaml(lib_dir)
      YAML.safe_load(File.read(lib_dir.join("library.yaml")), permitted_classes: [Date, Time], aliases: true) || {}
    end

    def update_yaml_field(lib_dir, video_path, field, value)
      yaml_path = lib_dir.join("library.yaml")
      lock_file = "#{yaml_path}.lock"
      File.open(lock_file, File::RDWR | File::CREAT, 0o600) do |f|
        f.flock(File::LOCK_EX)
        ydata = YAML.safe_load(File.read(yaml_path), permitted_classes: [Date, Time], aliases: true) || {}
        (ydata["videos"] || []).each do |v|
          v[field] = value if v["path"] == video_path
        end
        ydata["last_updated"] = Date.today.iso8601
        File.write("#{yaml_path}.tmp", YAML.dump(ydata))
        File.rename("#{yaml_path}.tmp", yaml_path.to_s)
      end
    end
  end
end
