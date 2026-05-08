require "set"
require_relative "broll_manifest"
require_relative "timecode"

class ButterCut
  class BrollDirectorPostprocess
    DENSITY_BUDGETS = { "low" => 2, "medium" => 4, "high" => 8 }.freeze

    def self.assemble(library_name:, roughcut_stem:, roughcut:, candidates:,
                      available_templates:, density:, score_threshold:,
                      blacklist_terms: [], code_vocabulary: [])
      new(
        library_name: library_name,
        roughcut_stem: roughcut_stem,
        roughcut: roughcut,
        candidates: candidates,
        available_templates: available_templates,
        density: density,
        score_threshold: score_threshold,
        blacklist_terms: blacklist_terms,
        code_vocabulary: code_vocabulary
      ).assemble
    end

    def initialize(library_name:, roughcut_stem:, roughcut:, candidates:,
                   available_templates:, density:, score_threshold:,
                   blacklist_terms: [], code_vocabulary: [])
      raise ArgumentError, "candidates must be an array, got #{candidates.class}" unless candidates.is_a?(Array)
      bad = candidates.reject { |c| c.is_a?(Hash) }
      raise ArgumentError, "every candidate must be a hash; got #{bad.first.class} at index #{candidates.index(bad.first)}" unless bad.empty?

      @library_name = library_name
      @roughcut_stem = roughcut_stem
      @roughcut = roughcut
      @candidates = candidates
      @template_names = available_templates.map { |t| t[:name] || t["name"] }.to_set
      @budget = DENSITY_BUDGETS.fetch(density) {
        raise ArgumentError, "density must be one of #{DENSITY_BUDGETS.keys.inspect}, got #{density.inspect}"
      }
      threshold = begin
        Float(score_threshold)
      rescue TypeError, ArgumentError
        raise ArgumentError, "score_threshold must be a finite number between 0.0 and 1.0, got #{score_threshold.inspect}"
      end
      unless threshold.finite? && threshold.between?(0.0, 1.0)
        raise ArgumentError, "score_threshold must be a finite number between 0.0 and 1.0, got #{score_threshold.inspect}"
      end
      @score_threshold = threshold
      raise ArgumentError, "blacklist_terms must be an array, got #{blacklist_terms.class}" unless blacklist_terms.is_a?(Array)
      @blacklist_terms = blacklist_terms.map { |t| t.to_s.downcase.strip }.reject(&:empty?)
      raise ArgumentError, "code_vocabulary must be an array, got #{code_vocabulary.class}" unless code_vocabulary.is_a?(Array)
      @code_vocabulary = code_vocabulary.map { |t| t.to_s.downcase.strip }.reject(&:empty?).to_set
      @clip_windows = build_clip_windows(@roughcut["clips"])
    end

    def assemble
      mapped = @candidates.filter_map { |c| map_candidate(c) }
      mapped = apply_density(mapped)
      mapped.each_with_index { |e, i| e["id"] = format("br-%04d", i + 1) }
      manifest = {
        "version" => ButterCut::BrollManifest::SCHEMA_VERSION,
        "library" => @library_name,
        "roughcut" => @roughcut_stem,
        "entries" => mapped
      }
      ButterCut::BrollManifest.from_hash(manifest)
      manifest
    end

    private

    def map_candidate(c)
      return nil unless @template_names.include?(c["template"])
      score = c["score"].to_f
      return nil if score < @score_threshold
      return nil if blacklisted?(c)
      return nil if c["template"] == "code-callout" && !valid_code_command?(c["content"])

      mapping = locate_in_cut(c)
      return nil if mapping.nil?

      {
        "source_video" => c["source_video"],
        "start" => mapping[:start],
        "end" => mapping[:end],
        "template" => c["template"],
        "placement" => c["placement"],
        "score" => score,
        "content" => c["content"],
        "rendered" => nil,
        "notes" => c["rationale"].to_s
      }
    end

    def build_clip_windows(clips)
      cursor = 0.0
      clips.map do |clip|
        clip_in = ButterCut::Timecode.to_seconds(clip["in"])
        clip_out = ButterCut::Timecode.to_seconds(clip["out"])
        window = {
          source_video: clip["source_video"],
          in_s: clip_in,
          out_s: clip_out,
          cursor: cursor
        }
        cursor += (clip_out - clip_in)
        window
      end
    end

    def locate_in_cut(c)
      s = c["source_start"].to_f
      e = c["source_end"].to_f
      @clip_windows.each do |w|
        next unless w[:source_video] == c["source_video"]
        next unless e > w[:in_s] && s < w[:out_s]

        mapped_start = w[:cursor] + [s, w[:in_s]].max - w[:in_s]
        mapped_end   = w[:cursor] + [e, w[:out_s]].min - w[:in_s]
        return nil if mapped_end <= mapped_start
        return { start: mapped_start.round(2), end: mapped_end.round(2) }
      end
      nil
    end

    # A code-callout `command` should look like a shell/code string, not prose.
    # Verbal-form leakage from transcription ("dash i tilde three") shows up
    # as 3+ alphabetic words with no punctuation, no digits, and no token
    # the library has marked as code vocabulary. Drop those — better to
    # render nothing than confidently wrong code.
    CODE_PUNCT = /[^\p{L}\p{N}\s_]/u.freeze

    def valid_code_command?(content)
      return false unless content.is_a?(Hash)
      cmd = content["command"].to_s.strip
      return false if cmd.empty?

      return true if cmd.match?(CODE_PUNCT)
      return true if cmd.match?(/\d/)

      tokens = cmd.downcase.split(/\s+/)
      return true if tokens.any? { |t| @code_vocabulary.include?(t) }
      tokens.length < 3
    end

    def blacklisted?(c)
      return false if @blacklist_terms.empty?
      haystack = content_text(c["content"]).downcase
      return false if haystack.empty?
      @blacklist_terms.any? { |term| haystack.include?(term) }
    end

    def content_text(content)
      case content
      when Hash then content.values.map { |v| content_text(v) }.join(" ")
      when Array then content.map { |v| content_text(v) }.join(" ")
      when nil then ""
      else content.to_s
      end
    end

    def apply_density(entries)
      buckets = entries.group_by { |e| (e["start"] / 60.0).floor }
      buckets.values.flat_map { |list|
        list.sort_by { |e| -e["score"] }.first(@budget)
      }.sort_by { |e| e["start"] }
    end
  end
end
