require_relative 'editor_base'
require 'nokogiri'

class ButterCut
  # Final Cut Pro 7 XML Interchange Format (version 5).
  # This structure can be imported by legacy FCP as well as Adobe Premiere Pro.
  class FCP7 < EditorBase
    def to_xml
      raise ArgumentError, "No clips provided" if clips.empty?

      asset_map = build_asset_map
      timeline_frame_duration = format_frame_duration
      timeline_clips, sequence_duration_fraction = build_timeline_clips(asset_map, timeline_frame_duration)

      rate_num, rate_denom = format_frame_rate.split('/').map(&:to_i)
      timebase = format_nominal_frame_rate
      ntsc_flag = ntsc_flag_for(rate_denom)
      drop_frame = drop_frame_rate?(rate_num, rate_denom)
      display_format = drop_frame ? 'DF' : 'NDF'

      sequence_duration_frames = frames_for_fraction(sequence_duration_fraction, timeline_frame_duration)
      sequence_uuid = generate_uuid
      sequence_id = "sequence-#{sequence_uuid}"

      first_path = clips.first[:path]
      sequence_name = "#{get_basename(get_filename(first_path))} #{timestamp_suffix}"

      clip_payloads = build_clip_payloads(timeline_clips, timeline_frame_duration)
      sequence_audio_rate = format_audio_rate || '48000'

      builder = Nokogiri::XML::Builder.new(encoding: 'UTF-8') do |xml|
        xml.doc.create_internal_subset('xmeml', nil, nil)
        xml.xmeml(version: '5') do
          xml.sequence(id: sequence_id) do
            xml.uuid sequence_uuid
            xml.name sequence_name
            xml.duration sequence_duration_frames
            xml.rate do
              xml.timebase timebase
              xml.ntsc ntsc_flag
            end
            xml.in 0
            xml.out sequence_duration_frames
            xml.timecode do
              xml.rate do
                xml.timebase timebase
                xml.ntsc ntsc_flag
              end
              xml.frame 0
              xml.displayformat display_format
            end
            xml.media do
              xml.video do
                xml.format do
                  xml.samplecharacteristics do
                    xml.rate do
                      xml.timebase timebase
                      xml.ntsc ntsc_flag
                    end
                    xml.width format_width
                    xml.height format_height
                    xml.anamorphic 'FALSE'
                    xml.pixelaspectratio 'square'
                    xml.fielddominance 'none'
                  end
                end
                xml.track do
                  clip_payloads.each do |payload|
                    build_video_clipitem(xml, payload)
                  end
                end
                build_overlay_video_track(xml, timeline_frame_duration) if overlays.any?
              end
              xml.audio do
                xml.numOutputChannels 2
                xml.format do
                  xml.samplecharacteristics do
                    xml.samplerate sequence_audio_rate
                    xml.sampledepth 16
                  end
                end
                xml.track do
                  clip_payloads.each do |payload|
                    build_audio_clipitem(xml, payload)
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

    def ntsc_flag_for(rate_denom)
      rate_denom == 1 ? 'FALSE' : 'TRUE'
    end

    def drop_frame_rate?(rate_num, rate_denom)
      (rate_num == 30000 && rate_denom == 1001) || (rate_num == 60000 && rate_denom == 1001)
    end

    def build_clip_payloads(timeline_clips, timeline_frame_duration)
      timeline_clips.each_with_index.map do |clip, index|
        asset = clip[:asset]
        asset_rate_num, asset_rate_denom = asset[:frame_rate].split('/').map(&:to_i)
        asset_timebase = (asset_rate_num.to_f / asset_rate_denom).round
        asset_ntsc = ntsc_flag_for(asset_rate_denom)
        asset_display = drop_frame_rate?(asset_rate_num, asset_rate_denom) ? 'DF' : 'NDF'

        timeline_duration_frames = frames_for_fraction(clip[:duration], timeline_frame_duration)
        timeline_start_frames = frames_for_fraction(clip[:timeline_offset], timeline_frame_duration)
        timeline_end_frames = timeline_start_frames + timeline_duration_frames

        source_in_frames = frames_for_fraction(clip[:source_in], asset[:frame_duration])
        source_duration_frames = frames_for_fraction(clip[:source_duration], asset[:frame_duration])
        source_out_frames = source_in_frames + source_duration_frames

        asset_duration_frames = frames_for_fraction(asset[:asset_duration], asset[:frame_duration])
        asset_timecode_start = frames_for_fraction(asset[:timecode], asset[:frame_duration])

        {
          index: index + 1,
          clip: clip,
          asset: asset,
          video_clip_id: "clipitem-video-#{index + 1}",
          audio_clip_id: "clipitem-audio-#{index + 1}",
          file_id: "file-#{asset[:asset_id]}",
          timeline_start: timeline_start_frames,
          timeline_end: timeline_end_frames,
          timeline_duration: timeline_duration_frames,
          source_in: source_in_frames,
          source_out: source_out_frames,
          source_duration_frames: source_duration_frames,
          asset_timebase: asset_timebase,
          asset_ntsc: asset_ntsc,
          asset_display: asset_display,
          asset_duration_frames: asset_duration_frames,
          asset_timecode_start: asset_timecode_start
        }
      end
    end

    def build_video_clipitem(xml, payload)
      asset = payload[:asset]

      xml.clipitem(id: payload[:video_clip_id]) do
        xml.name asset[:basename]
        xml.enabled 'TRUE'
        xml.duration payload[:timeline_duration]
        xml.start payload[:timeline_start]
        xml.end_ payload[:timeline_end]
        xml.in_ payload[:source_in]
        xml.out payload[:source_out]
        xml.file(id: payload[:file_id]) do
          xml.name asset[:filename]
          xml.pathurl asset[:file_url]
          xml.rate do
            xml.timebase payload[:asset_timebase]
            xml.ntsc payload[:asset_ntsc]
          end
          xml.duration payload[:asset_duration_frames]
          xml.timecode do
            xml.rate do
              xml.timebase payload[:asset_timebase]
              xml.ntsc payload[:asset_ntsc]
            end
            xml.frame payload[:asset_timecode_start]
            xml.displayformat payload[:asset_display]
          end
          xml.media do
            xml.video do
              xml.samplecharacteristics do
                xml.rate do
                  xml.timebase payload[:asset_timebase]
                  xml.ntsc payload[:asset_ntsc]
                end
                xml.width asset[:width]
                xml.height asset[:height]
                xml.anamorphic 'FALSE'
                xml.pixelaspectratio 'square'
                xml.fielddominance 'none'
              end
            end
            xml.audio do
              xml.samplecharacteristics do
                xml.samplerate asset_audio_rate(asset)
                xml.sampledepth 16
              end
            end
          end
        end
        xml.sourcetrack do
          xml.mediatype 'video'
          xml.trackindex 1
        end
        build_link_entries(xml, payload)
      end
    end

    def build_audio_clipitem(xml, payload)
      asset = payload[:asset]

      xml.clipitem(id: payload[:audio_clip_id]) do
        xml.name asset[:basename]
        xml.enabled 'TRUE'
        xml.duration payload[:timeline_duration]
        xml.start payload[:timeline_start]
        xml.end_ payload[:timeline_end]
        xml.in_ payload[:source_in]
        xml.out payload[:source_out]
        xml.file(id: payload[:file_id]) do
          xml.name asset[:filename]
          xml.pathurl asset[:file_url]
          xml.rate do
            xml.timebase payload[:asset_timebase]
            xml.ntsc payload[:asset_ntsc]
          end
          xml.duration payload[:asset_duration_frames]
          xml.media do
            xml.audio do
              xml.samplecharacteristics do
                xml.samplerate asset_audio_rate(asset)
                xml.sampledepth 16
              end
            end
          end
        end
        xml.sourcetrack do
          xml.mediatype 'audio'
          xml.trackindex 1
        end
        xml.channelcount 2
        build_link_entries(xml, payload)
      end
    end

    def build_link_entries(xml, payload)
      xml.link do
        xml.linkclipref payload[:video_clip_id]
        xml.mediatype 'video'
        xml.trackindex 1
        xml.clipindex payload[:index]
      end
      xml.link do
        xml.linkclipref payload[:audio_clip_id]
        xml.mediatype 'audio'
        xml.trackindex 1
        xml.clipindex payload[:index]
        xml.groupindex 1
      end
    end

    def asset_audio_rate(asset)
      asset[:audio_rate] || format_audio_rate || '48000'
    end

    def build_overlay_video_track(xml, timeline_frame_duration)
      xml.track do
        overlays.each_with_index do |overlay, i|
          build_overlay_clipitem(xml, overlay, i, timeline_frame_duration)
        end
      end
    end

    def build_overlay_clipitem(xml, overlay, index, timeline_frame_duration)
      metadata = extract_metadata(overlay.source)
      video_stream = metadata['streams'].find { |s| s['codec_type'] == 'video' }
      asset_duration_seconds = metadata['format']['duration'].to_f

      asset_rate_num, asset_rate_denom = (video_stream['r_frame_rate'] || '30/1').split('/').map(&:to_i)
      asset_timebase = (asset_rate_num.to_f / asset_rate_denom).round
      asset_ntsc = ntsc_flag_for(asset_rate_denom)

      start_frame = frames_for_fraction(seconds_to_fraction(overlay.start), timeline_frame_duration)
      duration_frame = frames_for_fraction(seconds_to_fraction(overlay.duration), timeline_frame_duration)
      end_frame = start_frame + duration_frame

      asset_duration_frames = frames_for_fraction(seconds_to_fraction(asset_duration_seconds), timeline_frame_duration)

      filename = File.basename(overlay.source)
      file_id = "file-overlay-#{overlay.source_id}"
      clip_id = "clipitem-overlay-#{overlay.source_id}-#{index + 1}"

      xml.clipitem(id: clip_id) do
        xml.name "#{overlay.source_id} (#{filename})"
        xml.enabled 'TRUE'
        xml.duration duration_frame
        xml.start start_frame
        xml.end_ end_frame
        xml.in_ 0
        xml.out duration_frame
        xml.file(id: file_id) do
          xml.name filename
          xml.pathurl path_to_file_url(overlay.source)
          xml.rate do
            xml.timebase asset_timebase
            xml.ntsc asset_ntsc
          end
          xml.duration asset_duration_frames
          xml.media do
            xml.video do
              xml.samplecharacteristics do
                xml.rate do
                  xml.timebase asset_timebase
                  xml.ntsc asset_ntsc
                end
                xml.width video_stream['width']
                xml.height video_stream['height']
              end
            end
          end
        end
        build_basic_motion_filter(xml, overlay) if overlay.pip?
      end
    end

    def build_basic_motion_filter(xml, overlay)
      transform = overlay.pip_transform
      return if transform.nil?

      xml.filter do
        xml.enabled 'TRUE'
        xml.start 0
        xml.end_(-1)
        xml.effect do
          xml.name 'Basic Motion'
          xml.effectid 'basic'
          xml.effectcategory 'motion'
          xml.effecttype 'motion'
          xml.mediatype 'video'
          xml.parameter do
            xml.name 'Scale'
            xml.parameterid 'scale'
            xml.value (transform[:scale] * 100.0).round(2)
            xml.valuemin 0
            xml.valuemax 1000
          end
          xml.parameter do
            xml.name 'Center'
            xml.parameterid 'center'
            xml.value do
              xml.horiz transform[:x].round(4)
              xml.vert(-transform[:y].round(4)) # FCP7 inverts y vs. FCPXML
            end
          end
        end
      end
    end
  end
end
