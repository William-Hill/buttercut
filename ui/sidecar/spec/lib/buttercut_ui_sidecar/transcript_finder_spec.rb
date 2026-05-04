# ui/sidecar/spec/lib/buttercut_ui_sidecar/transcript_finder_spec.rb
require "spec_helper"
require "tmpdir"
require_relative "../../fixtures/library_fixture"
require_relative "../../../lib/buttercut_ui_sidecar/transcript_finder"

RSpec.describe ButtercutUiSidecar::TranscriptFinder do
  def with_two_clip_lib
    Dir.mktmpdir do |root|
      lib_dir = LibraryFixture.build(root, name: "demo",
        videos: [
          { path: "/x/a.mp4", transcript: "a.json" },
          { path: "/x/b.mp4", transcript: "b.json" }
        ])
      LibraryFixture.write_whisperx_transcript(lib_dir, "a.json", segments: [
        {
          start: 0.0, end: 1.0, text: " I bought a Tenderlohn loaf",
          words: [
            { word: "I", start: 0.0, end: 0.05 },
            { word: "bought", start: 0.06, end: 0.3 },
            { word: "a", start: 0.31, end: 0.35 },
            { word: "Tenderlohn", start: 0.36, end: 0.7 },
            { word: "loaf", start: 0.71, end: 1.0 }
          ]
        }
      ])
      LibraryFixture.write_whisperx_transcript(lib_dir, "b.json", segments: [
        {
          start: 0.0, end: 0.8, text: " near Tenderlohn",
          words: [
            { word: "near", start: 0.0, end: 0.2 },
            { word: "Tenderlohn", start: 0.21, end: 0.8 }
          ]
        },
        {
          start: 1.0, end: 1.5, text: " a carrot cake",
          words: [
            { word: "a", start: 1.0, end: 1.05 },
            { word: "carrot", start: 1.06, end: 1.3 },
            { word: "cake", start: 1.31, end: 1.5 }
          ]
        }
      ])
      yield root, lib_dir
    end
  end

  describe ".find" do
    it "finds matches across multiple clips with clip filename, segment, and word index" do
      with_two_clip_lib do |root, _lib_dir|
        matches = described_class.find(libraries_root: root, library: "demo", tokens: ["Tenderlohn"], scope: :library)
        expect(matches.size).to eq(2)
        expect(matches.map { |m| m[:clip] }.sort).to eq(["a.json", "b.json"])
        a_match = matches.find { |m| m[:clip] == "a.json" }
        expect(a_match[:segment_index]).to eq(0)
        expect(a_match[:word_index]).to eq(3)
      end
    end

    it "is case-insensitive in matching but returns the actual cased token slice" do
      with_two_clip_lib do |root, _lib_dir|
        matches = described_class.find(libraries_root: root, library: "demo", tokens: ["tenderlohn"], scope: :library)
        expect(matches.size).to eq(2)
        expect(matches.first[:matched_tokens]).to eq(["Tenderlohn"])
      end
    end

    it "matches whole tokens only — NOT substrings (the `car` -> `carrot` trap)" do
      with_two_clip_lib do |root, _lib_dir|
        matches = described_class.find(libraries_root: root, library: "demo", tokens: ["car"], scope: :library)
        expect(matches).to be_empty
      end
    end

    it "supports clip-scoped search" do
      with_two_clip_lib do |root, _lib_dir|
        matches = described_class.find(libraries_root: root, library: "demo", tokens: ["Tenderlohn"], scope: :clip, clip: "a.json")
        expect(matches.size).to eq(1)
        expect(matches.first[:clip]).to eq("a.json")
      end
    end

    it "supports N-token phrase search" do
      with_two_clip_lib do |root, _lib_dir|
        matches = described_class.find(libraries_root: root, library: "demo", tokens: ["a", "carrot"], scope: :library)
        expect(matches.size).to eq(1)
        expect(matches.first[:clip]).to eq("b.json")
        expect(matches.first[:segment_index]).to eq(1)
        expect(matches.first[:word_index]).to eq(0)
      end
    end

    it "returns context_snippet with surrounding words" do
      with_two_clip_lib do |root, _lib_dir|
        matches = described_class.find(libraries_root: root, library: "demo", tokens: ["Tenderlohn"], scope: :library)
        a = matches.find { |m| m[:clip] == "a.json" }
        expect(a[:context_snippet]).to include("Tenderlohn")
        expect(a[:context_snippet]).to include("bought") # surrounding context
      end
    end
  end
end
