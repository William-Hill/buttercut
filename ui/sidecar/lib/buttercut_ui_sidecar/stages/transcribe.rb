# frozen_string_literal: true

require "open3"
require "pathname"

module ButtercutUiSidecar
  module Stages
    class Transcribe
      DEFAULT_PREPARE_SCRIPT = File.expand_path("../../../../../.claude/skills/transcribe-audio/prepare_audio_script.rb", __dir__)

      def initialize(shell: nil, prepare: nil, prepare_script: DEFAULT_PREPARE_SCRIPT)
        @shell = shell || method(:default_shell)
        @prepare = prepare || method(:default_prepare).curry[prepare_script]
      end

      # Returns { transcript_path: <abs path> } on success.
      def run(job:, video_path:, transcript_output_dir:, language_code:, whisper_model:)
        return cancel_result if job.canceled?

        argv = [
          "whisperx", video_path,
          "--language", language_code,
          "--model", whisper_model,
          "--compute_type", "float32",
          "--device", "cpu",
          "--output_format", "json",
          "--output_dir", transcript_output_dir
        ]

        ok, stderr = @shell.call(argv, on_pid: ->(pid) { job.register_pid(pid) })
        raise "whisperx failed: #{stderr.strip}" unless ok
        return cancel_result if job.canceled?

        basename = File.basename(video_path, ".*")
        json_path = File.join(transcript_output_dir, "#{basename}.json")
        raise "whisperx produced no output at #{json_path}" unless File.file?(json_path)

        @prepare.call(json_path, video_path)
        { transcript_path: json_path }
      end

      private

      def cancel_result
        { canceled: true }
      end

      def default_shell(argv, on_pid:)
        stdin, stdout_err, wait_thr = Open3.popen2e(*argv)
        stdin.close
        on_pid.call(wait_thr.pid)
        out = stdout_err.read
        wait_thr.value.success? ? [true, out] : [false, out]
      end

      def default_prepare(prepare_script, json_path, video_path)
        ok, err = run_simple("ruby", prepare_script, json_path, video_path)
        raise "prepare_audio_script failed: #{err.strip}" unless ok
      end

      def run_simple(*argv)
        out, status = Open3.capture2e(*argv)
        [status.success?, out]
      end
    end
  end
end
