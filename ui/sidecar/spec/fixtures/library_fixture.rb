require "fileutils"
require "json"
require "tmpdir"
require "yaml"

module LibraryFixture
  def self.build(libraries_root, name:, videos: [], footage_summary: "")
    lib_dir = File.join(libraries_root, name)
    FileUtils.mkdir_p(File.join(lib_dir, "transcripts"))
    FileUtils.mkdir_p(File.join(lib_dir, "summaries"))
    FileUtils.mkdir_p(File.join(lib_dir, "thumbnails"))

    yaml = {
      "library_name" => name,
      "language" => "english",
      "footage_summary" => footage_summary,
      "videos" => videos.map do |v|
        {
          "path" => v[:path],
          "duration" => v[:duration] || "00:00:30",
          "transcript" => v[:transcript] || "",
          "visual_transcript" => v[:visual_transcript] || "",
          "summary" => v[:summary] || ""
        }
      end
    }
    File.write(File.join(lib_dir, "library.yaml"), YAML.dump(yaml))
    lib_dir
  end

  def self.write_audio_transcript(lib_dir, basename, segments:)
    path = File.join(lib_dir, "transcripts", basename)
    File.write(path, JSON.generate({ language: "en", video_path: "n/a", segments: segments }))
    path
  end

  def self.write_visual_transcript(lib_dir, basename, segments:)
    path = File.join(lib_dir, "transcripts", basename)
    File.write(path, JSON.generate({ language: "en", video_path: "n/a", segments: segments }))
    path
  end

  def self.write_summary(lib_dir, basename, body:)
    path = File.join(lib_dir, "summaries", basename)
    File.write(path, body)
    path
  end
end
