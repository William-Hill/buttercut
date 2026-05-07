require 'yaml'
require 'date'

class ButterCut
  # B-roll manifest emitted by the director and consumed by the render skill
  # and roughcut integration. One entry per generated graphic. See
  # templates/broll_template.yaml for the canonical schema example.
  class BrollManifest
    SCHEMA_VERSION = 2
    SUPPORTED_VERSIONS = [1, 2].freeze

    PLACEMENTS = %w[overlay cutaway pip].freeze
    PIP_CORNERS = %w[top_right top_left bottom_right bottom_left].freeze
    PIP_SCALE_MIN = 0.05
    PIP_SCALE_MAX = 0.95

    def self.from_hash(hash)
      raise ArgumentError, "manifest hash required" unless hash.is_a?(Hash)

      new(
        version: hash["version"],
        library: hash["library"],
        roughcut: hash["roughcut"],
        entries: hash["entries"]
      )
    end

    def self.load(path)
      from_hash(YAML.load_file(path, permitted_classes: [Date, Time, Symbol]))
    end

    def initialize(version:, library:, roughcut:, entries:)
      @version = version
      @library = library
      @roughcut = roughcut
      @entries = entries

      validate!
      warn_if_legacy_version!
    end

    attr_reader :version, :library, :roughcut, :entries

    def to_h
      {
        "version" => @version,
        "library" => @library,
        "roughcut" => @roughcut,
        "entries" => @entries
      }
    end

    def save(path)
      File.write(path, to_h.to_yaml)
    end

    private

    def validate!
      validate_version!
      validate_string!(@library, "library")
      unless @roughcut.is_a?(String)
        raise ArgumentError, "roughcut required (string, may be empty); got #{@roughcut.inspect}"
      end
      validate_entries!
    end

    def validate_version!
      unless SUPPORTED_VERSIONS.include?(@version)
        raise ArgumentError, "version must be one of #{SUPPORTED_VERSIONS.inspect}, got #{@version.inspect}"
      end
    end

    def warn_if_legacy_version!
      return unless @version == 1
      warn "[BrollManifest] version 1 is deprecated; please upgrade to version #{SCHEMA_VERSION}."
    end

    def validate_string!(value, field)
      raise ArgumentError, "#{field} required" if !value.is_a?(String) || value.empty?
    end

    def validate_non_negative_number!(value, field)
      raise ArgumentError, "#{field} must be a non-negative number, got #{value.inspect}" unless value.is_a?(Numeric) && value >= 0
    end

    def validate_entries!
      raise ArgumentError, "entries must be an array" unless @entries.is_a?(Array)

      @entries.each { |entry| validate_entry!(entry) }

      ids = @entries.map { |e| e["id"] }
      duplicates = ids.tally.select { |_, count| count > 1 }.keys
      unless duplicates.empty?
        raise ArgumentError, "entry ids must be unique, duplicates: #{duplicates.inspect}"
      end
    end

    def validate_entry!(entry)
      raise ArgumentError, "entry must be a hash" unless entry.is_a?(Hash)

      validate_string!(entry["id"], "entry id")
      id = entry["id"]
      validate_string!(entry["source_video"], "entry #{id} source_video")
      validate_string!(entry["template"], "entry #{id} template")

      validate_non_negative_number!(entry["start"], "entry #{id} start")
      validate_non_negative_number!(entry["end"], "entry #{id} end")
      unless entry["end"] > entry["start"]
        raise ArgumentError, "entry #{id} end (#{entry["end"]}) must be greater than start (#{entry["start"]})"
      end

      placement = entry["placement"]
      unless PLACEMENTS.include?(placement)
        raise ArgumentError, "entry #{id} placement #{placement.inspect} not in #{PLACEMENTS.inspect}"
      end

      validate_pip_fields!(entry, id, placement)

      if entry.key?("score") && !entry["score"].nil?
        score = entry["score"]
        unless score.is_a?(Numeric) && score >= 0 && score <= 1
          raise ArgumentError, "entry #{id} score must be in 0..1, got #{score.inspect}"
        end
      end

      content = entry["content"]
      raise ArgumentError, "entry #{id} content must be a hash" unless content.is_a?(Hash)
      raise ArgumentError, "entry #{id} content must not be empty" if content.empty?

      if entry.key?("rendered") && !entry["rendered"].nil?
        validate_string!(entry["rendered"], "entry #{id} rendered")
      end

      if entry.key?("notes") && !entry["notes"].nil? && !entry["notes"].is_a?(String)
        raise ArgumentError, "entry #{id} notes must be a string"
      end
    end

    def validate_pip_fields!(entry, id, placement)
      has_corner = entry.key?("pip_corner") && !entry["pip_corner"].nil?
      has_scale  = entry.key?("pip_scale")  && !entry["pip_scale"].nil?

      if placement != "pip"
        if has_corner
          raise ArgumentError, "entry #{id} pip_corner only valid when placement is pip"
        end
        if has_scale
          raise ArgumentError, "entry #{id} pip_scale only valid when placement is pip"
        end
        return
      end

      if has_corner && !PIP_CORNERS.include?(entry["pip_corner"])
        raise ArgumentError, "entry #{id} pip_corner #{entry["pip_corner"].inspect} not in #{PIP_CORNERS.inspect}"
      end

      if has_scale
        scale = entry["pip_scale"]
        unless scale.is_a?(Numeric) && scale >= PIP_SCALE_MIN && scale <= PIP_SCALE_MAX
          raise ArgumentError, "entry #{id} pip_scale must be in #{PIP_SCALE_MIN}..#{PIP_SCALE_MAX}, got #{scale.inspect}"
        end
      end
    end
  end
end
