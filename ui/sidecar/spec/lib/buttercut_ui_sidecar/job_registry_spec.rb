require "spec_helper"
require_relative "../../../lib/buttercut_ui_sidecar/job_registry"

RSpec.describe ButtercutUiSidecar::JobRegistry do
  it "stores, retrieves, and removes by job_id" do
    registry = described_class.new
    registry.put("j1", :payload)
    expect(registry.get("j1")).to eq(:payload)
    registry.delete("j1")
    expect(registry.get("j1")).to be_nil
  end

  it "is concurrent-safe" do
    registry = described_class.new
    threads = 32.times.map do |i|
      Thread.new { registry.put("j#{i}", i) }
    end
    threads.each(&:join)
    32.times { |i| expect(registry.get("j#{i}")).to eq(i) }
  end
end
