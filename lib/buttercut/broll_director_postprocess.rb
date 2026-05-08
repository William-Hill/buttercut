require "set"
require_relative "broll_manifest"
require_relative "timecode"

class ButterCut
  class BrollDirectorPostprocess
    DENSITY_BUDGETS = { "low" => 2, "medium" => 4, "high" => 8 }.freeze

    def self.assemble(library_name:, roughcut_stem:, roughcut:, candidates:,
                      available_templates:, density:, score_threshold:)
      new(
        library_name: library_name,
        roughcut_stem: roughcut_stem,
        roughcut: roughcut,
        candidates: candidates,
        available_templates: available_templates,
        density: density,
        score_threshold: score_threshold
      ).assemble
    end

    def initialize(library_name:, roughcut_stem:, roughcut:, candidates:,
                   available_templates:, density:, score_threshold:)
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

    def locate_in_cut(c)
      cursor = 0.0
      @roughcut["clips"].each do |clip|
        clip_in = ButterCut::Timecode.to_seconds(clip["in"])
        clip_out = ButterCut::Timecode.to_seconds(clip["out"])
        clip_len = clip_out - clip_in

        if clip["source_video"] == c["source_video"]
          s = c["source_start"].to_f
          e = c["source_end"].to_f
          if e > clip_in && s < clip_out
            mapped_start = cursor + [s, clip_in].max - clip_in
            mapped_end   = cursor + [e, clip_out].min - clip_in
            return nil if mapped_end <= mapped_start
            return { start: mapped_start.round(2), end: mapped_end.round(2) }
          end
        end

        cursor += clip_len
      end
      nil
    end

    def apply_density(entries)
      buckets = entries.group_by { |e| (e["start"] / 60.0).floor }
      buckets.values.flat_map { |list|
        list.sort_by { |e| -e["score"] }.first(@budget)
      }.sort_by { |e| e["start"] }
    end
  end
end
