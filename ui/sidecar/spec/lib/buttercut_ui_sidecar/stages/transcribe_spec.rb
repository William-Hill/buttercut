require "spec_helper"
require "tmpdir"
require "json"
require_relative "../../../../lib/buttercut_ui_sidecar/stages/transcribe"
require_relative "../../../../lib/buttercut_ui_sidecar/analysis_job"

RSpec.describe ButtercutUiSidecar::Stages::Transcribe do
  it "runs whisperx, prepares the JSON, registers the PID for cancellation" do
    Dir.mktmpdir do |dir|
      video = File.join(dir, "tiny.mp4")
      File.write(video, "x")
      transcript_dir = File.join(dir, "transcripts")
      FileUtils.mkdir_p(transcript_dir)
      expected_output = File.join(transcript_dir, "tiny.json")

      shell = lambda do |argv, on_pid:|
        on_pid.call(12345)
        # simulate whisperx writing the file
        File.write(expected_output, JSON.generate({ language: "en", segments: [] }))
        [true, ""]
      end
      prep = ->(_path, _video) { } # no-op; output already valid

      job = ButtercutUiSidecar::AnalysisJob.new(id: "j1", library: "demo")
      stage = described_class.new(shell: shell, prepare: prep)

      result = stage.run(
        job: job,
        video_path: video,
        transcript_output_dir: transcript_dir,
        language_code: "en",
        whisper_model: "small"
      )

      expect(result[:transcript_path]).to eq(expected_output)
      expect(File.file?(expected_output)).to be true
    end
  end

  it "raises if whisperx returns failure" do
    Dir.mktmpdir do |dir|
      video = File.join(dir, "v.mp4"); File.write(video, "x")
      transcript_dir = File.join(dir, "transcripts"); FileUtils.mkdir_p(transcript_dir)
      shell = ->(_argv, on_pid:) { on_pid.call(1); [false, "boom"] }
      stage = described_class.new(shell: shell, prepare: ->(*) {})
      job = ButtercutUiSidecar::AnalysisJob.new(id: "j1", library: "demo")
      expect {
        stage.run(job: job, video_path: video, transcript_output_dir: transcript_dir,
                  language_code: "en", whisper_model: "small")
      }.to raise_error(/whisperx failed/)
    end
  end
end
