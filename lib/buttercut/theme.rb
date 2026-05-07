require 'yaml'

class ButterCut
  class Theme
    VALID_MOTION = %w[snappy smooth minimal].freeze
    PRESET_CACHE = {}

    def self.resolve(library_theme:, themes_dir:)
      new(library_theme: library_theme, themes_dir: themes_dir).resolve
    end

    def initialize(library_theme:, themes_dir:)
      raise ArgumentError, "library_theme hash required" unless library_theme.is_a?(Hash)
      raise ArgumentError, "themes_dir required" if themes_dir.nil? || themes_dir.to_s.empty?

      @library_theme = stringify_keys(library_theme)
      @themes_dir = themes_dir
    end

    def resolve
      preset = load_preset
      tokens = preset.merge(@library_theme)
      tokens.delete('template_set')
      validate_motion!(tokens)
      tokens
    end

    private

    def load_preset
      template_set = @library_theme['template_set']
      if template_set.nil? || template_set.to_s.empty?
        raise ArgumentError, "library_theme must include 'template_set'"
      end

      path = File.join(@themes_dir, "#{template_set}.yaml")
      PRESET_CACHE[path] ||= begin
        data = YAML.load_file(path)
        raise ArgumentError, "theme preset #{path} must be a hash" unless data.is_a?(Hash)
        data
      end
    rescue Errno::ENOENT
      raise ArgumentError, "theme preset not found: #{path}"
    end

    def validate_motion!(tokens)
      motion = tokens['motion']
      return if motion.nil? # presets ship with motion; library may omit
      unless VALID_MOTION.include?(motion)
        raise ArgumentError, "motion must be one of #{VALID_MOTION.inspect}, got #{motion.inspect}"
      end
    end

    def stringify_keys(hash)
      hash.each_with_object({}) { |(k, v), out| out[k.to_s] = v }
    end
  end
end
