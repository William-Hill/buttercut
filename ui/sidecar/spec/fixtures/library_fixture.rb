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

  # Writes a transcript JSON with the full WhisperX shape: segments[].words[]
  # and a top-level word_segments[]. Each segment is provided as
  # { start:, end:, text:, words: [{word:, start:, end:}, ...] }.
  # word_segments is auto-derived as the flat concatenation of all words[].
  def self.write_whisperx_transcript(lib_dir, basename, segments:, language: "en")
    path = File.join(lib_dir, "transcripts", basename)
    word_segments = segments.flat_map { |s| s[:words] || [] }.map do |w|
      { "word" => w[:word], "start" => w[:start], "end" => w[:end] }
    end
    payload = {
      "language" => language,
      "video_path" => "n/a",
      "segments" => segments.map do |s|
        {
          "start" => s[:start],
          "end" => s[:end],
          "text" => s[:text],
          "words" => (s[:words] || []).map { |w| { "word" => w[:word], "start" => w[:start], "end" => w[:end] } }
        }
      end,
      "word_segments" => word_segments
    }
    File.write(path, JSON.pretty_generate(payload))
    path
  end
end
