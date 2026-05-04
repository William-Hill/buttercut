# ui/sidecar/lib/buttercut_ui_sidecar/library_replacer.rb
# frozen_string_literal: true

require "date"
require "json"
require "pathname"
require "tempfile"
require "yaml"

require_relative "transcript_editor"
require_relative "transcript_finder"

module ButtercutUiSidecar
  # Library-wide replace orchestrator. Drives TranscriptFinder + TranscriptEditor
  # across every clip in a library under a single mutex acquisition. When
  # trust=true, idempotently appends new_tokens.join(" ") to library.yaml's
  # user_context. Emits one `transcript_edited` notification per affected clip.
  class LibraryReplacer
    def self.apply(libraries_root:, library:, old_tokens:, new_tokens:, trust:, notifier:, mutex: Mutex.new)
      new(
        libraries_root: libraries_root, library: library,
        old_tokens: old_tokens, new_tokens: new_tokens,
        trust: trust, notifier: notifier, mutex: mutex
      ).apply
    end

    def initialize(libraries_root:, library:, old_tokens:, new_tokens:, trust:, notifier:, mutex:)
      raise ArgumentError, "libraries_root required" if libraries_root.nil? || libraries_root.to_s.empty?
      raise ArgumentError, "library required" if library.nil? || library.to_s.empty?
      raise ArgumentError, "old_tokens required" if old_tokens.nil? || old_tokens.empty?
      raise ArgumentError, "new_tokens required" if new_tokens.nil? || new_tokens.empty?
      if old_tokens.length != new_tokens.length
        raise TranscriptEditor::TokenCountViolation,
              "new_tokens (#{new_tokens.length}) != old_tokens (#{old_tokens.length})"
      end
      if trust && new_tokens.length != 1
        raise ArgumentError, "trust mode requires a single-token replacement (got #{new_tokens.length})"
      end

      @libraries_root = libraries_root
      @library = library
      @old_tokens = old_tokens
      @new_tokens = new_tokens
      @trust = trust
      @notifier = notifier
      @mutex = mutex
    end

    def apply
      @mutex.synchronize do
        matches = TranscriptFinder.find(
          libraries_root: @libraries_root, library: @library,
          tokens: @old_tokens, scope: :library
        )

        per_clip = matches.group_by { |m| m[:clip] }
        affected_clips = []
        edit_count = 0

        per_clip.each do |clip, clip_matches|
          # Apply right-to-left within a clip so word_index values stay valid
          # across multiple edits in the same segment.
          clip_matches.sort_by { |m| [-m[:segment_index], -m[:word_index]] }.each do |m|
            TranscriptEditor.apply(
              libraries_root: @libraries_root, library: @library, clip: clip,
              edit: {
                segment_index: m[:segment_index],
                word_index: m[:word_index],
                old_tokens: @old_tokens,
                new_tokens: @new_tokens
              }
            )
            edit_count += 1
          end

          affected_clips << clip
          @notifier.notify("transcript_edited",
            library: @library, clip: clip, edit_count: clip_matches.size)
        end

        append_to_user_context if @trust && edit_count > 0

        { edit_count: edit_count, affected_clips: affected_clips }
      end
    end

    private

    def append_to_user_context
      yaml_path = Pathname.new(@libraries_root).join(@library, "library.yaml")
      return unless yaml_path.file?

      data = YAML.safe_load(yaml_path.read, permitted_classes: [Date, Time], aliases: true) || {}
      term = @new_tokens.join(" ")
      existing = (data["user_context"] || "").to_s
      return if existing.downcase.split(/\W+/).include?(term.downcase)

      data["user_context"] = existing.empty? ? term : "#{existing}\n#{term}"
      tmp_path = "#{yaml_path}.tmp"
      File.write(tmp_path, YAML.dump(data))
      File.rename(tmp_path, yaml_path.to_s)
    end
  end
end
