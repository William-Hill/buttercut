require "spec_helper"
require_relative "../../../lib/buttercut_ui_sidecar/limits"

RSpec.describe ButtercutUiSidecar::Limits do
  it "matches the values declared in the SKILL.md files" do
    expect(described_class::TRANSCRIBE_PARALLELISM).to eq(2)
    expect(described_class::ANALYZE_PARALLELISM).to eq(8)
    expect(described_class::SUMMARIZE_PARALLELISM).to eq(10)
  end
end
