# ui/sidecar/spec/lib/buttercut_ui_sidecar/library_replacer_spec.rb
require "spec_helper"
require "stringio"
require "tmpdir"
require "yaml"
require_relative "../../fixtures/library_fixture"
require_relative "../../../lib/buttercut_ui_sidecar/notifier"
require_relative "../../../lib/buttercut_ui_sidecar/library_replacer"

RSpec.describe ButtercutUiSidecar::LibraryReplacer do
  def with_lib(user_context: "")
    Dir.mktmpdir do |root|
      lib_dir = LibraryFixture.build(root, name: "demo",
        videos: [
          { path: "/x/a.mp4", transcript: "a.json" },
          { path: "/x/b.mp4", transcript: "b.json" }
        ])

      yaml_path = File.join(lib_dir, "library.yaml")
      data = YAML.safe_load(File.read(yaml_path)) || {}
      data["user_context"] = user_context
      File.write(yaml_path, YAML.dump(data))

      LibraryFixture.write_whisperx_transcript(lib_dir, "a.json", segments: [
        { start: 0.0, end: 0.5, text: " near Tenderlohn",
          words: [
            { word: "near", start: 0.0, end: 0.2 },
            { word: "Tenderlohn", start: 0.21, end: 0.5 }
          ] }
      ])
      LibraryFixture.write_whisperx_transcript(lib_dir, "b.json", segments: [
        { start: 0.0, end: 0.7, text: " over by Tenderlohn area",
          words: [
            { word: "over", start: 0.0, end: 0.1 },
            { word: "by", start: 0.11, end: 0.2 },
            { word: "Tenderlohn", start: 0.21, end: 0.5 },
            { word: "area", start: 0.51, end: 0.7 }
          ] }
      ])

      yield root, lib_dir
    end
  end

  let(:io) { StringIO.new }
  let(:notifier) { ButtercutUiSidecar::Notifier.new(io: io) }

  describe ".apply" do
    it "replaces all matches across clips and returns affected clip count" do
      with_lib do |root, lib_dir|
        result = described_class.apply(
          libraries_root: root, library: "demo",
          old_tokens: ["Tenderlohn"], new_tokens: ["Tenderloin"], trust: false,
          notifier: notifier
        )

        expect(result[:edit_count]).to eq(2)
        expect(result[:affected_clips]).to contain_exactly("a.json", "b.json")

        a = JSON.parse(File.read(File.join(lib_dir, "transcripts", "a.json")))
        b = JSON.parse(File.read(File.join(lib_dir, "transcripts", "b.json")))
        expect(a["segments"][0]["text"]).to eq(" near Tenderloin")
        expect(b["segments"][0]["text"]).to eq(" over by Tenderloin area")
      end
    end

    it "emits a transcript_edited notification per affected clip" do
      with_lib do |root, _lib_dir|
        described_class.apply(
          libraries_root: root, library: "demo",
          old_tokens: ["Tenderlohn"], new_tokens: ["Tenderloin"], trust: false,
          notifier: notifier
        )

        lines = io.string.lines.map { |l| JSON.parse(l) }
        edited = lines.select { |l| l["method"] == "transcript_edited" }
        expect(edited.size).to eq(2)
        expect(edited.map { |n| n.dig("params", "clip") }.sort).to eq(["a.json", "b.json"])
        expect(edited.first.dig("params", "library")).to eq("demo")
        expect(edited.first.dig("params", "edit_count")).to eq(1)
      end
    end

    it "appends to user_context when trust=true (idempotent)" do
      with_lib do |root, lib_dir|
        described_class.apply(
          libraries_root: root, library: "demo",
          old_tokens: ["Tenderlohn"], new_tokens: ["Tenderloin"], trust: true,
          notifier: notifier
        )

        yaml = YAML.safe_load(File.read(File.join(lib_dir, "library.yaml")))
        expect(yaml["user_context"]).to include("Tenderloin")

        # Idempotent: second call doesn't double-append.
        described_class.apply(
          libraries_root: root, library: "demo",
          old_tokens: ["Tenderloin"], new_tokens: ["Tenderloin"], trust: true,
          notifier: notifier
        )

        yaml2 = YAML.safe_load(File.read(File.join(lib_dir, "library.yaml")))
        expect(yaml2["user_context"].scan("Tenderloin").size).to eq(1)
      end
    end

    it "does NOT touch user_context when trust=false even if matches replaced" do
      with_lib(user_context: "existing context") do |root, lib_dir|
        described_class.apply(
          libraries_root: root, library: "demo",
          old_tokens: ["Tenderlohn"], new_tokens: ["Tenderloin"], trust: false,
          notifier: notifier
        )

        yaml = YAML.safe_load(File.read(File.join(lib_dir, "library.yaml")))
        expect(yaml["user_context"]).to eq("existing context")
      end
    end

    it "uses a single mutex acquisition for the whole walk" do
      with_lib do |root, _lib_dir|
        mutex = Mutex.new
        acquired = 0
        allow(mutex).to receive(:synchronize).and_wrap_original do |orig, &blk|
          acquired += 1
          orig.call(&blk)
        end

        described_class.apply(
          libraries_root: root, library: "demo",
          old_tokens: ["Tenderlohn"], new_tokens: ["Tenderloin"], trust: false,
          notifier: notifier, mutex: mutex
        )

        expect(acquired).to eq(1)
      end
    end

    it "returns edit_count=0 when there are no matches" do
      with_lib do |root, _lib_dir|
        result = described_class.apply(
          libraries_root: root, library: "demo",
          old_tokens: ["Pleasanton"], new_tokens: ["Pleasanton"], trust: false,
          notifier: notifier
        )
        expect(result[:edit_count]).to eq(0)
        expect(result[:affected_clips]).to be_empty
      end
    end
  end
end
