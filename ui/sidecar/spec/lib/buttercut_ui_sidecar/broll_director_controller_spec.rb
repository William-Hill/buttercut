require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"
require "yaml"
require "pathname"
require "date"
require_relative "../../../lib/buttercut_ui_sidecar/job_registry"
require_relative "../../../lib/buttercut_ui_sidecar/broll_director_controller"

RSpec.describe ButtercutUiSidecar::BrollDirectorController do
  let(:repo_root) { File.expand_path("../../../../..", __dir__) }
  let(:notifier) { double("notifier", notify: nil) }
  let(:registry) { ButtercutUiSidecar::JobRegistry.new }

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

  it "honors per-library broll defaults when caller passes nil and applies the blacklist" do
    canned = File.read(File.expand_path(
      "../../../../../spec/fixtures/broll_director/canned_model_response.json", __dir__
    ))
    client = double("anthropic_client")
    captured_user = nil
    allow(client).to receive(:complete) { |args| captured_user = args[:user]; canned }

    with_libraries_root do |root|
      lib_yaml = root.join("sample-library/library.yaml")
      data = YAML.safe_load(lib_yaml.read, permitted_classes: [Date, Time])
      data["broll"] = { "density" => "low", "score_threshold" => 0.7, "blacklist_terms" => ["rebase"], "code_vocabulary" => ["git", "npm"] }
      lib_yaml.write(data.to_yaml)

      controller = described_class.new(
        libraries_root: root.to_s, repo_root: repo_root,
        notifier: notifier, registry: registry, client: client
      )
      result = controller.run!(library: "sample-library", roughcut_stem: "sample")

      manifest_path = root.join("sample-library/roughcuts/sample.broll.yaml")
      manifest = YAML.safe_load(manifest_path.read, permitted_classes: [Date, Time])
      commands = manifest["entries"].map { |e| e["content"]["command"] }
      expect(commands).not_to include("git rebase -i HEAD~3")
      expect(commands).to include("git status")
      expect(result[:entries_written]).to eq(commands.length)

      payload = JSON.parse(captured_user)
      expect(payload["DENSITY"]).to eq("low")
      expect(payload["SCORE_THRESHOLD"]).to eq(0.7)
      expect(payload["BLACKLIST_TERMS"]).to eq(["rebase"])
      expect(payload["CODE_VOCABULARY"]).to eq(["git", "npm"])
    end
  end

  it "rejects roughcut_stem values that try to escape the roughcuts directory" do
    with_libraries_root do |root|
      controller = described_class.new(
        libraries_root: root.to_s, repo_root: repo_root,
        notifier: notifier, registry: registry,
        client: double("c")
      )
      ["../../../etc/passwd", "foo/bar", "..\\\\evil", "", "a/b"].each do |bad|
        expect {
          controller.run!(library: "sample-library", roughcut_stem: bad,
                          density: "medium", score_threshold: 0.5)
        }.to raise_error(ArgumentError, /invalid roughcut_stem/), "expected reject for #{bad.inspect}"
      end
    end
  end
end
