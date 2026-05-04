# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "base64"
require "pathname"
require "set"
require "tmpdir"

module ButtercutUiSidecar
  module Stages
    class Analyze
      def initialize(ffmpeg: nil, vision: nil, prompt_path: self.class.default_prompt_path)
        @ffmpeg = ffmpeg || method(:default_ffmpeg)
        @vision = vision # required when not in test mode
        @prompt_path = prompt_path
      end

      def run(job:, video_path:, audio_transcript_path:, visual_transcript_path:)
        return cancel_result if job.canceled?

        tmp_dir = nil
        begin
          prepared = prepare_skeleton(audio_transcript_path)
          timestamps = sample_timestamps(prepared)
          frames, tmp_dir = extract_frames(job, video_path, timestamps)
          return cancel_result if job.canceled?

          prompt = File.read(@prompt_path)
          response = @vision.call(frames, prompt + "\n\nHere is the prepared transcript skeleton (JSON):\n" + JSON.pretty_generate(prepared))
          return cancel_result if job.canceled?

          merged = merge_segments(prepared, response.fetch("segments"))
          atomic_write_json(visual_transcript_path, merged)

          { visual_transcript_path: visual_transcript_path }
        ensure
          FileUtils.rm_rf(tmp_dir) if tmp_dir && File.directory?(tmp_dir)
        end
      end

      def self.default_prompt_path
        File.expand_path("../../../prompts/analyze_video.md", __dir__)
      end

      private

      def prepare_skeleton(audio_path)
        data = JSON.parse(File.read(audio_path))
        # Strip word-level timing to keep the visual transcript small (mirrors
        # .claude/skills/analyze-video/prepare_visual_script.rb).
        if data["segments"]
          data["segments"] = data["segments"].map do |s|
            s.dup.tap { |c| c.delete("words") }
          end
        end
        data
      end

      def sample_timestamps(prepared)
        duration = (prepared.dig("segments", -1, "end") || 0).to_f
        return [duration / 2.0] if duration <= 30
        [2.0, duration / 2.0, [duration - 2.0, 2.0].max]
      end

      def extract_frames(job, video_path, timestamps)
        tmp_dir = File.join(Dir.tmpdir, "buttercut-frames-#{job.id}-#{File.basename(video_path, ".*")}")
        FileUtils.mkdir_p(tmp_dir)
        frames = []
        timestamps.each_with_index do |ts, i|
          return [frames, tmp_dir] if job.canceled?
          out = File.join(tmp_dir, "frame_#{i}.jpg")
          ok = @ffmpeg.call(video_path, ts, out, job: job)
          frames << out if ok && File.file?(out)
        end
        [frames, tmp_dir]
      end

      def merge_segments(prepared, response_segments)
        # Map response segments by start time to the skeleton; preserve any
        # fields the model didn't touch.
        by_start = response_segments.each_with_object({}) { |s, h| h[s["start"].to_f] = s }
        prepared["segments"] = prepared["segments"].map do |skel|
          rs = by_start[skel["start"].to_f] || {}
          skel.merge(rs.slice("visual", "b_roll"))
        end
        # Append any b-roll-only segments from the response that weren't in the skeleton.
        skel_starts = prepared["segments"].map { |s| s["start"].to_f }.to_set
        extras = response_segments.reject { |s| skel_starts.include?(s["start"].to_f) }
        prepared["segments"].concat(extras)
        prepared
      end

      def atomic_write_json(path, data)
        tmp = path + ".tmp"
        File.write(tmp, JSON.pretty_generate(data))
        File.rename(tmp, path)
      end

      def cancel_result
        { canceled: true }
      end

      def default_ffmpeg(video_path, timestamp, out_path, job:)
        cmd = ["ffmpeg", "-ss", format_ts(timestamp), "-i", video_path,
               "-vframes", "1", "-vf", "scale=1280:-1", "-y", out_path]
        stdin, stdout_err, wait_thr = Open3.popen2e(*cmd)
        stdin.close
        pid = wait_thr.pid
        job.register_pid(pid)
        begin
          stdout_err.read
          wait_thr.value.success?
        ensure
          job.unregister_pid(pid)
        end
      end

      def format_ts(seconds)
        s = seconds.to_f
        format("%02d:%02d:%06.3f", s / 3600, (s.to_i % 3600) / 60, s % 60)
      end
    end
  end
end
