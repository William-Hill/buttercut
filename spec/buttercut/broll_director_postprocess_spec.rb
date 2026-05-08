require "spec_helper"
require "json"
require "buttercut/broll_director_postprocess"
require "buttercut/broll_manifest"

RSpec.describe ButterCut::BrollDirectorPostprocess do
  let(:fixtures) { File.expand_path("../fixtures/broll_director", __dir__) }
  let(:roughcut) {
    {
      "clips" => [
        { "source_video" => "tutorial_01.mov", "in" => "00:00:30.00", "out" => "00:01:00.00" },
        { "source_video" => "tutorial_01.mov", "in" => "00:01:20.00", "out" => "00:01:50.00" }
      ]
    }
  }
  let(:candidates) { JSON.parse(File.read(File.join(fixtures, "canned_model_response.json"))) }
  let(:available_templates) { [{ name: "code-callout", readme_md: "" }] }

  def call(opts = {})
    described_class.assemble(
      library_name: "sample-library",
      roughcut_stem: "sample",
      roughcut: roughcut,
      candidates: candidates,
      available_templates: available_templates,
      density: opts.fetch(:density, "medium"),
      score_threshold: opts.fetch(:score_threshold, 0.5)
    )
  end

  it "drops candidates below the score threshold, outside any clip, or with an unknown template" do
    manifest = call
    contents = manifest["entries"].map { |e| e["content"] }
    commands = contents.map { |c| c["command"] }
    expect(commands).to contain_exactly("git rebase -i HEAD~3", "git status")
  end

  it "remaps source-relative timing to rough-cut-relative timing" do
    manifest = call
    rebase = manifest["entries"].find { |e| e["content"]["command"] == "git rebase -i HEAD~3" }
    # source 35.0 - clip[0].in (30.0) = 5.0 into the cut
    expect(rebase["start"]).to eq(5.0)
    expect(rebase["end"]).to eq(10.0)
    status = manifest["entries"].find { |e| e["content"]["command"] == "git status" }
    # clip[0] is 30s long (0..30), clip[1] starts at 30 in the cut
    # source 100.0 - clip[1].in (80.0) = 20.0 into clip[1] -> 30 + 20 = 50.0 in cut
    expect(status["start"]).to eq(50.0)
    expect(status["end"]).to eq(55.0)
  end

  it "assigns sequential ids in time order" do
    manifest = call
    expect(manifest["entries"].map { |e| e["id"] }).to eq(["br-0001", "br-0002"])
    starts = manifest["entries"].map { |e| e["start"] }
    expect(starts).to eq(starts.sort)
  end

  it "applies a density budget per minute" do
    many = (0..9).map do |i|
      {
        "source_video" => "tutorial_01.mov",
        "source_start" => 30.0 + i, "source_end" => 31.0 + i,
        "template" => "code-callout", "placement" => "overlay",
        "content" => { "command" => "cmd_#{i}" },
        "score" => 0.5 + i * 0.05
      }
    end
    manifest = described_class.assemble(
      library_name: "x", roughcut_stem: "y", roughcut: roughcut,
      candidates: many, available_templates: available_templates,
      density: "low", score_threshold: 0.0
    )
    expect(manifest["entries"].length).to eq(2)  # low = 2/min, all in minute 0
    kept = manifest["entries"].map { |e| e["content"]["command"] }
    expect(kept).to contain_exactly("cmd_9", "cmd_8")
  end

  it "produces a manifest that validates via BrollManifest" do
    manifest = call
    expect { ButterCut::BrollManifest.from_hash(manifest) }.not_to raise_error
  end

  it "rejects unsupported density" do
    expect { call(density: "extreme") }.to raise_error(ArgumentError, /density/)
  end

  it "drops candidates whose content references a blacklisted term (case-insensitive)" do
    manifest = call(score_threshold: 0.5)
    expect(manifest["entries"].map { |e| e["content"]["command"] })
      .to include("git rebase -i HEAD~3", "git status")

    filtered = described_class.assemble(
      library_name: "x", roughcut_stem: "y", roughcut: roughcut,
      candidates: candidates, available_templates: available_templates,
      density: "medium", score_threshold: 0.5,
      blacklist_terms: ["REBASE"]
    )
    commands = filtered["entries"].map { |e| e["content"]["command"] }
    expect(commands).not_to include("git rebase -i HEAD~3")
    expect(commands).to include("git status")
  end

  it "applies the blacklist to terms buried in nested content (hashes and arrays)" do
    nested = [
      {
        "source_video" => "tutorial_01.mov",
        "source_start" => 35.0, "source_end" => 40.0,
        "template" => "code-callout", "placement" => "overlay",
        "content" => { "meta" => { "tags" => ["git rebase -i HEAD~3"] }, "command" => "buried" },
        "score" => 0.9, "rationale" => "buried in nested array"
      },
      {
        "source_video" => "tutorial_01.mov",
        "source_start" => 100.0, "source_end" => 105.0,
        "template" => "code-callout", "placement" => "overlay",
        "content" => { "command" => "git status", "caption" => "clean tree" },
        "score" => 0.8, "rationale" => "clean"
      }
    ]
    filtered = described_class.assemble(
      library_name: "x", roughcut_stem: "y", roughcut: roughcut,
      candidates: nested, available_templates: available_templates,
      density: "medium", score_threshold: 0.5,
      blacklist_terms: ["REBASE"]
    )
    commands = filtered["entries"].map { |e| e["content"]["command"] }
    expect(commands).not_to include("buried")
    expect(commands).to include("git status")
  end

  it "rejects a non-array blacklist_terms" do
    expect {
      described_class.assemble(
        library_name: "x", roughcut_stem: "y", roughcut: roughcut,
        candidates: candidates, available_templates: available_templates,
        density: "medium", score_threshold: 0.5, blacklist_terms: "rebase"
      )
    }.to raise_error(ArgumentError, /blacklist_terms/)
  end

  it "produces monotonically non-decreasing entry counts as density rises (acceptance)" do
    many = (0..15).map do |i|
      {
        "source_video" => "tutorial_01.mov",
        "source_start" => 30.0 + (i * 0.5), "source_end" => 30.5 + (i * 0.5),
        "template" => "code-callout", "placement" => "overlay",
        "content" => { "command" => "cmd_#{i}" },
        "score" => 0.6 + (i % 5) * 0.05
      }
    end
    counts = ["low", "medium", "high"].map do |d|
      m = described_class.assemble(
        library_name: "x", roughcut_stem: "y", roughcut: roughcut,
        candidates: many, available_templates: available_templates,
        density: d, score_threshold: 0.0
      )
      m["entries"].length
    end
    expect(counts).to eq(counts.sort)
    expect(counts.first).to be < counts.last
    expect(counts[0]).to be <= 2
    expect(counts[1]).to be <= 4
    expect(counts[2]).to be <= 8
  end

  it "drops code-callout candidates whose command looks like verbal-form leakage" do
    leaky = [
      {
        "source_video" => "tutorial_01.mov",
        "source_start" => 35.0, "source_end" => 40.0,
        "template" => "code-callout", "placement" => "overlay",
        "content" => { "command" => "get rebase dash i tilde three" },
        "score" => 0.9, "rationale" => "verbal leakage"
      },
      {
        "source_video" => "tutorial_01.mov",
        "source_start" => 100.0, "source_end" => 105.0,
        "template" => "code-callout", "placement" => "overlay",
        "content" => { "command" => "git rebase -i HEAD~3" },
        "score" => 0.9, "rationale" => "valid"
      }
    ]
    manifest = described_class.assemble(
      library_name: "x", roughcut_stem: "y", roughcut: roughcut,
      candidates: leaky, available_templates: available_templates,
      density: "medium", score_threshold: 0.5
    )
    commands = manifest["entries"].map { |e| e["content"]["command"] }
    expect(commands).to eq(["git rebase -i HEAD~3"])
  end

  it "keeps short alphabetic commands (e.g. `ls`, `git status`) and vocabulary matches" do
    cands = [
      { "source_video" => "tutorial_01.mov", "source_start" => 35.0, "source_end" => 40.0,
        "template" => "code-callout", "placement" => "overlay",
        "content" => { "command" => "ls" }, "score" => 0.9, "rationale" => "" },
      { "source_video" => "tutorial_01.mov", "source_start" => 36.0, "source_end" => 41.0,
        "template" => "code-callout", "placement" => "overlay",
        "content" => { "command" => "git status" }, "score" => 0.9, "rationale" => "" },
      { "source_video" => "tutorial_01.mov", "source_start" => 100.0, "source_end" => 105.0,
        "template" => "code-callout", "placement" => "overlay",
        "content" => { "command" => "npm install lodash react" }, "score" => 0.9, "rationale" => "" }
    ]
    manifest = described_class.assemble(
      library_name: "x", roughcut_stem: "y", roughcut: roughcut,
      candidates: cands, available_templates: available_templates,
      density: "medium", score_threshold: 0.5,
      code_vocabulary: ["npm"]
    )
    commands = manifest["entries"].map { |e| e["content"]["command"] }
    expect(commands).to contain_exactly("ls", "git status", "npm install lodash react")
  end

  it "rejects non-numeric or out-of-range score_threshold instead of coercing to 0.0" do
    expect { call(score_threshold: nil) }.to raise_error(ArgumentError, /score_threshold/)
    expect { call(score_threshold: "abc") }.to raise_error(ArgumentError, /score_threshold/)
    expect { call(score_threshold: -0.1) }.to raise_error(ArgumentError, /score_threshold/)
    expect { call(score_threshold: 1.1) }.to raise_error(ArgumentError, /score_threshold/)
    expect { call(score_threshold: Float::INFINITY) }.to raise_error(ArgumentError, /score_threshold/)
  end
end
