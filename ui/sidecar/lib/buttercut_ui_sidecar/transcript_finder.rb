# ui/sidecar/lib/buttercut_ui_sidecar/transcript_finder.rb
# frozen_string_literal: true

require "date"
require "json"
require "pathname"
require "yaml"

module ButtercutUiSidecar
  # Searches WhisperX transcripts for a token sequence using whole-token
  # matching. Returns each match with the clip filename, segment index,
  # word index, the actual cased token slice, and a short surrounding-context
  # snippet for the UI.
  #
  # Whole-token (NOT substring) matching is load-bearing: searching `car`
  # MUST NOT match `carrot`. Comparison is case-insensitive on input, but the
  # returned :matched_tokens preserves the actual case from the transcript.
  class TranscriptFinder
    CONTEXT_WORDS = 4 # words on either side of the match

    def self.find(libraries_root:, library:, tokens:, scope:, clip: nil)
      new(libraries_root: libraries_root, library: library, tokens: tokens, scope: scope, clip: clip).find
    end

    def initialize(libraries_root:, library:, tokens:, scope:, clip:)
      raise ArgumentError, "libraries_root required" if libraries_root.nil? || libraries_root.to_s.empty?
      raise ArgumentError, "library required" if library.nil? || library.to_s.empty?
      raise ArgumentError, "tokens required" if tokens.nil? || tokens.empty?
      raise ArgumentError, "scope must be :clip or :library" unless %i[clip library].include?(scope)
      raise ArgumentError, "clip required when scope=:clip" if scope == :clip && (clip.nil? || clip.empty?)

      @lib_dir = Pathname.new(libraries_root).join(library)
      @tokens_lc = tokens.map { |t| t.downcase }
      @scope = scope
      @clip = clip
    end

    def find
      transcripts.flat_map { |path| matches_in(path) }
    end

    private

    def transcripts
      if @scope == :clip
        [@lib_dir.join("transcripts", @clip)]
      else
        clip_filenames_from_yaml.map { |c| @lib_dir.join("transcripts", c) }
      end.select(&:file?)
    end

    def clip_filenames_from_yaml
      yaml_path = @lib_dir.join("library.yaml")
      return [] unless yaml_path.file?
      data = YAML.safe_load(yaml_path.read, permitted_classes: [Date, Time], aliases: true) || {}
      (data["videos"] || []).filter_map { |v| v["transcript"] if v["transcript"] && !v["transcript"].to_s.empty? }
    end

    def matches_in(path)
      data = JSON.parse(path.read)
      clip = path.basename.to_s
      results = []
      (data["segments"] || []).each_with_index do |segment, seg_idx|
        words = segment["words"] || []
        next if words.length < @tokens_lc.length
        words.each_with_index do |_, word_idx|
          window = words[word_idx, @tokens_lc.length]
          window_lc = window.map { |w| w["word"].to_s.downcase }
          next unless window_lc == @tokens_lc

          results << {
            clip: clip,
            segment_index: seg_idx,
            word_index: word_idx,
            matched_tokens: window.map { |w| w["word"] },
            context_snippet: snippet(words, word_idx, @tokens_lc.length)
          }
        end
      end
      results
    end

    def snippet(words, start, length)
      from = [start - CONTEXT_WORDS, 0].max
      to = [start + length + CONTEXT_WORDS, words.length].min
      words[from...to].map { |w| w["word"] }.join(" ")
    end
  end
end
