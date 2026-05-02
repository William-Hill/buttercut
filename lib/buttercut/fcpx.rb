require_relative 'editor_base'
require 'nokogiri'

class ButterCut
  # Final Cut Pro X (FCPXML 1.10) implementation. Speed ramps from the
  # editorial recipe are emitted as <timeMap> elements inside <asset-clip>
  # so that DaVinci Resolve preserves them on import without needing the
  # apply script.
  class FCPX < EditorBase
    FORMAT_ID = "r1".freeze
    FCPXML_VERSION = "1.10".freeze

    EASE_TO_INTERP = {
      "linear"       => "linear",
      "ease-in"      => "smooth2",
      "ease-out"     => "smooth2",
      "ease-in-out"  => "smooth2"
    }.freeze

    def to_xml
      raise ArgumentError, "No clips provided" if clips.empty?

      asset_map = build_asset_map
      timeline_frame_duration = format_frame_duration
      timeline_clips, sequence_duration = build_timeline_clips(asset_map, timeline_frame_duration)

      event_uid = generate_uuid
      project_uid = generate_uuid

      first_path = clips.first[:path]
      first_filename = get_filename(first_path)
      project_basename = get_basename(first_filename)
      event_name = project_basename
      timestamped_project_name = "#{project_basename} #{timestamp_suffix}"

      builder = Nokogiri::XML::Builder.new(encoding: 'utf-8') do |xml|
        xml.fcpxml(version: FCPXML_VERSION) do
          xml.resources do
            xml.format(
              id: FORMAT_ID,
              height: format_height,
              width: format_width,
              frameDuration: format_frame_duration,
              colorSpace: format_color_space
            )

            asset_map.each_value do |asset|
              xml.asset(
                id: asset[:asset_id],
                name: asset[:filename],
                uid: asset[:asset_uid],
                src: asset[:file_url],
                start: asset[:timecode],
                audioRate: asset[:audio_rate],
                hasAudio: '1',
                hasVideo: '1',
                format: FORMAT_ID,
                duration: asset[:asset_duration]
              )
            end
          end

          xml.library(location: './') do
            xml.event(name: event_name, uid: event_uid) do
              xml.project(name: timestamped_project_name, uid: project_uid, modDate: '2025-10-31 17:25:16 GMT-7') do
                xml.sequence(duration: sequence_duration, format: FORMAT_ID, tcStart: '0s', audioRate: '48k') do
                  xml.spine do
                    timeline_clips.each do |clip|
                      xml.send('asset-clip',
                        name: clip[:filename],
                        ref: clip[:asset_id],
                        start: clip[:start],
                        offset: clip[:timeline_offset],
                        duration: clip[:duration],
                        audioRole: 'dialogue'
                      ) do
                        emit_time_map(xml, clip)
                        xml.send('adjust-volume', amount: volume_adjustment)
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end

      builder.to_xml
    end

    private

    def emit_time_map(xml, clip)
      ramps = clip.dig(:clip_definition, :speed_ramps)
      return if ramps.nil? || ramps.empty?

      points = build_time_map_points(ramps, clip)
      return if points.length < 2

      xml.timeMap do
        points.each do |pt|
          xml.timept(time: pt[:time], value: pt[:value], interp: pt[:interp])
        end
      end
    end

    # Translate recipe speed ramps (output-time waypoints with speed %) into
    # FCPXML <timept> control points. Each timept is (output_time, source_time);
    # the slope between adjacent points is the effective speed for that segment.
    # We integrate piecewise using the average of adjacent speeds, which gives
    # a plausible source-time curve for both linear and smooth2 interp.
    def build_time_map_points(ramps, clip)
      sorted = ramps.sort_by { |r| ramp_at_seconds(r) }
      clip_duration = fraction_to_rational(clip[:duration])

      waypoints = sorted.map do |ramp|
        {
          at:     Rational(ramp_at_seconds(ramp)),
          speed:  Rational(ramp["speed"]) / 100,
          interp: EASE_TO_INTERP.fetch(ramp["ease"], "linear")
        }
      end

      waypoints.unshift({ at: Rational(0), speed: waypoints.first[:speed], interp: waypoints.first[:interp] }) if waypoints.first[:at] > 0
      waypoints.push({ at: clip_duration, speed: waypoints.last[:speed], interp: waypoints.last[:interp] }) if waypoints.last[:at] < clip_duration

      points = []
      cumulative_source = Rational(0)
      waypoints.each_with_index do |wp, i|
        if i > 0
          prev = waypoints[i - 1]
          segment_dt = wp[:at] - prev[:at]
          avg_speed = (prev[:speed] + wp[:speed]) / 2
          cumulative_source += segment_dt * avg_speed
        end
        points << {
          time:   rational_to_fraction(wp[:at]),
          value:  rational_to_fraction(cumulative_source),
          interp: wp[:interp]
        }
      end
      points
    end

    def ramp_at_seconds(ramp)
      at = ramp["at"]
      raise ArgumentError, "speed_ramp missing 'at'" if at.nil?
      at.to_f
    end

    def rational_to_fraction(rational)
      rational = Rational(rational) unless rational.is_a?(Rational)
      return "0s" if rational.zero?
      "#{rational.numerator}/#{rational.denominator}s"
    end
  end
end
