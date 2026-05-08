require "spec_helper"
require "tmpdir"
require "fileutils"
require "yaml"
require "buttercut/broll_director_inputs"

RSpec.describe ButterCut::BrollDirectorInputs do
  let(:fixtures) { File.expand_path("../fixtures/broll_director", __dir__) }
  let(:lib_dir) { File.join(fixtures, "sample_library") }
  let(:roughcut_path) { File.join(lib_dir, "roughcuts", "sample.yaml") }
  let(:hyperframes_dir) { File.expand_path("../../hyperframes", __dir__) }

  it "gathers everything the director prompt needs" do
    result = described_class.gather(
      library_dir: lib_dir,
      roughcut_path: roughcut_path,
      hyperframes_dir: hyperframes_dir
    )

    expect(result[:library_name]).to eq("sample-library")
    expect(result[:roughcut_stem]).to eq("sample")
    expect(result[:roughcut]["clips"].length).to eq(2)
    expect(result[:theme]["template_set"]).to eq("tutorial-dark")

    sources = result[:source_videos]
    expect(sources.keys).to contain_exactly("tutorial_01.mov")
    src = sources["tutorial_01.mov"]
    expect(src[:audio_transcript]["segments"].first["text"]).to include("git rebase")
    expect(src[:visual_transcript]["frames"].length).to eq(5)
    expect(src[:summary]).to include("git rebase")

    templates = result[:available_templates]
    template_names = templates.map { |t| t[:name] }
    expect(template_names).to include("code-callout")
    callout = templates.find { |t| t[:name] == "code-callout" }
    expect(callout[:readme_md]).to be_a(String)
    expect(callout[:readme_md]).not_to be_empty
  end

  it "raises if a referenced source_video is missing transcripts in library.yaml" do
    Dir.mktmpdir do |tmp|
      bad_lib = File.join(tmp, "lib")
      FileUtils.mkdir_p(File.join(bad_lib, "roughcuts"))
      File.write(File.join(bad_lib, "library.yaml"), {
        "library_name" => "x",
        "theme" => {},
        "videos" => [{ "path" => "/x/tutorial_01.mov" }]
      }.to_yaml)
      File.write(File.join(bad_lib, "roughcuts", "r.yaml"), {
        "clips" => [{ "source_video" => "tutorial_01.mov", "in" => "00:00:00.00", "out" => "00:00:05.00" }]
      }.to_yaml)

      expect {
        described_class.gather(
          library_dir: bad_lib,
          roughcut_path: File.join(bad_lib, "roughcuts", "r.yaml"),
          hyperframes_dir: hyperframes_dir
        )
      }.to raise_error(ArgumentError, /missing transcripts.*tutorial_01\.mov/i)
    end
  end
end
