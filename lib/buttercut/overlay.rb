require 'pathname'

class ButterCut
  # One b-roll placement on top of the V1 spine. Built by callers (typically
  # export_to_fcpxml.rb) from a BrollManifest entry; consumed by FCPX/FCP7.
  #
  # All overlays mute their own audio — the V1 audio bed continues underneath.
  class Overlay
    PLACEMENTS = %w[overlay cutaway pip].freeze
    PIP_CORNERS = %w[top_right top_left bottom_right bottom_left].freeze
    DEFAULT_PIP_CORNER = "top_right"
    DEFAULT_PIP_SCALE = 0.33

    # Inset, in centered-fraction units, between the scaled clip's edge and the
    # frame's edge. 0.05 means the clip edge sits 0.05 (5% of the full frame
    # dimension) inside the frame edge after scaling.
    PIP_EDGE_MARGIN = 0.05

    attr_reader :source, :source_id, :start, :duration, :placement,
                :pip_corner, :pip_scale

    def self.from_hash(hash)
      raise ArgumentError, "overlay hash required" unless hash.is_a?(Hash)

      new(
        source: hash[:source] || hash["source"],
        source_id: hash[:source_id] || hash["source_id"],
        start: hash[:start] || hash["start"],
        duration: hash[:duration] || hash["duration"],
        placement: hash[:placement] || hash["placement"],
        pip_corner: hash[:pip_corner] || hash["pip_corner"],
        pip_scale: hash[:pip_scale] || hash["pip_scale"]
      )
    end

    def initialize(source:, source_id:, start:, duration:, placement:, pip_corner: nil, pip_scale: nil)
      raise ArgumentError, "source required" if source.nil? || source.empty?
      raise ArgumentError, "source must be an absolute path: #{source}" unless Pathname.new(source).absolute?
      raise ArgumentError, "source_id required" if source_id.nil? || source_id.empty?
      raise ArgumentError, "start must be a non-negative number" unless start.is_a?(Numeric) && start >= 0
      raise ArgumentError, "duration must be > 0" unless duration.is_a?(Numeric) && duration > 0
      raise ArgumentError, "placement #{placement.inspect} not in #{PLACEMENTS.inspect}" unless PLACEMENTS.include?(placement)

      if placement == "pip"
        @pip_corner = pip_corner || DEFAULT_PIP_CORNER
        @pip_scale = pip_scale.nil? ? DEFAULT_PIP_SCALE : pip_scale
        unless PIP_CORNERS.include?(@pip_corner)
          raise ArgumentError, "pip_corner #{@pip_corner.inspect} not in #{PIP_CORNERS.inspect}"
        end
        unless @pip_scale.is_a?(Numeric) && @pip_scale > 0 && @pip_scale < 1
          raise ArgumentError, "pip_scale must be in (0, 1), got #{@pip_scale.inspect}"
        end
      else
        if pip_corner
          raise ArgumentError, "pip_corner only valid when placement is pip"
        end
        if pip_scale
          raise ArgumentError, "pip_scale only valid when placement is pip"
        end
        @pip_corner = nil
        @pip_scale = nil
      end

      @source = source
      @source_id = source_id
      @start = start
      @duration = duration
      @placement = placement
    end

    def end_time
      @start + @duration
    end

    def pip?
      @placement == "pip"
    end

    # Returns { scale:, x:, y:, corner: } in FCPXML centered-fraction units, or
    # nil for non-pip overlays.
    #
    # Coordinate convention: 0,0 is frame center. Positive x = right, positive y
    # = up (FCPXML convention). Values are fractions of the frame: x=0.5 means
    # right edge, y=0.5 means top edge. We compute the corner offset so the
    # scaled clip's edge sits PIP_EDGE_MARGIN inside the frame edge.
    def pip_transform
      return nil unless pip?

      offset = (1.0 - @pip_scale) / 2.0 - PIP_EDGE_MARGIN
      sign_x = @pip_corner.end_with?("right") ? 1 : -1
      sign_y = @pip_corner.start_with?("top")  ? 1 : -1

      {
        scale: @pip_scale,
        x: sign_x * offset,
        y: sign_y * offset,
        corner: @pip_corner
      }
    end
  end
end
