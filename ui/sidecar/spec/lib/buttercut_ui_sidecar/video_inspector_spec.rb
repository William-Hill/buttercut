require "spec_helper"
require "tmpdir"
require_relative "../../../lib/buttercut_ui_sidecar/video_inspector"

RSpec.describe ButtercutUiSidecar::VideoInspector do
  it "rejects paths that do not exist" do
    result = described_class.new.inspect(["/no/such/file.mov"])
    expect(result[:accepted]).to be_empty
    expect(result[:rejected].first[:reason]).to eq("not_found")
  end

  it "rejects non-video files", skip: !system("which ffprobe > /dev/null 2>&1") do
    Dir.mktmpdir do |dir|
      txt = File.join(dir, "notes.txt")
      File.write(txt, "hello")
      result = described_class.new.inspect([txt])
      expect(result[:rejected].first[:reason]).to eq("not_video")
    end
  end

  it "accepts a real video and returns duration_seconds + size_bytes",
     skip: !system("which ffmpeg > /dev/null 2>&1 && which ffprobe > /dev/null 2>&1") do
    Dir.mktmpdir do |dir|
      video = File.join(dir, "tiny.mp4")
      system("ffmpeg -y -loglevel error -f lavfi -i color=c=red:s=64x64:d=2 -pix_fmt yuv420p #{video}")
      result = described_class.new.inspect([video])
      expect(result[:accepted].first[:path]).to eq(video)
      expect(result[:accepted].first[:duration_seconds]).to be > 0
      expect(result[:accepted].first[:size_bytes]).to be > 0
    end
  end
end
