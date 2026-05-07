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
      overlay_asset_map = build_overlay_asset_map(asset_map)
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

            (asset_map.values + overlay_asset_map.values).each do |asset|
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
                        emit_overlays_for_clip(xml, clip, asset_map, overlay_asset_map)
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

    # Build asset entries for overlay sources that are not already represented
    # in the V1 clip asset map. Sources reused from V1 clips share the existing
    # asset row (no duplication in <resources>).
    def build_overlay_asset_map(existing_asset_map)
      map = {}
      return map if overlays.empty?

      overlays.map(&:source).uniq.each do |path|
        abs_path = get_absolute_path(path)
        next if existing_asset_map.key?(abs_path)
        next if map.key?(abs_path)

        map[abs_path] = {
          asset_id: deterministic_asset_id(abs_path),
          asset_uid: deterministic_asset_uid(abs_path),
          abs_path: abs_path,
          filename: get_filename(path),
          file_url: path_to_file_url(path),
          timecode: clip_timecode_fraction(path),
          audio_rate: audio_sample_rate(path),
          asset_duration: duration_to_fraction(path)
        }
      end
      map
    end

    def emit_overlays_for_clip(xml, clip, asset_map, overlay_asset_map)
      return if overlays.empty?

      clip_start_seconds   = fraction_to_seconds(clip[:timeline_offset])
      clip_end_seconds     = clip_start_seconds + fraction_to_seconds(clip[:duration])
      parent_source_start  = fraction_to_seconds(clip[:start])

      overlays.each do |o|
        next unless overlay_overlaps?(o, clip_start_seconds, clip_end_seconds)

        abs_source = get_absolute_path(o.source)
        asset = overlay_asset_map[abs_source] || asset_map[abs_source]
        next if asset.nil?

        relative_offset_seconds = o.start - clip_start_seconds
        offset_in_parent_local  = parent_source_start + relative_offset_seconds
        offset_fraction         = seconds_to_fraction(offset_in_parent_local)
        duration_fraction       = seconds_to_fraction(o.duration)

        xml.send('asset-clip',
          name:     "#{o.source_id} (#{asset[:filename]})",
          ref:      asset[:asset_id],
          lane:     '1',
          offset:   offset_fraction,
          start:    '0s',
          duration: duration_fraction
        ) do
          xml.send('adjust-volume', amount: '-96dB')
          if (transform = o.pip_transform)
            xml.send('adjust-transform',
              scale:    format('%g %g', transform[:scale], transform[:scale]),
              position: format('%g %g', transform[:x] * 100, transform[:y] * 100)
            )
          end
        end
      end
    end

    def overlay_overlaps?(overlay, clip_start_seconds, clip_end_seconds)
      overlay.start < clip_end_seconds && overlay.end_time > clip_start_seconds
    end

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

      waypoints.unshift({ at: Rational(0), speed: Rational(1), interp: "linear" }) if waypoints.first[:at] > 0
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
