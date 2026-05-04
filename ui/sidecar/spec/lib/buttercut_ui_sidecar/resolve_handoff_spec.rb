# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require_relative "../../../lib/buttercut_ui_sidecar/resolve_handoff"

RSpec.describe ButtercutUiSidecar::ResolveHandoff do
  it "maps resolve-not-running to actionable error" do
    allow(Open3).to receive(:capture2).with("pgrep", "-x", "Resolve").and_return(["", instance_double(Process::Status, success?: false)])
    expect {
      described_class.new.send(:ensure_resolve_running!)
    }.to raise_error(/resolve_not_running/)
  end

  it "raises timeline mismatch with expected/active names" do
    Dir.mktmpdir do |root|
      apply_path = File.join(root, "cut_apply.py")
      recipe_path = File.join(root, "cut.recipe.json")
      File.write(apply_path, "#!/usr/bin/env python3\n")
      File.write(recipe_path, JSON.dump({ version: 1, timeline: "Expected TL" }))

      running = instance_double(Process::Status, success?: true)
      ok = instance_double(Process::Status, success?: true)
      allow(Open3).to receive(:capture2).with("pgrep", "-x", "Resolve").and_return(["123\n", running])
      allow(Open3).to receive(:capture2e).with("open", "-a", "DaVinci Resolve").and_return(["", ok])
      allow(Open3).to receive(:capture2e).with("python3", "-c", described_class::PRECHECK, "Expected TL").and_return([
        JSON.dump({ ok: false, error: "resolve_timeline_target_mismatch", expected_timeline: "Expected TL", active_timeline: "Other TL" }),
        ok
      ])

      expect {
        described_class.new.run(apply_path: apply_path, recipe_path: recipe_path)
      }.to raise_error(/resolve_timeline_target_mismatch/)
    end
  end

  it "raises resolve_launch_failed when open -a DaVinci Resolve fails" do
    Dir.mktmpdir do |root|
      apply_path = File.join(root, "cut_apply.py")
      recipe_path = File.join(root, "cut.recipe.json")
      File.write(apply_path, "#!/usr/bin/env python3\n")
      File.write(recipe_path, JSON.dump({ version: 1, timeline: "TL" }))

      running = instance_double(Process::Status, success?: true)
      open_fail = instance_double(Process::Status, success?: false)
      allow(Open3).to receive(:capture2).with("pgrep", "-x", "Resolve").and_return(["123\n", running])
      allow(Open3).to receive(:capture2e).with("open", "-a", "DaVinci Resolve").and_return(["Unable to find application named DaVinci Resolve", open_fail])

      expect {
        described_class.new.run(apply_path: apply_path, recipe_path: recipe_path)
      }.to raise_error(/resolve_launch_failed/)
    end
  end
end
