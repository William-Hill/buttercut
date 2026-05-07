require 'spec_helper'
require 'tmpdir'
require 'yaml'

RSpec.describe ButterCut::BrollManifest do
  let(:valid_hash) do
    {
      "version" => 1,
      "library" => "tutorial-series",
      "roughcut" => "tutorial_ep1_20260506_120000",
      "entries" => [
        {
          "id" => "br-0001",
          "source_video" => "tutorial_01.mov",
          "start" => 42.1,
          "end" => 47.8,
          "template" => "code-callout",
          "placement" => "overlay",
          "score" => 0.84,
          "content" => {
            "command" => "git rebase -i HEAD~3",
            "caption" => "Interactive rebase, last 3 commits"
          },
          "rendered" => nil
        },
        {
          "id" => "br-0002",
          "source_video" => "tutorial_01.mov",
          "start" => 75.0,
          "end" => 80.0,
          "template" => "term-card",
          "placement" => "cutaway",
          "content" => { "term" => "rebase", "definition" => "Replay commits onto a new base" },
          "rendered" => nil
        }
      ]
    }
  end

  describe ".from_hash" do
    it "loads a valid manifest" do
      manifest = described_class.from_hash(valid_hash)
      expect(manifest.library).to eq("tutorial-series")
      expect(manifest.entries.length).to eq(2)
    end

    it "rejects a non-hash" do
      expect { described_class.from_hash("nope") }.to raise_error(ArgumentError, /hash required/)
    end
  end

  describe "round-trip" do
    it "saves and reloads identically" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "test.broll.yaml")
        described_class.from_hash(valid_hash).save(path)

        reloaded = described_class.load(path)
        expect(reloaded.to_h).to eq(valid_hash)
      end
    end

    it "loads from the canonical template" do
      template_path = File.expand_path("../templates/broll_template.yaml", __dir__)
      expect { described_class.load(template_path) }.not_to raise_error
    end
  end

  describe "validation" do
    def expect_invalid(mutation, error_pattern)
      h = Marshal.load(Marshal.dump(valid_hash))
      mutation.call(h)
      expect { described_class.from_hash(h) }.to raise_error(ArgumentError, error_pattern)
    end

    it "rejects an unknown version" do
      expect_invalid(->(h) { h["version"] = 99 }, /version/)
    end

    it "requires library" do
      expect_invalid(->(h) { h["library"] = "" }, /library required/)
    end

    it "rejects entries that are not an array" do
      expect_invalid(->(h) { h["entries"] = "nope" }, /entries must be an array/)
    end

    it "allows an empty entries list" do
      h = Marshal.load(Marshal.dump(valid_hash))
      h["entries"] = []
      expect { described_class.from_hash(h) }.not_to raise_error
    end

    it "rejects duplicate ids" do
      expect_invalid(->(h) { h["entries"][1]["id"] = "br-0001" }, /entry ids must be unique/)
    end

    it "rejects an unknown placement" do
      expect_invalid(->(h) { h["entries"][0]["placement"] = "sidebar" }, /placement.*not in/)
    end

    it "rejects end <= start" do
      expect_invalid(->(h) { h["entries"][0]["end"] = h["entries"][0]["start"] }, /end .* must be greater than start/)
    end

    it "rejects a score above 1" do
      expect_invalid(->(h) { h["entries"][0]["score"] = 1.5 }, /score must be in 0\.\.1/)
    end

    it "rejects a negative score" do
      expect_invalid(->(h) { h["entries"][0]["score"] = -0.1 }, /score must be in 0\.\.1/)
    end

    it "rejects empty content" do
      expect_invalid(->(h) { h["entries"][0]["content"] = {} }, /content must not be empty/)
    end

    it "rejects non-hash content" do
      expect_invalid(->(h) { h["entries"][0]["content"] = "string" }, /content must be a hash/)
    end

    it "rejects a missing template" do
      expect_invalid(->(h) { h["entries"][0]["template"] = "" }, /template required/)
    end

    it "treats a nil rendered field as 'not yet rendered'" do
      h = Marshal.load(Marshal.dump(valid_hash))
      h["entries"][0]["rendered"] = nil
      expect { described_class.from_hash(h) }.not_to raise_error
    end

    it "accepts a string path in rendered" do
      h = Marshal.load(Marshal.dump(valid_hash))
      h["entries"][0]["rendered"] = "broll/br-0001.mp4"
      expect { described_class.from_hash(h) }.not_to raise_error
    end

    it "rejects an empty rendered string" do
      expect_invalid(->(h) { h["entries"][0]["rendered"] = "" }, /rendered required/)
    end

    it "allows an empty roughcut string for hand-authored manifests" do
      h = Marshal.load(Marshal.dump(valid_hash))
      h["roughcut"] = ""
      expect { described_class.from_hash(h) }.not_to raise_error
    end

    it "rejects a missing roughcut key" do
      expect_invalid(->(h) { h.delete("roughcut") }, /roughcut required/)
    end

    it "rejects a nil roughcut" do
      expect_invalid(->(h) { h["roughcut"] = nil }, /roughcut required/)
    end
  end

  describe "schema v2 pip fields" do
    let(:pip_entry) do
      {
        "id" => "br-9001",
        "source_video" => "tutorial_01.mov",
        "start" => 10.0,
        "end" => 14.0,
        "template" => "code-callout",
        "placement" => "pip",
        "pip_corner" => "top_right",
        "pip_scale" => 0.33,
        "content" => { "command" => "ls" },
        "rendered" => nil
      }
    end

    let(:v2_hash) do
      {
        "version" => 2,
        "library" => "tutorial-series",
        "roughcut" => "tutorial_ep1",
        "entries" => [pip_entry]
      }
    end

    it "accepts version 2" do
      expect { described_class.from_hash(v2_hash) }.not_to raise_error
    end

    it "accepts pip entry with valid pip_corner and pip_scale" do
      expect { described_class.from_hash(v2_hash) }.not_to raise_error
    end

    it "defaults pip_corner and pip_scale to nil when omitted on a pip entry" do
      bare = pip_entry.dup
      bare.delete("pip_corner")
      bare.delete("pip_scale")
      expect { described_class.from_hash(v2_hash.merge("entries" => [bare])) }.not_to raise_error
    end

    it "rejects pip_corner outside the enum" do
      bad = pip_entry.merge("pip_corner" => "middle")
      expect {
        described_class.from_hash(v2_hash.merge("entries" => [bad]))
      }.to raise_error(ArgumentError, /pip_corner/)
    end

    it "rejects pip_scale outside 0.05..0.95" do
      bad = pip_entry.merge("pip_scale" => 1.2)
      expect {
        described_class.from_hash(v2_hash.merge("entries" => [bad]))
      }.to raise_error(ArgumentError, /pip_scale/)

      tiny = pip_entry.merge("pip_scale" => 0.01)
      expect {
        described_class.from_hash(v2_hash.merge("entries" => [tiny]))
      }.to raise_error(ArgumentError, /pip_scale/)
    end

    it "rejects pip_corner on a non-pip entry" do
      overlay_with_pip = pip_entry.merge("placement" => "overlay")
      expect {
        described_class.from_hash(v2_hash.merge("entries" => [overlay_with_pip]))
      }.to raise_error(ArgumentError, /pip_corner.*only valid.*pip/)
    end

    it "rejects pip_scale on a non-pip entry" do
      overlay_with_scale = pip_entry.merge("placement" => "cutaway").tap { |h| h.delete("pip_corner") }
      expect {
        described_class.from_hash(v2_hash.merge("entries" => [overlay_with_scale]))
      }.to raise_error(ArgumentError, /pip_scale.*only valid.*pip/)
    end

    it "accepts version 1 with a deprecation warning" do
      v1 = v2_hash.merge("version" => 1)
      expect { described_class.from_hash(v1) }.to output(/version 1.*deprecated/i).to_stderr
    end

    it "rejects unknown versions" do
      expect {
        described_class.from_hash(v2_hash.merge("version" => 99))
      }.to raise_error(ArgumentError, /version/)
    end
  end
end
