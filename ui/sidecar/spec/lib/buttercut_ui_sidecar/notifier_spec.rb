require "spec_helper"
require "stringio"
require "json"
require_relative "../../../lib/buttercut_ui_sidecar/notifier"

RSpec.describe ButtercutUiSidecar::Notifier do
  it "writes a JSON-RPC 2.0 notification (no id) and flushes" do
    io = StringIO.new
    described_class.new(io: io).notify("file_started", job_id: "j1", video: "a.mp4", stage: "transcribe")

    line = io.string.lines.last
    payload = JSON.parse(line)
    expect(payload["jsonrpc"]).to eq("2.0")
    expect(payload).not_to have_key("id")
    expect(payload["method"]).to eq("file_started")
    expect(payload["params"]).to include("job_id" => "j1", "video" => "a.mp4", "stage" => "transcribe")
    expect(payload["params"]).to have_key("ts")
  end

  it "is safe to call concurrently — lines are not interleaved" do
    io = StringIO.new
    notifier = described_class.new(io: io)
    threads = 16.times.map do |i|
      Thread.new { 50.times { notifier.notify("ping", n: i) } }
    end
    threads.each(&:join)

    io.string.each_line do |line|
      expect { JSON.parse(line) }.not_to raise_error
    end
  end
end
