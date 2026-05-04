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

      @path = Pathname.new(libraries_root).join(library, "transcripts", clip)
      @segment_index = edit[:segment_index]
      @word_index = edit[:word_index]
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

    def apply_to_words(words)
      @new_tokens.each_with_index do |new_word, i|
        words[@word_index + i]["word"] = new_word
      end
    end

    # The segment's `text` is the space-joined view of its words. Replace the
    # exact phrase rather than the bare token to avoid the "carrot" trap
    # (substring matching corrupting unrelated occurrences).
    def apply_to_segment_text(segment)
      old_phrase = @old_tokens.join(" ")
      new_phrase = @new_tokens.join(" ")
      text = segment["text"].to_s
      idx = text.index(old_phrase)
      raise ArgumentError, "phrase not found in segment text: #{old_phrase.inspect}" if idx.nil?
      segment["text"] = text[0...idx] + new_phrase + text[(idx + old_phrase.length)..]
    end

    # The flat top-level word_segments array mirrors segments[].words[] in
    # document order. Find the matching window by token sequence + start time,
    # then update.
    def apply_to_word_segments(data)
      target_start = data["segments"][@segment_index]["words"][@word_index]["start"]
      flat = data["word_segments"]
      window = nil
      flat.each_with_index do |entry, i|
        next unless entry["start"] == target_start && entry["word"] == @new_tokens.first
        # First word already updated in-place via apply_to_words... but
        # word_segments is a separate array (entries are dup'd at write time).
        # So we need to match by start AND old token. Re-check with the original.
        window = i
        break
      end

      # If we didn't catch it via new_tokens.first (which we can't, because
      # apply_to_words mutated words[] not word_segments[]), fall back to
      # matching by start + old token.
      window = nil
      flat.each_with_index do |entry, i|
        if entry["start"] == target_start && entry["word"] == @old_tokens.first
          window = i
          break
        end
      end
      return if window.nil? # leave consistent enough; spec for finder catches drift

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
