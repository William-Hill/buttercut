# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "yaml"
require_relative "../../../lib/buttercut_ui_sidecar/roughcut_exporter"

RSpec.describe ButtercutUiSidecar::RoughcutExporter do
  def repo_root
    File.expand_path("../../../../../", __dir__)
  end

  it "exports using requested format and filename stem" do
    Dir.mktmpdir do |root|
      yaml_path = File.join(root, "roughcuts", "roughcut_ui_20260504_120000.yaml")
      FileUtils.mkdir_p(File.dirname(yaml_path))
      File.write(yaml_path, YAML.dump("clips" => []))

      status = instance_double(Process::Status, success?: true)
      allow(Open3).to receive(:capture2e) do
        base = File.join(root, "roughcuts", "delivery_cut")
        File.write("#{base}.xml", "<x/>")
        File.write("#{base}.recipe.json", "{}")
        File.write("#{base}_apply.py", "#!/usr/bin/env python3\n")
        ["ok", status]
      end

      result = described_class.new(repo_root: repo_root).export(
        yaml_path: yaml_path,
        format: "resolve",
        filename: "delivery_cut"
      )

      expect(result[:xml_path]).to end_with("/roughcuts/delivery_cut.xml")
      expect(result[:recipe_path]).to end_with("/roughcuts/delivery_cut.recipe.json")
      expect(result[:apply_path]).to end_with("/roughcuts/delivery_cut_apply.py")
      expect(Open3).to have_received(:capture2e)
    end
  end

  it "uses .fcpxml for fcpx format" do
    Dir.mktmpdir do |root|
      yaml_path = File.join(root, "roughcuts", "roughcut_ui_20260504_120000.yaml")
      FileUtils.mkdir_p(File.dirname(yaml_path))
      File.write(yaml_path, YAML.dump("clips" => []))

      status = instance_double(Process::Status, success?: true)
      allow(Open3).to receive(:capture2e) do
        base = File.join(root, "roughcuts", "roughcut_ui_20260504_120000")
        File.write("#{base}.fcpxml", "<x/>")
        File.write("#{base}.recipe.json", "{}")
        File.write("#{base}_apply.py", "#!/usr/bin/env python3\n")
        ["ok", status]
      end

      result = described_class.new(repo_root: repo_root).export(
        yaml_path: yaml_path,
        format: "fcpx"
      )

      expect(result[:xml_path]).to end_with(".fcpxml")
    end
  end
end
