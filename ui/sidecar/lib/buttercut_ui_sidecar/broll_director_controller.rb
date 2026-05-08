# frozen_string_literal: true

require "json"
require "pathname"
require "securerandom"
require "yaml"
require "date"

require "buttercut/broll_director_inputs"
require "buttercut/broll_director_postprocess"
require "buttercut/broll_manifest"

require_relative "analysis_job"
require_relative "anthropic_client"

module ButtercutUiSidecar
  class BrollDirectorController
    PROMPT_RELATIVE_PATH = ".claude/skills/broll-director/agent_prompt.md"
    DEFAULT_DENSITY = "medium"
    DEFAULT_SCORE_THRESHOLD = 0.5
    MODEL = AnthropicClient::VISION_MODEL

    EVENT_STARTED = "broll_job_started"
    EVENT_PHASE   = "broll_phase"
    EVENT_DONE    = "broll_job_done"
    EVENT_FAILED  = "broll_job_failed"

    PHASE_GATHER = "gather"
    PHASE_MODEL  = "model"
    PHASE_WRITE  = "write"

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
      stem = safe_roughcut_stem!(roughcut_stem)
      roughcut_path = @libraries_root.join(library, "roughcuts", "#{stem}.yaml")
      raise "rough cut not found at #{roughcut_path}" unless roughcut_path.file?

      job_id = "job-#{SecureRandom.hex(6)}"
      @registry.put(job_id, AnalysisJob.new(id: job_id, library: library))

      Thread.new do
        begin
          run!(
            library: library, roughcut_stem: stem,
            density: density, score_threshold: score_threshold,
            job_id: job_id
          )
        rescue StandardError => e
          warn "[broll-director #{job_id}] FAILED #{e.class}: #{e.message}"
          @notifier.notify(EVENT_FAILED, job_id: job_id, message: e.message)
        ensure
          @registry.delete(job_id)
        end
      end
      job_id
    end

    def run!(library:, roughcut_stem:, density:, score_threshold:, job_id: nil)
      stem = safe_roughcut_stem!(roughcut_stem)
      lib_dir = @libraries_root.join(library)
      roughcut_path = lib_dir.join("roughcuts", "#{stem}.yaml")
      raise "rough cut not found at #{roughcut_path}" unless roughcut_path.file?

      notify(job_id, EVENT_STARTED, library: library, roughcut_stem: stem)
      notify(job_id, EVENT_PHASE, phase: PHASE_GATHER, message: "Gathering transcripts and templates…")

      inputs = ButterCut::BrollDirectorInputs.gather(
        library_dir: lib_dir.to_s,
        roughcut_path: roughcut_path.to_s,
        hyperframes_dir: @repo_root.join("hyperframes").to_s
      )

      notify(job_id, EVENT_PHASE, phase: PHASE_MODEL, message: "Asking the director for candidates…")
      candidates = JSON.parse(call_model(inputs, density, score_threshold))

      notify(job_id, EVENT_PHASE, phase: PHASE_WRITE, message: "Validating and writing manifest…")
      manifest_hash = ButterCut::BrollDirectorPostprocess.assemble(
        library_name: inputs[:library_name],
        roughcut_stem: inputs[:roughcut_stem],
        roughcut: inputs[:roughcut],
        candidates: candidates,
        available_templates: inputs[:available_templates],
        density: density,
        score_threshold: score_threshold
      )

      manifest_path = lib_dir.join("roughcuts", "#{stem}.broll.yaml")
      warn_if_overwriting(manifest_path)
      ButterCut::BrollManifest.from_hash(manifest_hash).save(manifest_path.to_s)

      notify(job_id, EVENT_DONE,
             manifest_path: manifest_path.to_s,
             entries_written: manifest_hash["entries"].length,
             density: density)

      { manifest_path: manifest_path.to_s, entries_written: manifest_hash["entries"].length }
    end

    private

    def safe_roughcut_stem!(roughcut_stem)
      stem = roughcut_stem.to_s
      if stem.empty? || stem != File.basename(stem) || stem.include?("/") || stem.include?("\\")
        raise ArgumentError, "invalid roughcut_stem: #{roughcut_stem.inspect}"
      end
      stem
    end

    def notify(job_id, event, **payload)
      return if job_id.nil?
      @notifier.notify(event, job_id: job_id, **payload)
    end

    def call_model(inputs, density, score_threshold)
      user = JSON.generate(
        LIBRARY_NAME: inputs[:library_name],
        ROUGHCUT_STEM: inputs[:roughcut_stem],
        ROUGHCUT_YAML: inputs[:roughcut],
        THEME: inputs[:theme],
        SOURCE_VIDEOS: inputs[:source_videos],
        AVAILABLE_TEMPLATES: inputs[:available_templates],
        DENSITY: density,
        SCORE_THRESHOLD: score_threshold
      )
      @client.complete(system: prompt_text, user: user, model: MODEL)
    end

    def prompt_text
      @prompt_text ||= begin
        path = @repo_root.join(PROMPT_RELATIVE_PATH)
        raise "broll-director prompt missing: #{path}" unless path.file?
        path.read
      end
    end

    def warn_if_overwriting(path)
      prior = YAML.safe_load(path.read, permitted_classes: [Date, Time], aliases: true) || {}
      n = Array(prior["entries"]).length
      warn "[broll-director] overwriting existing manifest at #{path} (#{n} prior entries)"
    rescue Errno::ENOENT
      nil
    rescue Psych::Exception, TypeError => e
      warn "[broll-director] overwriting unreadable manifest at #{path} (#{e.class}: #{e.message})"
      nil
    end
  end
end
