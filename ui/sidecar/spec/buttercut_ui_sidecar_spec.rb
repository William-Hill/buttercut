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

  describe "has_api_key" do
    it "returns false when no key is configured" do
      prev = ENV.delete("ANTHROPIC_API_KEY")
      begin
        Dir.mktmpdir do |root|
          result = call(root, "has_api_key")
          expect(result["result"]).to eq({ "configured" => false })
        end
      ensure
        ENV["ANTHROPIC_API_KEY"] = prev if prev
      end
    end
  end

  describe "start_analysis" do
    it "returns missing_api_key when no Anthropic key is configured" do
      prev = ENV.delete("ANTHROPIC_API_KEY")
      begin
        Dir.mktmpdir do |root|
          result = call(root, "start_analysis", { library: "demo" })
          expect(result["error"]["code"]).to eq(-32_010)
          expect(result["error"]["message"]).to eq("missing_api_key")
        end
      ensure
        ENV["ANTHROPIC_API_KEY"] = prev if prev
      end
    end
  end

  describe "create_library" do
    it "creates a library and returns its slug" do
      Dir.mktmpdir do |root|
        Dir.mktmpdir do |footage|
          v = File.join(footage, "a.mp4")
          File.write(v, "x")
          result = call(root, "create_library", {
            name: "My Lib",
            language: "English",
            language_code: "en",
            refinement: true,
            videos: [{ path: v, duration_seconds: 5 }]
          })
          expect(result["result"]).to eq({ "name" => "my-lib" })
          expect(File.file?(File.join(root, "my-lib", "library.yaml"))).to be true
        end
      end
    end
  end

  describe "inspect_video_paths" do
    it "rejects nonexistent paths" do
      Dir.mktmpdir do |root|
        result = call(root, "inspect_video_paths", { paths: ["/no/such/file.mov"] })
        expect(result["result"]["rejected"].first["reason"]).to eq("not_found")
      end
    end
  end

  describe "get_or_generate_thumbnail" do
    it "returns the cached path on second call without re-shelling out" do
      Dir.mktmpdir do |root|
        lib = LibraryFixture.build(root, name: "demo",
          videos: [{ path: "/x/a.mp4" }])

        # Pre-place the cached thumbnail to avoid needing ffmpeg in CI.
        cached = File.join(lib, "thumbnails", "a.jpg")
        FileUtils.mkdir_p(File.dirname(cached))
        File.write(cached, "fake-jpg-bytes")

        r = call(root, "get_or_generate_thumbnail", { library: "demo", video: "a.mp4" })["result"]
        expect(r["path"]).to eq(cached)
      end
    end

    it "shells out to ffmpeg on cache miss when ffmpeg is available", skip: !system("which ffmpeg > /dev/null 2>&1") do
      Dir.mktmpdir do |root|
        # Create a 1-second silent test video using ffmpeg.
        videos_root = File.join(root, "footage")
        FileUtils.mkdir_p(videos_root)
        video = File.join(videos_root, "tiny.mp4")
        system("ffmpeg -y -loglevel error -f lavfi -i color=c=red:s=64x64:d=2 -pix_fmt yuv420p #{video}")

        LibraryFixture.build(root, name: "demo", videos: [{ path: video }])
        r = call(root, "get_or_generate_thumbnail", { library: "demo", video: "tiny.mp4" })["result"]

        expect(File.file?(r["path"])).to be true
        expect(File.size(r["path"])).to be > 0
      end
    end

    it "returns an RPC error when the source video file is missing" do
      Dir.mktmpdir do |root|
        LibraryFixture.build(root, name: "demo",
          videos: [{ path: "/nonexistent/missing.mp4" }])
        r = call(root, "get_or_generate_thumbnail", { library: "demo", video: "missing.mp4" })
        expect(r["error"]["message"]).to match(/missing\.mp4/)
      end
    end
  end

  describe "apply_transcript_edit" do
    it "applies a 1->1 edit and returns edit_count" do
      Dir.mktmpdir do |root|
        lib_dir = LibraryFixture.build(root, name: "demo",
          videos: [{ path: "/x/a.mp4", transcript: "a.json" }])
        LibraryFixture.write_whisperx_transcript(lib_dir, "a.json", segments: [
          { start: 0.0, end: 0.5, text: " hi Tenderlohn",
            words: [
              { word: "hi", start: 0.0, end: 0.1 },
              { word: "Tenderlohn", start: 0.11, end: 0.5 }
            ] }
        ])

        result = call(root, "apply_transcript_edit", {
          library: "demo", clip: "a.json",
          edit: { segment_index: 0, word_index: 1, old_tokens: ["Tenderlohn"], new_tokens: ["Tenderloin"] }
        })
        expect(result["error"]).to be_nil
        expect(result["result"]["edit_count"]).to eq(1)
      end
    end

    it "returns RPC error code -32013 token_count_violation on bad edit" do
      Dir.mktmpdir do |root|
        lib_dir = LibraryFixture.build(root, name: "demo",
          videos: [{ path: "/x/a.mp4", transcript: "a.json" }])
        LibraryFixture.write_whisperx_transcript(lib_dir, "a.json", segments: [
          { start: 0.0, end: 0.5, text: " hi there",
            words: [
              { word: "hi", start: 0.0, end: 0.1 },
              { word: "there", start: 0.11, end: 0.5 }
            ] }
        ])

        result = call(root, "apply_transcript_edit", {
          library: "demo", clip: "a.json",
          edit: { segment_index: 0, word_index: 0, old_tokens: ["hi"], new_tokens: ["hi", "there"] }
        })
        expect(result["error"]["code"]).to eq(-32013)
        expect(result["error"]["message"]).to match(/token_count_violation/)
      end
    end
  end

  describe "find_transcript_matches" do
    it "returns library-wide matches" do
      Dir.mktmpdir do |root|
        lib_dir = LibraryFixture.build(root, name: "demo",
          videos: [{ path: "/x/a.mp4", transcript: "a.json" }])
        LibraryFixture.write_whisperx_transcript(lib_dir, "a.json", segments: [
          { start: 0.0, end: 0.3, text: " hi Tenderlohn",
            words: [
              { word: "hi", start: 0.0, end: 0.1 },
              { word: "Tenderlohn", start: 0.11, end: 0.3 }
            ] }
        ])

        result = call(root, "find_transcript_matches", {
          library: "demo", tokens: ["Tenderlohn"], scope: "library"
        })["result"]
        expect(result["matches"].length).to eq(1)
        expect(result["matches"].first["clip"]).to eq("a.json")
      end
    end
  end

  describe "apply_library_replace" do
    it "replaces matches across the library and returns counts" do
      Dir.mktmpdir do |root|
        lib_dir = LibraryFixture.build(root, name: "demo",
          videos: [{ path: "/x/a.mp4", transcript: "a.json" }])
        LibraryFixture.write_whisperx_transcript(lib_dir, "a.json", segments: [
          { start: 0.0, end: 0.3, text: " hi Tenderlohn",
            words: [
              { word: "hi", start: 0.0, end: 0.1 },
              { word: "Tenderlohn", start: 0.11, end: 0.3 }
            ] }
        ])

        result = call(root, "apply_library_replace", {
          library: "demo", old_tokens: ["Tenderlohn"], new_tokens: ["Tenderloin"], trust: true
        })["result"]
        expect(result["edit_count"]).to eq(1)
        expect(result["affected_clips"]).to eq(["a.json"])

        yaml = YAML.safe_load(File.read(File.join(lib_dir, "library.yaml")))
        expect(yaml["user_context"]).to include("Tenderloin")
      end
    end
  end
end
