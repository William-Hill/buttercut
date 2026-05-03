require "spec_helper"
require "tmpdir"
require "yaml"
require_relative "../../../lib/buttercut_ui_sidecar/library_creator"

RSpec.describe ButtercutUiSidecar::LibraryCreator do
  def video(dir, name, duration: "00:00:05")
    path = File.join(dir, name)
    File.write(path, "x")
    { path: path, duration_seconds: 5 }
  end

  it "slugifies the name and creates the directory tree + library.yaml" do
    Dir.mktmpdir do |root|
      Dir.mktmpdir do |footage|
        creator = described_class.new(libraries_root: root)
        result = creator.create!(
          name: "My Bike Series",
          language: "English",
          language_code: "en",
          refinement: true,
          videos: [video(footage, "a.mp4"), video(footage, "b.mp4")]
        )
        expect(result[:name]).to eq("my-bike-series")

        lib_dir = File.join(root, "my-bike-series")
        expect(File.directory?(File.join(lib_dir, "transcripts"))).to be true
        expect(File.directory?(File.join(lib_dir, "summaries"))).to be true

        data = YAML.safe_load(File.read(File.join(lib_dir, "library.yaml")), permitted_classes: [Date, Time])
        expect(data["library_name"]).to eq("my-bike-series")
        expect(data["language"]).to eq("English")
        expect(data["language_code"]).to eq("en")
        expect(data["transcript_refinement"]).to be true
        expect(data["videos"].length).to eq(2)
        expect(data["videos"].first["transcript"]).to eq("")
        expect(data["videos"].first["visual_transcript"]).to eq("")
        expect(data["videos"].first["summary"]).to eq("")
      end
    end
  end

  it "errors with library_exists when the slug already has a library.yaml" do
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "demo"))
      File.write(File.join(root, "demo", "library.yaml"), "library_name: demo")
      creator = described_class.new(libraries_root: root)
      expect {
        creator.create!(name: "Demo", language: "English", language_code: "en", refinement: false, videos: [])
      }.to raise_error(described_class::LibraryExists)
    end
  end

  it "rolls back on partial failure (e.g. yaml write fails)" do
    Dir.mktmpdir do |root|
      creator = described_class.new(libraries_root: root)
      allow(File).to receive(:write).and_call_original
      allow(File).to receive(:write).with(/library\.yaml/, anything).and_raise(Errno::EACCES, "denied")

      expect {
        creator.create!(name: "rollback", language: "English", language_code: "en", refinement: false, videos: [])
      }.to raise_error(Errno::EACCES)

      expect(File.directory?(File.join(root, "rollback"))).to be false
    end
  end
end
