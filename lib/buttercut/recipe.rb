require 'json'
require_relative 'fuse_library'

class ButterCut
  # Editorial recipe emitted alongside the rough-cut XML. Captures per-clip
  # directives (speed ramps, color tags, markers), transitions between clips,
  # an optional title card, render preset, and PowerGrade reference. The
  # recipe is consumed by a Resolve apply script (see Sprint 1).
  class Recipe
    SCHEMA_VERSION = 3
    SUPPORTED_VERSIONS = [1, 2, 3].freeze
    BROLL_PLACEMENTS = %w[overlay cutaway pip].freeze
    DEFAULT_FUSE_ROOT = File.expand_path('../../fuses', __dir__)

    CLIP_COLOR_TAGS = %w[
      Orange Apricot Yellow Lime Olive Green Teal Navy Blue
      Purple Violet Pink Tan Beige Brown Chocolate
    ].freeze

    MARKER_COLORS = %w[
      Blue Cyan Green Yellow Red Pink Purple Fuchsia Rose
      Lavender Sky Mint Lemon Sand Cocoa Cream
    ].freeze

    EASE_TYPES = %w[linear ease-in ease-out ease-in-out].freeze
    TRANSITION_TYPES = %w[dip_to_color cross_dissolve].freeze
    DIP_COLORS = %w[black white].freeze

    def self.from_hash(hash, fuse_library: nil)
      raise ArgumentError, "recipe hash required" unless hash.is_a?(Hash)

      new(
        version: hash["version"],
        library: hash["library"],
        timeline: hash["timeline"],
        clips: hash["clips"],
        render_preset: hash["render_preset"],
        powergrade: hash["powergrade"],
        transitions: hash.key?("transitions") ? hash["transitions"] : [],
        title_card: hash["title_card"],
        broll: hash.key?("broll") ? hash["broll"] : nil,
        fuse_library: fuse_library
      )
    end

    def self.load(path, fuse_library: nil)
      from_hash(JSON.parse(File.read(path)), fuse_library: fuse_library)
    end

    def initialize(version:, library:, timeline:, clips:, render_preset: nil, powergrade: nil, transitions: [], title_card: nil, broll: nil, fuse_library: nil)
      @version = version
      @library = library
      @timeline = timeline
      @clips = clips
      @render_preset = render_preset
      @powergrade = powergrade
      @transitions = transitions
      @title_card = title_card
      @broll = broll
      @fuse_library = fuse_library

      validate!
    end

    def to_h
      h = {
        "version" => @version,
        "library" => @library,
        "timeline" => @timeline
      }
      h["render_preset"] = @render_preset if @render_preset
      h["powergrade"] = @powergrade if @powergrade
      h["clips"] = @clips
      h["transitions"] = @transitions unless @transitions.empty?
      h["title_card"] = @title_card if @title_card
      h["broll"] = @broll if @broll && !@broll.empty?
      h
    end

    def to_json(*args)
      JSON.generate(to_h, *args)
    end

    def save(path)
      File.write(path, JSON.pretty_generate(to_h))
    end

    private

    def validate!
      validate_version!
      validate_string!(@library, "library")
      validate_string!(@timeline, "timeline")
      validate_clips!
      validate_render_preset! if @render_preset
      validate_powergrade! if @powergrade
      validate_transitions!
      validate_title_card! if @title_card
      validate_broll! unless @broll.nil?
    end

    def validate_broll!
      raise ArgumentError, "broll must be an array" unless @broll.is_a?(Array)
      @broll.each_with_index do |entry, i|
        raise ArgumentError, "broll[#{i}] must be a hash" unless entry.is_a?(Hash)
        %w[id start end placement source source_video].each do |field|
          unless entry.key?(field) && !entry[field].nil?
            raise ArgumentError, "broll[#{i}] missing required field #{field.inspect}"
          end
        end
        validate_string!(entry["id"], "broll[#{i}] id")
        validate_string!(entry["source"], "broll[#{i}] source")
        validate_string!(entry["source_video"], "broll[#{i}] source_video")
        validate_non_negative_number!(entry["start"], "broll[#{i}] start")
        validate_non_negative_number!(entry["end"], "broll[#{i}] end")
        unless entry["end"] > entry["start"]
          raise ArgumentError, "broll[#{i}] end must be greater than start"
        end
        unless BROLL_PLACEMENTS.include?(entry["placement"])
          raise ArgumentError, "broll[#{i}] placement #{entry["placement"].inspect} not in #{BROLL_PLACEMENTS.inspect}"
        end
      end
    end

    def validate_version!
      unless SUPPORTED_VERSIONS.include?(@version)
        raise ArgumentError, "version must be one of #{SUPPORTED_VERSIONS.inspect}, got #{@version.inspect}"
      end
    end

    def validate_string!(value, field)
      raise ArgumentError, "#{field} required" if value.nil? || !value.is_a?(String) || value.empty?
    end

    def validate_positive_int!(value, field)
      raise ArgumentError, "#{field} must be a positive integer, got #{value.inspect}" unless value.is_a?(Integer) && value.positive?
    end

    def validate_non_negative_number!(value, field)
      raise ArgumentError, "#{field} must be a non-negative number, got #{value.inspect}" unless value.is_a?(Numeric) && value >= 0
    end

    def validate_clips!
      raise ArgumentError, "clips must be a non-empty array" unless @clips.is_a?(Array) && !@clips.empty?

      @clips.each { |clip| validate_clip!(clip) }

      duplicates = clip_indices.tally.select { |_, count| count > 1 }.keys
      unless duplicates.empty?
        raise ArgumentError, "clip indices must be unique, duplicates: #{duplicates.inspect}"
      end
    end

    def clip_indices
      @clip_indices ||= @clips.map { |c| c["index"] }
    end

    def clip_positions
      @clip_positions ||= @clips.each_with_index.to_h { |clip, pos| [clip["index"], pos] }
    end

    def validate_clip!(clip)
      raise ArgumentError, "clip must be a hash" unless clip.is_a?(Hash)
      validate_positive_int!(clip["index"], "clip index")
      validate_string!(clip["source_file"], "clip source_file")

      speed_ramps = clip.key?("speed_ramps") ? clip["speed_ramps"] : []
      raise ArgumentError, "clip #{clip["index"]} speed_ramps must be an array" unless speed_ramps.is_a?(Array)
      speed_ramps.each { |ramp| validate_speed_ramp!(ramp, clip["index"]) }

      if clip.key?("color_tag") && !CLIP_COLOR_TAGS.include?(clip["color_tag"])
        raise ArgumentError, "clip #{clip["index"]} color_tag #{clip["color_tag"].inspect} not in #{CLIP_COLOR_TAGS.inspect}"
      end

      markers = clip.key?("markers") ? clip["markers"] : []
      raise ArgumentError, "clip #{clip["index"]} markers must be an array" unless markers.is_a?(Array)
      markers.each { |marker| validate_marker!(marker, clip["index"]) }

      validate_fusion_effects!(clip) if clip.key?("fusion_effects")
    end

    def fuse_library
      @fuse_library ||= ButterCut::FuseLibrary.load(root: DEFAULT_FUSE_ROOT)
    end

    def validate_fusion_effects!(clip)
      effects = clip["fusion_effects"]
      raise ArgumentError, "clip #{clip["index"]} fusion_effects must be an array" unless effects.is_a?(Array)
      effects.each_with_index do |effect, i|
        unless effect.is_a?(Hash) && effect["fuse"].is_a?(String) && !effect["fuse"].empty?
          raise ArgumentError, "clip #{clip["index"]} fusion_effects[#{i}] must be a hash with a 'fuse' string"
        end
        params = effect["params"] || {}
        fuse_library.validate_params!(effect["fuse"], params)
      end
    end

    def validate_speed_ramp!(ramp, clip_index)
      raise ArgumentError, "clip #{clip_index} speed_ramp must be a hash" unless ramp.is_a?(Hash)
      validate_non_negative_number!(ramp["at"], "clip #{clip_index} speed_ramp at")
      speed = ramp["speed"]
      unless speed.is_a?(Numeric) && speed > 0
        raise ArgumentError, "clip #{clip_index} speed_ramp speed must be > 0, got #{speed.inspect}"
      end
      unless EASE_TYPES.include?(ramp["ease"])
        raise ArgumentError, "clip #{clip_index} speed_ramp ease #{ramp["ease"].inspect} not in #{EASE_TYPES.inspect}"
      end
    end

    def validate_marker!(marker, clip_index)
      raise ArgumentError, "clip #{clip_index} marker must be a hash" unless marker.is_a?(Hash)
      validate_non_negative_number!(marker["at"], "clip #{clip_index} marker at")
      name = marker["name"]
      raise ArgumentError, "clip #{clip_index} marker name required" if !name.is_a?(String) || name.empty?
      unless MARKER_COLORS.include?(marker["color"])
        raise ArgumentError, "clip #{clip_index} marker color #{marker["color"].inspect} not in #{MARKER_COLORS.inspect}"
      end
    end

    def validate_render_preset!
      raise ArgumentError, "render_preset must be a hash" unless @render_preset.is_a?(Hash)
      validate_string!(@render_preset["format"], "render_preset format")
      validate_string!(@render_preset["codec"], "render_preset codec")
      validate_string!(@render_preset["resolution"], "render_preset resolution")
      validate_positive_int!(@render_preset["bitrate_kbps"], "render_preset bitrate_kbps")
    end

    def validate_powergrade!
      raise ArgumentError, "powergrade must be a hash" unless @powergrade.is_a?(Hash)
      validate_string!(@powergrade["name"], "powergrade name")

      apply_to = @powergrade["apply_to"]
      case apply_to
      when "all"
        # ok
      when Array
        apply_to.each do |idx|
          unless clip_indices.include?(idx)
            raise ArgumentError, "powergrade apply_to references unknown clip index #{idx}"
          end
        end
      else
        raise ArgumentError, "powergrade apply_to must be 'all' or an array of clip indices, got #{apply_to.inspect}"
      end
    end

    def validate_transitions!
      raise ArgumentError, "transitions must be an array" unless @transitions.is_a?(Array)
      @transitions.each { |t| validate_transition!(t) }
    end

    def validate_transition!(t)
      raise ArgumentError, "transition must be a hash" unless t.is_a?(Hash)

      between = t["between"]
      unless between.is_a?(Array) && between.length == 2 && between.all? { |i| i.is_a?(Integer) }
        raise ArgumentError, "transition between must be a [a, b] pair of integers, got #{between.inspect}"
      end
      a, b = between
      unless clip_indices.include?(a) && clip_indices.include?(b)
        missing = [a, b].reject { |i| clip_indices.include?(i) }
        raise ArgumentError, "transition between references unknown clip index #{missing.first}"
      end
      unless clip_positions[b] == clip_positions[a] + 1
        raise ArgumentError, "transition between #{between.inspect} must reference adjacent clips in recipe order"
      end

      unless TRANSITION_TYPES.include?(t["type"])
        raise ArgumentError, "transition type #{t["type"].inspect} not in #{TRANSITION_TYPES.inspect}"
      end

      validate_positive_int!(t["duration_frames"], "transition duration_frames")

      if t["type"] == "dip_to_color"
        unless DIP_COLORS.include?(t["color"])
          raise ArgumentError, "dip_to_color transition color #{t["color"].inspect} not in #{DIP_COLORS.inspect}"
        end
      end
    end

    def validate_title_card!
      raise ArgumentError, "title_card must be a hash" unless @title_card.is_a?(Hash)
      at_clip = @title_card["at_clip"]
      unless clip_indices.include?(at_clip)
        raise ArgumentError, "title_card at_clip references unknown clip index #{at_clip.inspect}"
      end
      validate_string!(@title_card["text"], "title_card text")
      validate_non_negative_number!(@title_card["fade_in_at"], "title_card fade_in_at")
      validate_positive_int!(@title_card["fade_in_frames"], "title_card fade_in_frames")
    end
  end
end
