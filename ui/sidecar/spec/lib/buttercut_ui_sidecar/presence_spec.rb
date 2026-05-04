# frozen_string_literal: true

require "spec_helper"
require_relative "../../../lib/buttercut_ui_sidecar/presence"

RSpec.describe ButtercutUiSidecar::Presence do
  it "is false for nil and empty string" do
    expect(described_class.present?(nil)).to be false
    expect(described_class.present?("")).to be false
  end

  it "treats whitespace-only strings as present (matches path / YAML field checks)" do
    expect(described_class.present?("  ")).to be true
  end

  it "is true for non-empty strings and other values" do
    expect(described_class.present?("x")).to be true
    expect(described_class.present?(0)).to be true
  end
end
