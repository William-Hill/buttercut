require "yaml"
require "json"
require "date"
require "pathname"

require_relative "timecode"

class ButterCut
  class BrollDirectorInputs
    REQUIRED_VIDEO_KEYS = %w[transcript visual_transcript summary].freeze
    SLICE_PAD_SECONDS = 2.0

    def self.gather(library_dir:, roughcut_path:, hyperframes_dir:)
      new(
        library_dir: library_dir,
        roughcut_path: roughcut_path,
        hyperframes_dir: hyperframes_dir
      ).gather
    end

    def initialize(library_dir:, roughcut_path:, hyperframes_dir:)
      raise ArgumentError, "library_dir required" if library_dir.to_s.empty?
      raise ArgumentError, "roughcut_path required" if roughcut_path.to_s.empty?
      raise ArgumentError, "hyperframes_dir required" if hyperframes_dir.to_s.empty?

      @library_dir = Pathname.new(library_dir)
      @roughcut_path = Pathname.new(roughcut_path)
      @hyperframes_dir = Pathname.new(hyperframes_dir)
    end

    def gather
      library = load_library
      roughcut = load_roughcut
      sources = load_source_videos(library, roughcut)
      {
        library_name: library["library_name"] || @library_dir.basename.to_s,
        roughcut_stem: @roughcut_path.basename.sub_ext("").to_s,
        roughcut: roughcut,
        theme: library["theme"] || {},
        source_videos: sources,
        available_templates: load_templates
      }
    end

    private

    def load_library
      path = @library_dir.join("library.yaml")
      raise ArgumentError, "library.yaml not found at #{path}" unless path.file?
      YAML.safe_load(path.read, permitted_classes: [Date, Time], aliases: true) || {}
    end

    def load_roughcut
      raise ArgumentError, "rough cut not found at #{@roughcut_path}" unless @roughcut_path.file?
      data = YAML.safe_load(@roughcut_path.read, permitted_classes: [Date, Time], aliases: true) || {}
      raise ArgumentError, "rough cut has no clips" unless data["clips"].is_a?(Array) && !data["clips"].empty?
      data
    end

    def load_source_videos(library, roughcut)
      videos = library["videos"] || []
      duplicates = videos
        .group_by { |v| File.basename(v["path"].to_s) }
        .select { |basename, items| !basename.empty? && items.length > 1 }
        .keys
      unless duplicates.empty?
        raise ArgumentError, "duplicate source video basenames in library.yaml: #{duplicates.join(', ')}"
      end

      videos_by_basename = videos.each_with_object({}) do |v, h|
        h[File.basename(v["path"].to_s)] = v
      end

      windows_by_source = clip_windows(roughcut["clips"])
      missing_meta = []
      result = {}

      windows_by_source.each do |basename, windows|
        video = videos_by_basename[basename]
        if video.nil?
          missing_meta << basename
          next
        end
        absent = REQUIRED_VIDEO_KEYS.select { |k| video[k].to_s.empty? }
        unless absent.empty?
          missing_meta << "#{basename} (missing #{absent.join(', ')})"
          next
        end

        audio = load_json(safe_transcript_path(video["transcript"]))
        visual = load_json(safe_transcript_path(video["visual_transcript"]))
        summary = safe_summary_path(video["summary"]).read

        result[basename] = {
          audio_transcript: slice_audio(audio, windows),
          visual_transcript: slice_visual(visual, windows),
          summary: summary
        }
      end

      unless missing_meta.empty?
        raise ArgumentError, "missing transcripts/summaries for: #{missing_meta.join('; ')}"
      end

      result
    end

    # { source_video => [[in_s, out_s], ...] } sorted, padded.
    def clip_windows(clips)
      clips.each_with_object({}) do |clip, h|
        src = clip["source_video"]
        in_s = ButterCut::Timecode.to_seconds(clip["in"])
        out_s = ButterCut::Timecode.to_seconds(clip["out"])
        (h[src] ||= []) << [[in_s - SLICE_PAD_SECONDS, 0].max, out_s + SLICE_PAD_SECONDS]
      end
    end

    def in_any_window?(t, windows)
      windows.any? { |a, b| t >= a && t <= b }
    end

    def overlaps_any_window?(a, b, windows)
      windows.any? { |wa, wb| b >= wa && a <= wb }
    end

    def slice_audio(audio, windows)
      segs = audio["segments"] || []
      kept = segs.select { |s| overlaps_any_window?(s["start"].to_f, s["end"].to_f, windows) }
      audio.merge("segments" => kept)
    end

    def slice_visual(visual, windows)
      frames = visual["frames"] || []
      kept = frames.select { |f| in_any_window?(f["t"].to_f, windows) }
      visual.merge("frames" => kept)
    end

    def safe_transcript_path(filename)
      safe_subpath(@library_dir.join("transcripts"), filename)
    end

    def safe_summary_path(filename)
      safe_subpath(@library_dir.join("summaries"), filename)
    end

    # Reject absolute paths and traversal — accept basenames only.
    def safe_subpath(base, filename)
      s = filename.to_s
      raise ArgumentError, "invalid path reference: #{filename.inspect}" if Pathname.new(s).absolute?
      raise ArgumentError, "invalid path reference: #{filename.inspect}" if s != File.basename(s)
      base.expand_path.join(s)
    end

    def load_json(path)
      raise ArgumentError, "transcript not found at #{path}" unless path.file?
      JSON.parse(path.read)
    end

    def load_templates
      compositions_dir = @hyperframes_dir.join("compositions")
      return [] unless compositions_dir.directory?

      compositions_dir.children.select(&:directory?).sort.filter_map do |dir|
        readme = dir.join("README.md")
        next nil unless readme.file?
        { name: dir.basename.to_s, readme_md: readme.read }
      end
    end
  end
end
