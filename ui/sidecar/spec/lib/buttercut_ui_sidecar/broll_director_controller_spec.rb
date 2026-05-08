require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"
require "yaml"
require "pathname"
require "date"
require_relative "../../../lib/buttercut_ui_sidecar/broll_director_controller"

RSpec.describe ButtercutUiSidecar::BrollDirectorController do
  let(:repo_root) { File.expand_path("../../../../..", __dir__) }
  let(:notifier) { double("notifier", notify: nil) }
  let(:registry) {
    Class.new {
      def initialize; @jobs = {}; end
      def create(_); id = "job-#{@jobs.size + 1}"; @jobs[id] = { canceled: false }; id; end
      def canceled?(id); @jobs[id][:canceled]; end
    }.new
  }

  let(:fixture_lib) {
    File.expand_path("../../../../../spec/fixtures/broll_director/sample_library", __dir__)
  }

  def with_libraries_root
    Dir.mktmpdir do |tmp|
      FileUtils.cp_r(fixture_lib, File.join(tmp, "sample-library"))
      yield Pathname.new(tmp)
    end
  end

  it "writes a validated manifest using a stubbed model response" do
    canned = File.read(File.expand_path(
      "../../../../../spec/fixtures/broll_director/canned_model_response.json", __dir__
    ))
    client = double("anthropic_client")
    allow(client).to receive(:complete).and_return(canned)

    with_libraries_root do |root|
      controller = described_class.new(
        libraries_root: root.to_s,
        repo_root: repo_root,
        notifier: notifier,
        registry: registry,
        client: client
      )
      result = controller.run!(
        library: "sample-library",
        roughcut_stem: "sample",
        density: "medium",
        score_threshold: 0.5
      )

      expect(result[:entries_written]).to be > 0
      manifest_path = root.join("sample-library/roughcuts/sample.broll.yaml")
      expect(manifest_path.file?).to be true
      data = YAML.safe_load(manifest_path.read, permitted_classes: [Date, Time])
      expect(data["library"]).to eq("sample-library")
      expect(data["roughcut"]).to eq("sample")
      expect(data["entries"]).not_to be_empty
    end
  end

  it "raises when the rough cut does not exist" do
    with_libraries_root do |root|
      controller = described_class.new(
        libraries_root: root.to_s, repo_root: repo_root,
        notifier: notifier, registry: registry,
        client: double("c")
      )
      expect {
        controller.run!(library: "sample-library", roughcut_stem: "nope",
                        density: "medium", score_threshold: 0.5)
      }.to raise_error(/rough cut not found/)
    end
  end
end
