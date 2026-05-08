# frozen_string_literal: true

require "json"
require "pathname"
require "yaml"
require "date"

# Make the parent gem's lib/ available so we can require buttercut/* helpers.
# Sidecar lives at <repo>/ui/sidecar/lib/buttercut_ui_sidecar/, so the gem's
# lib/ is four levels up.
gem_lib = File.expand_path("../../../../lib", __dir__)
$LOAD_PATH.unshift(gem_lib) unless $LOAD_PATH.include?(gem_lib)

require "buttercut/broll_director_inputs"
require "buttercut/broll_director_postprocess"
require "buttercut/broll_manifest"

require_relative "anthropic_client"

module ButtercutUiSidecar
  # UI-driven b-roll director. Mirrors RoughcutController's shape; loads the
  # same agent prompt as the broll-director skill so behavior cannot drift.
  class BrollDirectorController
    PROMPT_RELATIVE_PATH = ".claude/skills/broll-director/agent_prompt.md"
    DEFAULT_DENSITY = "medium"
    DEFAULT_SCORE_THRESHOLD = 0.5
    MODEL = AnthropicClient::VISION_MODEL

    def initialize(libraries_root:, repo_root:, notifier:, registry:, client:)
      raise ArgumentError, "libraries_root required" if libraries_root.to_s.empty?
      raise ArgumentError, "repo_root required" if repo_root.to_s.empty?
      raise ArgumentError, "notifier required" if notifier.nil?
      raise ArgumentError, "registry required" if registry.nil?
      raise ArgumentError, "client required" if client.nil?

      @libraries_root = Pathname.new(libraries_root)
      @repo_root = Pathname.new(repo_root)
      @notifier = notifier
      @registry = registry
      @client = client
    end

    def validate_and_start!(library:, roughcut_stem:, density: DEFAULT_DENSITY,
                            score_threshold: DEFAULT_SCORE_THRESHOLD)
      job_id = @registry.create(library)
      Thread.new do
        begin
          run!(
            library: library, roughcut_stem: roughcut_stem,
            density: density, score_threshold: score_threshold,
            job_id: job_id
          )
        rescue StandardError => e
          warn "[broll-director #{job_id}] FAILED #{e.class}: #{e.message}"
          @notifier.notify("broll_job_failed", job_id: job_id, message: e.message)
        end
      end
      job_id
    end

    def run!(library:, roughcut_stem:, density:, score_threshold:, job_id: nil)
      lib_dir = @libraries_root.join(library)
      roughcut_path = lib_dir.join("roughcuts", "#{roughcut_stem}.yaml")
      raise "rough cut not found at #{roughcut_path}" unless roughcut_path.file?

      notify(job_id, "broll_job_started", library: library, roughcut_stem: roughcut_stem)
      notify(job_id, "broll_phase", phase: "gather", message: "Gathering transcripts and templates…")

      inputs = ButterCut::BrollDirectorInputs.gather(
        library_dir: lib_dir.to_s,
        roughcut_path: roughcut_path.to_s,
        hyperframes_dir: @repo_root.join("hyperframes").to_s
      )

      notify(job_id, "broll_phase", phase: "model", message: "Asking the director for candidates…")
      raw = call_model(inputs, density, score_threshold)
      candidates = parse_or_retry(raw, inputs, density, score_threshold)

      notify(job_id, "broll_phase", phase: "write", message: "Validating and writing manifest…")
      manifest_hash = ButterCut::BrollDirectorPostprocess.assemble(
        library_name: inputs[:library_name],
        roughcut_stem: inputs[:roughcut_stem],
        roughcut: inputs[:roughcut],
        candidates: candidates,
        available_templates: inputs[:available_templates],
        density: density,
        score_threshold: score_threshold
      )

      manifest_path = lib_dir.join("roughcuts", "#{roughcut_stem}.broll.yaml")
      warn_if_overwriting(manifest_path)
      ButterCut::BrollManifest.from_hash(manifest_hash).save(manifest_path.to_s)

      notify(job_id, "broll_job_done",
             manifest_path: manifest_path.to_s,
             entries_written: manifest_hash["entries"].length,
             density: density)

      { manifest_path: manifest_path.to_s, entries_written: manifest_hash["entries"].length }
    end

    private

    def notify(job_id, event, **payload)
      return if job_id.nil?
      @notifier.notify(event, job_id: job_id, **payload)
    end

    def call_model(inputs, density, score_threshold)
      system = prompt_text
      user = JSON.pretty_generate(
        LIBRARY_NAME: inputs[:library_name],
        ROUGHCUT_STEM: inputs[:roughcut_stem],
        ROUGHCUT_YAML: inputs[:roughcut],
        THEME: inputs[:theme],
        SOURCE_VIDEOS: inputs[:source_videos],
        AVAILABLE_TEMPLATES: inputs[:available_templates],
        DENSITY: density,
        SCORE_THRESHOLD: score_threshold
      )
      @client.complete(system: system, user: user, model: MODEL)
    end

    def parse_or_retry(raw, _inputs, _density, _score_threshold)
      JSON.parse(raw)
    rescue JSON::ParserError => e
      retry_user = "Your previous response was not valid JSON: #{e.message}\n\n" \
                   "Return ONLY the JSON array, no surrounding text."
      raw2 = @client.complete(system: prompt_text, user: retry_user, model: MODEL)
      JSON.parse(raw2)
    end

    def prompt_text
      path = @repo_root.join(PROMPT_RELATIVE_PATH)
      raise "broll-director prompt missing: #{path}" unless path.file?
      path.read
    end

    def warn_if_overwriting(path)
      return unless path.file?
      prior = begin
        YAML.safe_load(path.read, permitted_classes: [Date, Time])
      rescue StandardError
        {}
      end
      n = (prior["entries"] || []).length
      warn "[broll-director] overwriting existing manifest at #{path} (#{n} prior entries)"
    end
  end
end
