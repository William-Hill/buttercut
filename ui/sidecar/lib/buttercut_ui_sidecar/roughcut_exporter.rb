# frozen_string_literal: true

require "open3"
require "pathname"

module ButtercutUiSidecar
  class RoughcutExporter
    FORMATS = {
      "fcpx" => { editor: "fcpx", ext: ".fcpxml" },
      "premiere" => { editor: "premiere", ext: ".xml" },
      "resolve" => { editor: "resolve", ext: ".xml" }
    }.freeze

    def initialize(repo_root:)
      raise ArgumentError, "repo_root required" if repo_root.nil? || repo_root.to_s.empty?

      @repo_root = Pathname.new(repo_root)
    end

    def export(yaml_path:, format:, filename: nil)
      yaml = Pathname.new(yaml_path.to_s).expand_path
      raise ArgumentError, "yaml not found: #{yaml}" unless yaml.file?

      fmt = FORMATS.fetch(format.to_s.strip.downcase) do
        raise ArgumentError, "unsupported format: #{format}"
      end

      stem = pick_stem(yaml: yaml, filename: filename)
      xml_path = yaml.parent.join("#{stem}#{fmt[:ext]}")
      run_export!(yaml_path: yaml, xml_path: xml_path, editor: fmt[:editor])
      xml_base = xml_path.to_s.sub(/\.[^.]+\z/, "")
      recipe_path = Pathname.new("#{xml_base}.recipe.json")
      apply_path = Pathname.new("#{xml_base}_apply.py")
      missing = [xml_path, recipe_path, apply_path].reject(&:file?)
      raise "missing_artifacts: #{missing.map(&:to_s).join(', ')}" unless missing.empty?

      {
        yaml_path: yaml.to_s,
        xml_path: xml_path.to_s,
        recipe_path: recipe_path.to_s,
        apply_path: apply_path.to_s,
        format: format.to_s.strip.downcase
      }
    end

    private

    def pick_stem(yaml:, filename:)
      candidate = filename.to_s.strip
      return yaml.basename(".yaml").to_s if candidate.empty?

      candidate = File.basename(candidate)
      candidate = candidate.sub(/\.[^.]+\z/, "")
      raise ArgumentError, "filename required" if candidate.empty?

      candidate
    end

    def run_export!(yaml_path:, xml_path:, editor:)
      script = @repo_root.join(".claude/skills/roughcut/export_to_fcpxml.rb")
      raise "export script missing: #{script}" unless script.file?

      gemfile = @repo_root.join("Gemfile").to_s
      cmd = ["bundle", "exec", "ruby", script.to_s, yaml_path.to_s, xml_path.to_s, editor]
      out, status = Dir.chdir(@repo_root.to_s) do
        Open3.capture2e({ "BUNDLE_GEMFILE" => gemfile }, *cmd)
      end
      raise "export_failed: #{out.to_s.strip}" unless status.success?
    end
  end
end
