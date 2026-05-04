# frozen_string_literal: true

require "fileutils"
require "pathname"
require "securerandom"
require "time"
require "yaml"

module ButtercutUiSidecar
  # Per-library stack of edit briefs (plain-language prompts + target duration).
  class BriefStore
    CATALOG = "catalog.yaml"

    def initialize(libraries_root:, library:)
      raise ArgumentError, "libraries_root required" if libraries_root.nil? || libraries_root.to_s.empty?
      raise ArgumentError, "library required" if library.nil? || library.to_s.empty?

      @lib_dir = Pathname.new(libraries_root).join(library)
      @briefs_dir = @lib_dir.join("briefs")
      @catalog_path = @briefs_dir.join(CATALOG)
    end

    def list
      data = read_catalog
      briefs = (data["briefs"] || []).map(&:dup)
      # Newest first by updated_at; on timestamp ties, later catalog rows win (stable fork-after-parent).
      briefs.each_with_index.sort_by { |(b, i)| [brief_sort_epoch(b["updated_at"]), i] }.map(&:first).reverse
    end

    def upsert(id:, prompt:, target_duration_seconds:, title: nil)
      raise ArgumentError, "prompt required" if prompt.nil? || prompt.to_s.strip.empty?
      n = Integer(target_duration_seconds)
      raise ArgumentError, "target_duration_seconds must be positive" if n <= 0

      now = Time.now.utc.iso8601(3)
      with_catalog_lock do
        data = read_catalog
        rows = data["briefs"] || []

        if id && !id.to_s.empty?
          row = rows.find { |r| r["id"] == id }
          raise ArgumentError, "unknown brief id: #{id}" if row.nil?

          row["prompt"] = prompt.to_s
          row["target_duration_seconds"] = n
          row["title"] = title.to_s unless title.nil?
          row["updated_at"] = now
        else
          row = {
            "id" => "b-#{SecureRandom.urlsafe_base64(9)}",
            "parent_id" => nil,
            "prompt" => prompt.to_s,
            "target_duration_seconds" => n,
            "title" => title.to_s,
            "created_at" => now,
            "updated_at" => now
          }
          rows << row
        end

        write_catalog!("briefs" => rows)
        row["id"]
      end
    end

    def fork(parent_id:)
      pid = parent_id.to_s
      with_catalog_lock do
        data = read_catalog
        rows = data["briefs"] || []
        parent = rows.find { |r| r["id"] == pid }
        raise ArgumentError, "unknown parent brief: #{parent_id}" if parent.nil?

        now = Time.now.utc.iso8601(3)
        row = {
          "id" => "b-#{SecureRandom.urlsafe_base64(9)}",
          "parent_id" => pid,
          "prompt" => parent["prompt"].to_s,
          "target_duration_seconds" => Integer(parent["target_duration_seconds"]),
          "title" => parent["title"].to_s,
          "created_at" => now,
          "updated_at" => now
        }
        rows << row
        write_catalog!("briefs" => rows)
        row["id"]
      end
    end

    def get(id)
      rows = read_catalog["briefs"] || []
      rows.find { |r| r["id"] == id }
    end

    private

    def with_catalog_lock
      raise "library directory missing: #{@lib_dir}" unless @lib_dir.directory?

      @briefs_dir.mkpath
      lock_path = @briefs_dir.join(".catalog.lock")
      File.open(lock_path, File::CREAT | File::RDWR) do |lock_io|
        lock_io.flock(File::LOCK_EX)
        yield
      end
    end

    def brief_sort_epoch(value)
      Time.parse(value.to_s).to_i
    rescue ArgumentError, TypeError
      0
    end

    def read_catalog
      return { "briefs" => [] } unless @catalog_path.file?

      YAML.safe_load(@catalog_path.read, permitted_classes: [Time, Date], aliases: true) || { "briefs" => [] }
    end

    def write_catalog!(data)
      tmp = nil
      raise "library directory missing: #{@lib_dir}" unless @lib_dir.directory?

      @briefs_dir.mkpath
      tmp = @briefs_dir.join("catalog.#{Process.pid}.#{SecureRandom.hex(6)}.tmp")
      File.write(tmp, YAML.dump(data))
      File.rename(tmp.to_s, @catalog_path.to_s)
    ensure
      FileUtils.rm_f(tmp.to_s) if tmp&.to_s && File.exist?(tmp.to_s)
    end
  end
end
