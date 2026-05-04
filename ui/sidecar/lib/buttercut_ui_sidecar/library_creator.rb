# frozen_string_literal: true

require "fileutils"
require "pathname"
require "yaml"
require "date"

module ButtercutUiSidecar
  class LibraryCreator
    class LibraryExists < StandardError; end

    def initialize(libraries_root:)
      raise ArgumentError, "libraries_root required" if libraries_root.nil? || libraries_root.to_s.empty?
      @root = Pathname.new(libraries_root)
    end

    def create!(name:, language:, language_code:, refinement:, videos:)
      slug = slugify(name)
      raise ArgumentError, "invalid name: #{name}" if slug.empty?

      lib_dir = @root.join(slug)
      raise LibraryExists, "library already exists: #{slug}" if lib_dir.join("library.yaml").file?

      created = false
      begin
        FileUtils.mkdir_p(lib_dir.join("transcripts"))
        FileUtils.mkdir_p(lib_dir.join("summaries"))
        created = true

        data = build_yaml(slug: slug, language: language, language_code: language_code,
                          refinement: refinement, videos: videos)
        File.write(lib_dir.join("library.yaml").to_s, YAML.dump(data))
        { name: slug }
      rescue StandardError
        FileUtils.rm_rf(lib_dir) if created
        raise
      end
    end

    private

    def slugify(name)
      name.to_s.downcase.gsub(/\s+/, "-").gsub(/[^a-z0-9\-]/, "").gsub(/-+/, "-").gsub(/\A-|-\z/, "")
    end

    def build_yaml(slug:, language:, language_code:, refinement:, videos:)
      today = Date.today.iso8601
      {
        "library_name" => slug,
        "created_date" => today,
        "last_updated" => today,
        "language" => language,
        "language_code" => language_code,
        "editor" => nil,
        "transcript_refinement" => refinement,
        "user_context" => "",
        "footage_summary" => "No footage analyzed yet.",
        "videos" => videos.map do |v|
          {
            "path" => v[:path] || v["path"],
            "duration" => format_duration(v[:duration_seconds] || v["duration_seconds"]),
            "transcript" => "",
            "visual_transcript" => "",
            "summary" => ""
          }
        end
      }
    end

    def format_duration(seconds)
      return "00:00:00" if seconds.nil?
      s = seconds.to_i
      format("%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    end
  end
end
