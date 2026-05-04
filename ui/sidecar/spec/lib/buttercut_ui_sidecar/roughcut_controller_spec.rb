# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "yaml"
require "stringio"
require_relative "../../../lib/buttercut_ui_sidecar/notifier"
require_relative "../../../lib/buttercut_ui_sidecar/job_registry"
require_relative "../../../lib/buttercut_ui_sidecar/roughcut_controller"
require_relative "../../fixtures/library_fixture"

RSpec.describe ButtercutUiSidecar::RoughcutController do
  def repo_root
    File.expand_path("../../../../../", __dir__)
  end

  let(:fake_yaml) do
    <<~YAML
      description: "Test"
      notes: ""
      footage_coverage: ""
      clips:
        - source_file: "a.mp4"
          in_point: "00:00:00.00"
          out_point: "00:00:01.00"
          dialogue: "hello"
          visual_description: "wide shot"
      metadata:
        created_date: ""
        total_duration: ""
    YAML
  end

  it "prerequisites_report flags missing fields" do
    data = {
      "videos" => [
        { "path" => "/x/a.mp4", "transcript" => "a.json", "visual_transcript" => "", "summary" => "s.md" }
      ]
    }
    r = described_class.prerequisites_report(data)
    expect(r[:ok]).to be false
    expect(r[:missing].first["missing"]).to include("visual_transcript")
  end

  it "runs model + export and notifies done" do
    Dir.mktmpdir do |root|
      video = File.join(root, "a.mp4")
      File.write(video, "x")
      lib_dir = LibraryFixture.build(
        root,
        name: "demo",
        videos: [{
          path: video,
          transcript: "a.json",
          visual_transcript: "visual_a.json",
          summary: "summary_a.md"
        }]
      )
      LibraryFixture.write_visual_transcript(lib_dir, "visual_a.json", segments: [
        { start: 0.0, end: 2.0, text: "hello", visual: "wide" }
      ])
      yaml_lib = YAML.safe_load(File.read(File.join(lib_dir, "library.yaml")))
      yaml_lib["editor"] = "fcpx"
      File.write(File.join(lib_dir, "library.yaml"), YAML.dump(yaml_lib))

      store = ButtercutUiSidecar::BriefStore.new(libraries_root: root, library: "demo")
      bid = store.upsert(id: nil, prompt: "Make a one second cut", target_duration_seconds: 5, title: "t")

      io = StringIO.new
      notifier = ButtercutUiSidecar::Notifier.new(io: io)

      client = instance_double(ButtercutUiSidecar::AnthropicClient)
      wrapped = "```yaml\n#{fake_yaml}\n```"
      allow(client).to receive(:messages_create).and_return(
        { "content" => [{ "text" => wrapped }] }
      )

      status = instance_double(Process::Status, success?: true)
      allow(Open3).to receive(:capture2e).and_return(["export ok", status])

      controller = described_class.new(
        libraries_root: root,
        repo_root: repo_root,
        notifier: notifier,
        registry: ButtercutUiSidecar::JobRegistry.new,
        client: client
      )

      controller.validate_and_start!(library: "demo", brief_id: bid)

      deadline = Time.now + 5
      loop do
        break if io.string.include?("roughcut_job_done") || io.string.include?("roughcut_job_failed")
        raise "roughcut job did not finish" if Time.now > deadline

        sleep 0.02
      end

      lines = io.string.lines.map { |l| JSON.parse(l) }
      methods = lines.map { |x| x["method"] }
      expect(methods).to include("roughcut_job_done")

      done = lines.reverse.find { |x| x["method"] == "roughcut_job_done" }
      expect(done["params"]["clips"].size).to eq(1)
      expect(done["params"]["yaml_path"]).to end_with(".yaml")
      expect(done["params"]["xml_path"]).to end_with(".fcpxml")
      expect(done["params"]["recipe_path"]).to end_with(".recipe.json")
      expect(done["params"]["apply_path"]).to end_with("_apply.py")

      expect(Open3).to have_received(:capture2e)
    end
  end

  describe "#extract_yaml_fence" do
    let(:controller) { described_class.allocate }

    it "extracts multiline ```yaml bodies" do
      inner = <<~YAML.strip
        clips:
          - source_file: a.mp4
            in_point: "00:00:00.00"
            out_point: "00:00:01.00"
            dialogue: ""
            visual_description: "x"
      YAML
      text = "Intro\n```yaml\n#{inner}\n```\n"
      expect(controller.send(:extract_yaml_fence, text)).to eq(inner)
    end

    it "prefers ```yaml over an earlier non-roughcut fence" do
      yaml_inner = <<~YAML.strip
        clips:
          - source_file: a.mp4
            in_point: "00:00:00.00"
            out_point: "00:00:01.00"
            dialogue: ""
            visual_description: "x"
      YAML
      text = <<~MD
        ```json
        {"note": "not roughcut yaml"}
        ```
        ```yaml
        #{yaml_inner}
        ```
      MD
      expect(controller.send(:extract_yaml_fence, text)).to eq(yaml_inner)
    end

    it "accepts an untagged fence that parses as roughcut YAML" do
      inner = fake_yaml.strip
      text = "```\n#{inner}\n```"
      expect(controller.send(:extract_yaml_fence, text)).to eq(inner)
    end

    it "returns stripped raw text when no fence matches" do
      expect(controller.send(:extract_yaml_fence, "  clips: []\n")).to eq("clips: []")
    end
  end

  describe ".safe_visual_transcript_path" do
    it "rejects absolute paths and path traversal" do
      lib = Pathname.new("/tmp/demo_lib")
      expect { described_class.safe_visual_transcript_path(lib, "/etc/passwd") }.to raise_error(/invalid_visual_transcript_ref/)
      expect { described_class.safe_visual_transcript_path(lib, "..#{File::SEPARATOR}x.json") }.to raise_error(/invalid_visual_transcript_ref/)
    end

    it "returns a path under transcripts for a basename" do
      lib = Pathname.new("/tmp/demo_lib")
      p = described_class.safe_visual_transcript_path(lib, "foo.json")
      expect(p.to_s).to end_with(File.join("transcripts", "foo.json"))
    end
  end

  describe "#validate_roughcut_shape!" do
    let(:controller) { described_class.allocate }
    let(:library_data) { { "videos" => [{ "path" => "/vol/a.mp4" }] } }

    it "rejects source_file not in the library" do
      rough = {
        "clips" => [
          {
            "source_file" => "other.mp4",
            "in_point" => "00:00:00.00",
            "out_point" => "00:00:01.00",
            "dialogue" => "",
            "visual_description" => "x"
          }
        ]
      }
      expect { controller.send(:validate_roughcut_shape!, rough, library_data) }.to raise_error(/invalid_source_file/)
    end

    it "rejects out_point <= in_point" do
      rough = {
        "clips" => [
          {
            "source_file" => "a.mp4",
            "in_point" => "00:00:05.00",
            "out_point" => "00:00:01.00",
            "dialogue" => "",
            "visual_description" => "x"
          }
        ]
      }
      expect { controller.send(:validate_roughcut_shape!, rough, library_data) }.to raise_error(/invalid_time_range/)
    end
  end
end
