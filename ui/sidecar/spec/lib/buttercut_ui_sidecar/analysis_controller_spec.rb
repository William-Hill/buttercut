require "spec_helper"
require "fileutils"
require "tmpdir"
require "json"
require "stringio"
require "yaml"
require_relative "../../../lib/buttercut_ui_sidecar/notifier"
require_relative "../../../lib/buttercut_ui_sidecar/job_registry"
require_relative "../../../lib/buttercut_ui_sidecar/analysis_controller"

RSpec.describe ButtercutUiSidecar::AnalysisController do
  def make_library(root, name: "demo", videos:)
    lib_dir = File.join(root, name)
    FileUtils.mkdir_p(File.join(lib_dir, "transcripts"))
    FileUtils.mkdir_p(File.join(lib_dir, "summaries"))
    File.write(File.join(lib_dir, "library.yaml"), YAML.dump(
                 "library_name" => name, "language" => "English", "language_code" => "en",
                 "transcript_refinement" => false, "videos" => videos.map { |v| { "path" => v, "duration" => "00:00:05" } }
               ))
    lib_dir
  end

  it "runs all three stages for one video and updates library.yaml" do
    Dir.mktmpdir do |root|
      v = File.join(root, "a.mp4")
      File.write(v, "x")
      lib_dir = make_library(root, videos: [v])

      io = StringIO.new
      notifier = ButtercutUiSidecar::Notifier.new(io: io)
      registry = ButtercutUiSidecar::JobRegistry.new

      transcribe = instance_double("TranscribeStage")
      analyze = instance_double("AnalyzeStage")
      summarize = instance_double("SummarizeStage")
      allow(transcribe).to receive(:run) do |args|
        path = File.join(args[:transcript_output_dir], "a.json")
        File.write(path, JSON.generate(segments: []))
        { transcript_path: path }
      end
      allow(analyze).to receive(:run) do |args|
        File.write(args[:visual_transcript_path], JSON.generate(segments: []))
        { visual_transcript_path: args[:visual_transcript_path] }
      end
      allow(summarize).to receive(:run) do |args|
        File.write(args[:summary_output_path], "## Overview")
        { summary_path: args[:summary_output_path] }
      end

      controller = described_class.new(
        libraries_root: root, notifier: notifier, registry: registry,
        transcribe: transcribe, analyze: analyze, summarize: summarize,
        whisper_model: "small"
      )
      job_id = controller.start!(library: "demo")

      controller.wait!(job_id)

      data = YAML.safe_load(File.read(File.join(lib_dir, "library.yaml")))
      v0 = data["videos"].first
      expect(v0["transcript"]).to eq("a.json")
      expect(v0["visual_transcript"]).to eq("visual_a.json")
      expect(v0["summary"]).to eq("summary_a.md")

      events = io.string.lines.map { |l| JSON.parse(l) }
      methods = events.map { |e| e["method"] }
      expect(methods).to include("job_started", "file_started", "artifact_ready", "file_done", "job_done")
    end
  end

  it "skips stages already present and still completes the job" do
    Dir.mktmpdir do |root|
      v = File.join(root, "a.mp4")
      File.write(v, "x")
      lib_dir = make_library(root, videos: [v])
      transcripts = File.join(lib_dir, "transcripts")
      summaries = File.join(lib_dir, "summaries")
      File.write(File.join(transcripts, "a.json"), JSON.generate(segments: []))
      File.write(File.join(transcripts, "visual_a.json"), JSON.generate(segments: []))

      yaml = YAML.safe_load(File.read(File.join(lib_dir, "library.yaml")))
      yaml["videos"][0]["transcript"] = "a.json"
      yaml["videos"][0]["visual_transcript"] = "visual_a.json"
      File.write(File.join(lib_dir, "library.yaml"), YAML.dump(yaml))

      io = StringIO.new
      notifier = ButtercutUiSidecar::Notifier.new(io: io)
      registry = ButtercutUiSidecar::JobRegistry.new

      transcribe = instance_double("TranscribeStage")
      analyze = instance_double("AnalyzeStage")
      summarize = instance_double("SummarizeStage")
      allow(transcribe).to receive(:run).and_raise("transcribe should not run")
      allow(analyze).to receive(:run).and_raise("analyze should not run")
      allow(summarize).to receive(:run) do |args|
        File.write(args[:summary_output_path], "## Overview")
        { summary_path: args[:summary_output_path] }
      end

      controller = described_class.new(
        libraries_root: root, notifier: notifier, registry: registry,
        transcribe: transcribe, analyze: analyze, summarize: summarize,
        whisper_model: "small"
      )
      job_id = controller.start!(library: "demo")
      controller.wait!(job_id)

      data = YAML.safe_load(File.read(File.join(lib_dir, "library.yaml")))
      expect(data["videos"].first["summary"]).to eq("summary_a.md")

      methods = io.string.lines.map { |l| JSON.parse(l)["method"] }
      expect(methods).not_to include("file_failed")
      expect(methods.count { |m| m == "file_started" }).to eq(1)
    end
  end
end
