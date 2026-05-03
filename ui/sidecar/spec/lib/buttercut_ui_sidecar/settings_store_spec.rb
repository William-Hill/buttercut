require "spec_helper"
require "tmpdir"
require "yaml"
require_relative "../../../lib/buttercut_ui_sidecar/settings_store"

RSpec.describe ButtercutUiSidecar::SettingsStore do
  it "prefers ENV over the YAML file" do
    Dir.mktmpdir do |root|
      File.write(File.join(root, "settings.yaml"), YAML.dump("anthropic_api_key" => "from-yaml"))
      store = described_class.new(libraries_root: root, env: { "ANTHROPIC_API_KEY" => "from-env" })
      expect(store.api_key).to eq("from-env")
    end
  end

  it "falls back to settings.yaml when ENV is unset" do
    Dir.mktmpdir do |root|
      File.write(File.join(root, "settings.yaml"), YAML.dump("anthropic_api_key" => "from-yaml"))
      store = described_class.new(libraries_root: root, env: {})
      expect(store.api_key).to eq("from-yaml")
    end
  end

  it "returns nil when neither is set" do
    Dir.mktmpdir do |root|
      store = described_class.new(libraries_root: root, env: {})
      expect(store.api_key).to be_nil
    end
  end

  it "writes the key to settings.yaml without clobbering other fields" do
    Dir.mktmpdir do |root|
      File.write(File.join(root, "settings.yaml"), YAML.dump("editor" => "fcpx", "whisper_model" => "small"))
      store = described_class.new(libraries_root: root, env: {})
      store.write_api_key!("sk-abc")

      data = YAML.safe_load(File.read(File.join(root, "settings.yaml")))
      expect(data["editor"]).to eq("fcpx")
      expect(data["whisper_model"]).to eq("small")
      expect(data["anthropic_api_key"]).to eq("sk-abc")
    end
  end

  it "creates settings.yaml when missing" do
    Dir.mktmpdir do |root|
      store = described_class.new(libraries_root: root, env: {})
      store.write_api_key!("sk-xyz")
      data = YAML.safe_load(File.read(File.join(root, "settings.yaml")))
      expect(data["anthropic_api_key"]).to eq("sk-xyz")
    end
  end

  it "configured? reflects whether a key is available" do
    Dir.mktmpdir do |root|
      empty = described_class.new(libraries_root: root, env: {})
      expect(empty.configured?).to be false
      configured = described_class.new(libraries_root: root, env: { "ANTHROPIC_API_KEY" => "x" })
      expect(configured.configured?).to be true
    end
  end
end
