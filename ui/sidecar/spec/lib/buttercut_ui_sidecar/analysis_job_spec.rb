require "spec_helper"
require_relative "../../../lib/buttercut_ui_sidecar/analysis_job"

RSpec.describe ButtercutUiSidecar::AnalysisJob do
  it "starts uncanceled" do
    job = described_class.new(id: "j1", library: "demo")
    expect(job.canceled?).to be false
  end

  it "cancel! flips the token and is idempotent" do
    job = described_class.new(id: "j1", library: "demo")
    job.cancel!
    job.cancel!
    expect(job.canceled?).to be true
  end

  it "registers and signals child PIDs on cancel" do
    job = described_class.new(id: "j1", library: "demo")
    pid = Process.spawn("sleep", "60")
    job.register_pid(pid)
    job.cancel!
    # Reap the child to avoid zombies; Process.wait blocks until done.
    Process.wait(pid)
    expect($?.success?).to be_falsey
  end

  it "registers and aborts in-flight handles on cancel" do
    job = described_class.new(id: "j1", library: "demo")
    aborted = false
    handle = Object.new
    handle.define_singleton_method(:abort!) { aborted = true }
    job.register_abortable(handle)
    job.cancel!
    expect(aborted).to be true
  end
end
