require "spec_helper"
require "json"
require "stringio"
require "tmpdir"
require_relative "fixtures/library_fixture"
require_relative "../buttercut_ui_sidecar"

RSpec.describe ButtercutUiSidecar do
  def call(libraries_root, method, params = {})
    io_in = StringIO.new(JSON.generate(jsonrpc: "2.0", id: 1, method: method, params: params) + "\n")
    io_out = StringIO.new
    ButtercutUiSidecar.run(libraries_root: libraries_root, io_in: io_in, io_out: io_out)
    JSON.parse(io_out.string.lines.last)
  end

  describe "get_library" do
    it "returns library metadata, video list, has_* flags, and the longest common parent" do
      Dir.mktmpdir do |root|
        videos_root = File.join(root, "footage")
        FileUtils.mkdir_p(videos_root)
        video_a = File.join(videos_root, "a.mp4")
        video_b = File.join(videos_root, "b.mp4")
        File.write(video_a, "x")
        File.write(video_b, "x")

        lib = LibraryFixture.build(root,
          name: "demo",
          footage_summary: "Demo footage.",
          videos: [
            { path: video_a, duration: "00:00:10", transcript: "a.json", visual_transcript: "visual_a.json", summary: "summary_a.md" },
            { path: video_b, duration: "00:00:20", transcript: "", visual_transcript: "visual_b.json", summary: "" }
          ])

        result = call(root, "get_library", { name: "demo" })

        expect(result["error"]).to be_nil
        r = result["result"]
        expect(r["name"]).to eq("demo")
        expect(r["footage_summary"]).to eq("Demo footage.")
        expect(r["video_paths_root"]).to eq(videos_root)
        expect(r["videos"].length).to eq(2)

        v0 = r["videos"][0]
        expect(v0["filename"]).to eq("a.mp4")
        expect(v0["path"]).to eq(video_a)
        expect(v0["duration_seconds"]).to eq(10)
        expect(v0["has_audio_transcript"]).to be true
        expect(v0["has_visual_transcript"]).to be true
        expect(v0["has_summary"]).to be true

        v1 = r["videos"][1]
        expect(v1["filename"]).to eq("b.mp4")
        expect(v1["duration_seconds"]).to eq(20)
        expect(v1["has_audio_transcript"]).to be false
        expect(v1["has_visual_transcript"]).to be true
        expect(v1["has_summary"]).to be false
      end
    end

    it "returns an RPC error when the library does not exist" do
      Dir.mktmpdir do |root|
        result = call(root, "get_library", { name: "missing" })
        expect(result["error"]).not_to be_nil
        expect(result["error"]["message"]).to match(/missing/)
      end
    end
  end

  describe "get_clip_transcripts" do
    it "returns audio json, visual json, and summary text when all present" do
      Dir.mktmpdir do |root|
        lib = LibraryFixture.build(root, name: "demo",
          videos: [{ path: "/x/a.mp4", transcript: "a.json", visual_transcript: "visual_a.json", summary: "summary_a.md" }])
        LibraryFixture.write_audio_transcript(lib, "a.json", segments: [{ start: 0, end: 1, text: "hi" }])
        LibraryFixture.write_visual_transcript(lib, "visual_a.json", segments: [{ start: 0, end: 1, visual: "scene" }])
        LibraryFixture.write_summary(lib, "summary_a.md", body: "Overview.")

        r = call(root, "get_clip_transcripts", { library: "demo", video: "a.mp4" })["result"]
        expect(r["audio"]["segments"].first["text"]).to eq("hi")
        expect(r["visual"]["segments"].first["visual"]).to eq("scene")
        expect(r["summary"]).to eq("Overview.")
      end
    end

    it "returns null for any missing artifact" do
      Dir.mktmpdir do |root|
        LibraryFixture.build(root, name: "demo",
          videos: [{ path: "/x/b.mp4" }])
        r = call(root, "get_clip_transcripts", { library: "demo", video: "b.mp4" })["result"]
        expect(r["audio"]).to be_nil
        expect(r["visual"]).to be_nil
        expect(r["summary"]).to be_nil
      end
    end

    it "returns an RPC error when the video filename is not in the library" do
      Dir.mktmpdir do |root|
        LibraryFixture.build(root, name: "demo", videos: [{ path: "/x/a.mp4" }])
        r = call(root, "get_clip_transcripts", { library: "demo", video: "missing.mp4" })
        expect(r["error"]["message"]).to match(/missing\.mp4/)
      end
    end
  end
end
