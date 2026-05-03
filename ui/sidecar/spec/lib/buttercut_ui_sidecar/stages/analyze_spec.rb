require "spec_helper"
require "tmpdir"
require "json"
require_relative "../../../../lib/buttercut_ui_sidecar/stages/analyze"
require_relative "../../../../lib/buttercut_ui_sidecar/analysis_job"

RSpec.describe ButtercutUiSidecar::Stages::Analyze do
  let(:job) { ButtercutUiSidecar::AnalysisJob.new(id: "j1", library: "demo") }

  def setup_audio(dir, name: "a.json")
    path = File.join(dir, name)
    File.write(path, JSON.generate(language: "en", video_path: "/x/a.mp4",
      segments: [{ start: 0.0, end: 5.0, text: "hello", words: [] }]))
    path
  end

  it "writes the visual transcript with model-supplied descriptions" do
    Dir.mktmpdir do |dir|
      audio = setup_audio(dir)
      visual = File.join(dir, "visual_a.json")

      ffmpeg = ->(_video, _ts, out_path, on_pid:) { on_pid.call(rand(2**16)); File.write(out_path, "fakejpg"); true }
      vision = ->(_frames, _prompt) { { "segments" => [{ "start" => 0.0, "end" => 5.0, "text" => "hello", "visual" => "scene" }] } }

      stage = described_class.new(ffmpeg: ffmpeg, vision: vision)
      result = stage.run(job: job, video_path: "/x/a.mp4", audio_transcript_path: audio, visual_transcript_path: visual)

      expect(result[:visual_transcript_path]).to eq(visual)
      expect(File.file?(visual)).to be true
      data = JSON.parse(File.read(visual))
      expect(data["segments"].first["visual"]).to eq("scene")
    end
  end

  it "respects cancellation between frame extraction and vision call" do
    Dir.mktmpdir do |dir|
      audio = setup_audio(dir)
      visual = File.join(dir, "visual_a.json")

      ffmpeg = ->(_, _, out_path, on_pid:) { on_pid.call(1); File.write(out_path, "fakejpg"); true }
      vision = ->(_, _) { raise "should not call vision" }

      stage = described_class.new(ffmpeg: ffmpeg, vision: vision)
      job.cancel!
      result = stage.run(job: job, video_path: "/x/a.mp4", audio_transcript_path: audio, visual_transcript_path: visual)
      expect(result[:canceled]).to be true
      expect(File.file?(visual)).to be false
    end
  end
end
