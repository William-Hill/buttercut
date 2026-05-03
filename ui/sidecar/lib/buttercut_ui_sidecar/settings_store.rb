# frozen_string_literal: true

require "date"
require "fileutils"
require "pathname"
require "time"
require "yaml"

module ButtercutUiSidecar
  class SettingsStore
    SETTINGS_FILENAME = "settings.yaml"

    def initialize(libraries_root:, env: ENV.to_h)
      raise ArgumentError, "libraries_root required" if libraries_root.nil? || libraries_root.to_s.empty?
      @root = Pathname.new(libraries_root)
      @env = env
    end

    def api_key
      env_key = @env["ANTHROPIC_API_KEY"]
      return env_key unless env_key.nil? || env_key.empty?
      data = read_yaml
      key = data["anthropic_api_key"]
      key.nil? || key.empty? ? nil : key
    end

    def configured?
      !api_key.nil?
    end

    def write_api_key!(key)
      raise ArgumentError, "key required" if key.nil? || key.empty?
      data = read_yaml
      data["anthropic_api_key"] = key
      write_yaml(data)
    end

    private

    def settings_path
      @root.join(SETTINGS_FILENAME)
    end

    def read_yaml
      return {} unless settings_path.file?
      YAML.safe_load(settings_path.read, permitted_classes: [Date, Time], aliases: true) || {}
    end

    def write_yaml(data)
      FileUtils.mkdir_p(@root)
      tmp = settings_path.to_s + ".tmp"
      File.write(tmp, YAML.dump(data))
      File.rename(tmp, settings_path.to_s)
    end
  end
end
