require "spec_helper"
require "json"
require "tmpdir"
require "fileutils"
require_relative "../../fixtures/library_fixture"
require_relative "../../../lib/buttercut_ui_sidecar/transcript_editor"

RSpec.describe ButtercutUiSidecar::TranscriptEditor do
  def with_lib
    Dir.mktmpdir do |root|
      lib_dir = LibraryFixture.build(root, name: "demo",
        videos: [{ path: "/x/a.mp4", transcript: "a.json" }])
      yield root, lib_dir
    end
  end

  def write_transcript(lib_dir)
    LibraryFixture.write_whisperx_transcript(lib_dir, "a.json", segments: [
      {
        start: 0.0, end: 1.5, text: " ride out to Walnut Creak for the weekend",
        words: [
          { word: "ride", start: 0.0, end: 0.2 },
          { word: "out", start: 0.21, end: 0.3 },
          { word: "to", start: 0.31, end: 0.4 },
          { word: "Walnut", start: 0.41, end: 0.7 },
          { word: "Creak", start: 0.71, end: 1.0 },
          { word: "for", start: 1.01, end: 1.1 },
          { word: "the", start: 1.11, end: 1.2 },
          { word: "weekend", start: 1.21, end: 1.5 }
        ]
      }
    ])
  end

  def read_transcript(lib_dir)
    JSON.parse(File.read(File.join(lib_dir, "transcripts", "a.json")))
  end

  describe ".apply" do
    it "applies a 1->1 spelling fix to all three arrays" do
      with_lib do |root, lib_dir|
        write_transcript(lib_dir)

        result = described_class.apply(
          libraries_root: root, library: "demo", clip: "a.json",
          edit: { segment_index: 0, word_index: 4, old_tokens: ["Creak"], new_tokens: ["Creek"] }
        )

        data = read_transcript(lib_dir)
        expect(data["segments"][0]["text"]).to eq(" ride out to Walnut Creek for the weekend")
        expect(data["segments"][0]["words"][4]["word"]).to eq("Creek")
        expect(data["segments"][0]["words"][4]["start"]).to eq(0.71) # timing untouched
        expect(data["word_segments"][4]["word"]).to eq("Creek")
        expect(result[:edit_count]).to eq(1)
      end
    end

    it "supports an N->N phrase fix" do
      with_lib do |root, lib_dir|
        LibraryFixture.write_whisperx_transcript(lib_dir, "a.json", segments: [
          {
            start: 0.0, end: 1.0, text: " hello dear world",
            words: [
              { word: "hello", start: 0.0, end: 0.3 },
              { word: "dear", start: 0.31, end: 0.6 },
              { word: "world", start: 0.61, end: 1.0 }
            ]
          }
        ])

        described_class.apply(
          libraries_root: root, library: "demo", clip: "a.json",
          edit: { segment_index: 0, word_index: 0, old_tokens: ["hello", "dear"], new_tokens: ["howdy", "friend"] }
        )

        data = read_transcript(lib_dir)
        expect(data["segments"][0]["text"]).to eq(" howdy friend world")
        expect(data["segments"][0]["words"].map { |w| w["word"] }).to eq(["howdy", "friend", "world"])
        expect(data["word_segments"].map { |w| w["word"] }).to eq(["howdy", "friend", "world"])
      end
    end

    it "preserves case character-for-character" do
      with_lib do |root, lib_dir|
        LibraryFixture.write_whisperx_transcript(lib_dir, "a.json", segments: [
          {
            start: 0.0, end: 0.5, text: " tundraloin neighborhood",
            words: [
              { word: "tundraloin", start: 0.0, end: 0.3 },
              { word: "neighborhood", start: 0.31, end: 0.5 }
            ]
          }
        ])

        described_class.apply(
          libraries_root: root, library: "demo", clip: "a.json",
          edit: { segment_index: 0, word_index: 0, old_tokens: ["tundraloin"], new_tokens: ["tenderloin"] }
        )

        data = read_transcript(lib_dir)
        expect(data["segments"][0]["text"]).to eq(" tenderloin neighborhood")
      end
    end

    it "raises TokenCountViolation when new_tokens length differs from old_tokens" do
      with_lib do |root, lib_dir|
        write_transcript(lib_dir)

        expect {
          described_class.apply(
            libraries_root: root, library: "demo", clip: "a.json",
            edit: { segment_index: 0, word_index: 4, old_tokens: ["Creak"], new_tokens: ["Walnut", "Creek"] }
          )
        }.to raise_error(ButtercutUiSidecar::TranscriptEditor::TokenCountViolation)

        # Disk unchanged
        expect(read_transcript(lib_dir)["segments"][0]["text"]).to eq(" ride out to Walnut Creak for the weekend")
      end
    end

    it "raises ArgumentError if old_tokens does not match the words at (segment_index, word_index)" do
      with_lib do |root, lib_dir|
        write_transcript(lib_dir)

        expect {
          described_class.apply(
            libraries_root: root, library: "demo", clip: "a.json",
            edit: { segment_index: 0, word_index: 4, old_tokens: ["Lake"], new_tokens: ["Pond"] }
          )
        }.to raise_error(ArgumentError, /old_tokens does not match/)
      end
    end

    it "writes atomically via tempfile + rename" do
      with_lib do |root, lib_dir|
        write_transcript(lib_dir)
        # Existence check: there must NOT be a leftover .tmp file after a successful edit
        described_class.apply(
          libraries_root: root, library: "demo", clip: "a.json",
          edit: { segment_index: 0, word_index: 4, old_tokens: ["Creak"], new_tokens: ["Creek"] }
        )
        expect(Dir.glob(File.join(lib_dir, "transcripts", "*.tmp"))).to be_empty
      end
    end

    it "updates the correct occurrence when the same token repeats" do
      with_lib do |root, lib_dir|
        LibraryFixture.write_whisperx_transcript(lib_dir, "a.json", segments: [
          {
            start: 0.0, end: 1.0, text: " foo foo bar",
            words: [
              { word: "foo", start: 0.0, end: 0.2 },
              { word: "foo", start: 0.21, end: 0.4 },
              { word: "bar", start: 0.41, end: 1.0 }
            ]
          }
        ])

        described_class.apply(
          libraries_root: root, library: "demo", clip: "a.json",
          edit: { segment_index: 0, word_index: 1, old_tokens: ["foo"], new_tokens: ["baz"] }
        )

        data = read_transcript(lib_dir)
        expect(data["segments"][0]["words"].map { |w| w["word"] }).to eq(%w[foo baz bar])
        expect(data["segments"][0]["text"]).to eq(" foo baz bar")
      end
    end

    it "rejects negative segment_index" do
      with_lib do |root, lib_dir|
        write_transcript(lib_dir)
        expect {
          described_class.apply(
            libraries_root: root, library: "demo", clip: "a.json",
            edit: { segment_index: -1, word_index: 0, old_tokens: ["ride"], new_tokens: ["walk"] }
          )
        }.to raise_error(ArgumentError, /segment_index must be non-negative/)
      end
    end

    it "rejects clip transcript names that escape the transcripts directory" do
      with_lib do |root, lib_dir|
        write_transcript(lib_dir)
        expect {
          described_class.apply(
            libraries_root: root, library: "demo", clip: "../a.json",
            edit: { segment_index: 0, word_index: 0, old_tokens: ["ride"], new_tokens: ["walk"] }
          )
        }.to raise_error(ArgumentError, /invalid clip/)
      end
    end

    it "tolerates transcripts without a top-level word_segments array" do
      with_lib do |root, lib_dir|
        # write a payload without word_segments
        path = File.join(lib_dir, "transcripts", "a.json")
        File.write(path, JSON.pretty_generate({
          "language" => "en", "video_path" => "n/a",
          "segments" => [
            {
              "start" => 0.0, "end" => 0.5, "text" => " ride out",
              "words" => [
                { "word" => "ride", "start" => 0.0, "end" => 0.2 },
                { "word" => "out", "start" => 0.21, "end" => 0.5 }
              ]
            }
          ]
        }))

        described_class.apply(
          libraries_root: root, library: "demo", clip: "a.json",
          edit: { segment_index: 0, word_index: 0, old_tokens: ["ride"], new_tokens: ["walk"] }
        )

        data = read_transcript(lib_dir)
        expect(data["segments"][0]["text"]).to eq(" walk out")
        expect(data["segments"][0]["words"][0]["word"]).to eq("walk")
        expect(data).not_to have_key("word_segments") # we don't synthesize one we didn't get
      end
    end
  end
end
