require "spec_helper"
require "tmpdir"
require "json"
require_relative "../../../../lib/buttercut_ui_sidecar/stages/summarize"
require_relative "../../../../lib/buttercut_ui_sidecar/analysis_job"

RSpec.describe ButtercutUiSidecar::Stages::Summarize do
  it "writes the markdown summary atomically using the supplied Haiku callable" do
    Dir.mktmpdir do |dir|
      visual = File.join(dir, "visual_a.json")
      File.write(visual, JSON.generate(language: "en", video_path: "/x/a.mp4", segments: [
        { start: 0.0, end: 5.0, text: "hello", visual: "scene" }
      ]))
      summary_path = File.join(dir, "summary_a.md")

      haiku = ->(_prompt) { "## Overview\n\nMan says hello.\n\n## Key visuals\n- scene\n\n## Dialogue\n\nNone\n\n## B-roll\n\nNone\n" }
      stage = described_class.new(haiku: haiku)
      job = ButtercutUiSidecar::AnalysisJob.new(id: "j1", library: "demo")

      result = stage.run(job: job, visual_transcript_path: visual, summary_output_path: summary_path)
      expect(result[:summary_path]).to eq(summary_path)
      expect(File.read(summary_path)).to include("## Overview")
    end
  end
end
