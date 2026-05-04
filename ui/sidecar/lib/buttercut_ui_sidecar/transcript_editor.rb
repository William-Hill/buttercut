# frozen_string_literal: true

require "json"
require "fileutils"
require "pathname"
require "tempfile"

module ButtercutUiSidecar
  # Applies a single-clip word-level edit to a WhisperX transcript JSON,
  # keeping segments[].text, segments[].words[].word, and word_segments[].word
  # consistent. Enforces the 1->1 / N->N word-count rule that downstream
  # timing depends on.
  class TranscriptEditor
    class TokenCountViolation < StandardError; end

    def self.apply(libraries_root:, library:, clip:, edit:)
      new(libraries_root: libraries_root, library: library, clip: clip, edit: edit).apply
    end

    def initialize(libraries_root:, library:, clip:, edit:)
      raise ArgumentError, "libraries_root required" if libraries_root.nil? || libraries_root.to_s.empty?
      raise ArgumentError, "library required" if library.nil? || library.to_s.empty?
      raise ArgumentError, "clip required" if clip.nil? || clip.to_s.empty?
      raise ArgumentError, "edit required" if edit.nil?
      raise ArgumentError, "old_tokens required" if edit[:old_tokens].nil? || edit[:old_tokens].empty?
      raise ArgumentError, "new_tokens required" if edit[:new_tokens].nil? || edit[:new_tokens].empty?

      @path = resolve_transcript_path(libraries_root, library, clip)
      @segment_index = require_non_negative_integer(edit[:segment_index], "segment_index")
      @word_index = require_non_negative_integer(edit[:word_index], "word_index")
      @old_tokens = edit[:old_tokens]
      @new_tokens = edit[:new_tokens]
    end

    def apply
      raise ArgumentError, "transcript not found: #{@path}" unless @path.file?
      if @new_tokens.length != @old_tokens.length
        raise TokenCountViolation,
              "new_tokens (#{@new_tokens.length}) != old_tokens (#{@old_tokens.length})"
      end

      data = JSON.parse(@path.read)
      segments = data["segments"] || []
      segment = segments[@segment_index] or raise ArgumentError, "segment_index out of range"
      words = segment["words"] || []
      slice = words[@word_index, @old_tokens.length] || []
      actual = slice.map { |w| w["word"] }
      unless actual == @old_tokens
        raise ArgumentError,
              "old_tokens does not match: expected #{@old_tokens.inspect}, found #{actual.inspect}"
      end

      apply_to_words(words)
      apply_to_segment_text(segment)
      apply_to_word_segments(data) if data["word_segments"]

      write_atomic(data)

      { edit_count: 1 }
    end

    private

    def require_non_negative_integer(value, name)
      i = Integer(value)
      raise ArgumentError, "#{name} must be non-negative" if i.negative?

      i
    rescue ArgumentError => e
      raise e if e.message == "#{name} must be non-negative"

      raise ArgumentError, "#{name} must be a non-negative integer"
    rescue TypeError
      raise ArgumentError, "#{name} must be a non-negative integer"
    end

    # Mirrors buttercut_ui_sidecar.rb #library_dir — rejects path traversal in
    # library / clip so RPC cannot read/write outside <root>/<library>/transcripts/.
    def resolve_transcript_path(libraries_root, library, clip)
      root = Pathname.new(libraries_root).expand_path
      root = Pathname.new(File.realpath(root.to_s)) if root.directory?

      clip_bn = safe_transcript_basename(clip)

      candidate = root.join(library)
      lib_dir = if candidate.directory?
        Pathname.new(File.realpath(candidate.to_s))
      else
        candidate.expand_path
      end
      root_prefix = root.to_s + File::SEPARATOR
      unless lib_dir.to_s.start_with?(root_prefix)
        raise ArgumentError, "invalid library name: #{library}"
      end

      transcripts_dir = lib_dir.join("transcripts")
      path = transcripts_dir.join(clip_bn)
      td_prefix = transcripts_dir.to_s + File::SEPARATOR
      unless path.to_s.start_with?(td_prefix)
        raise ArgumentError, "invalid transcript path for clip: #{clip.inspect}"
      end

      path
    end

    def safe_transcript_basename(clip)
      s = clip.to_s
      bn = File.basename(s)
      raise ArgumentError, "invalid clip transcript name" if bn.empty? || bn == "." || bn == ".."
      raise ArgumentError, "invalid clip transcript name" unless s == bn

      bn
    end

    def apply_to_words(words)
      @new_tokens.each_with_index do |new_word, i|
        words[@word_index + i]["word"] = new_word
      end
    end

    # Rebuild from words[] so segment text matches the edited token window (handles
    # repeated phrases — String#index would always hit the first). Preserve any
    # leading whitespace WhisperX stores on segment["text"].
    def apply_to_segment_text(segment)
      words = segment["words"] || []
      lead = segment["text"].to_s[/\A\s*/]
      segment["text"] = "#{lead}#{words.map { |w| w["word"].to_s }.join(" ")}"
    end

    # The flat top-level word_segments array mirrors segments[].words[] in
    # document order. Find the matching window by start time + the original
    # token (apply_to_words has already mutated the per-segment words[] but
    # word_segments is a separate array), then update.
    def apply_to_word_segments(data)
      target_start = data["segments"][@segment_index]["words"][@word_index]["start"]
      flat = data["word_segments"]
      window = nil
      flat.each_with_index do |entry, i|
        if entry["start"] == target_start && entry["word"] == @old_tokens.first
          window = i
          break
        end
      end
      if window.nil?
        raise ArgumentError,
              "word_segments realignment failed at segment #{@segment_index}, word #{@word_index}"
      end

      @new_tokens.each_with_index do |new_word, i|
        flat[window + i]["word"] = new_word if flat[window + i]
      end
    end

    def write_atomic(data)
      dir = @path.dirname
      tmp = Tempfile.create(["transcript", ".tmp"], dir.to_s)
      begin
        tmp.write(JSON.pretty_generate(data))
        tmp.close
        File.rename(tmp.path, @path.to_s)
      rescue StandardError
        File.unlink(tmp.path) if File.exist?(tmp.path)
        raise
      end
    end
  end
end
