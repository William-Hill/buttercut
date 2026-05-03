# frozen_string_literal: true

require "json"

module ButtercutUiSidecar
  module Stages
    class Summarize
      def initialize(haiku:, prompt_path: nil)
        raise ArgumentError, "haiku required" if haiku.nil?
        @haiku = haiku
        @prompt_path = prompt_path || self.class.default_prompt_path
      end

      def run(job:, visual_transcript_path:, summary_output_path:)
        return cancel_result if job.canceled?

        script = extract_script(visual_transcript_path)
        prompt = File.read(@prompt_path) + "\n\n## Visual transcript\n\n" + script
        markdown = @haiku.call(prompt)
        return cancel_result if job.canceled?

        atomic_write(summary_output_path, markdown)
        { summary_path: summary_output_path }
      end

      def self.default_prompt_path
        File.expand_path("../../../prompts/summarize_video.md", __dir__)
      end

      private

      def extract_script(visual_path)
        data = JSON.parse(File.read(visual_path))
        lines = []
        (data["segments"] || []).each do |s|
          ts = format_ts(s["start"].to_f)
          lines << "[VISUAL] #{s['visual']}" if s["visual"]
          lines << "[#{ts}] #{s['text']}" if s["text"] && !s["text"].empty?
        end
        lines.join("\n")
      end

      def format_ts(seconds)
        format("[%02d:%02d]", seconds.to_i / 60, seconds.to_i % 60)
      end

      def atomic_write(path, body)
        tmp = path + ".tmp"
        File.write(tmp, body)
        File.rename(tmp, path)
      end

      def cancel_result
        { canceled: true }
      end
    end
  end
end
