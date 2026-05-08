require "yaml"
require "json"
require "date"
require "pathname"

class ButterCut
  # Pure-Ruby gathering of everything the b-roll director prompt needs.
  # No LLM, no writes — just reads files the caller points at.
  class BrollDirectorInputs
    REQUIRED_VIDEO_KEYS = %w[transcript visual_transcript summary].freeze

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
      videos_by_basename = (library["videos"] || []).each_with_object({}) do |v, h|
        h[File.basename(v["path"].to_s)] = v
      end

      referenced = roughcut["clips"].map { |c| c["source_video"] }.uniq
      missing_meta = []
      result = {}

      referenced.each do |basename|
        video = videos_by_basename[basename]
        if video.nil?
          missing_meta << basename
          next
        end
        absent = REQUIRED_VIDEO_KEYS.reject { |k| !video[k].to_s.empty? }
        if !absent.empty?
          missing_meta << "#{basename} (missing #{absent.join(', ')})"
          next
        end
        result[basename] = {
          audio_transcript: load_json(@library_dir.join("transcripts", video["transcript"])),
          visual_transcript: load_json(@library_dir.join("transcripts", video["visual_transcript"])),
          summary: @library_dir.join("summaries", video["summary"]).read
        }
      end

      unless missing_meta.empty?
        raise ArgumentError, "missing transcripts/summaries for: #{missing_meta.join('; ')}"
      end

      result
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
