# frozen_string_literal: true

require "open3"
require "json"

module ButtercutUiSidecar
  class VideoInspector
    def inspect(paths)
      accepted = []
      rejected = []

      paths.each do |p|
        unless File.file?(p)
          rejected << { path: p, reason: "not_found" }
          next
        end

        info = probe(p)
        if info.nil?
          rejected << { path: p, reason: "not_video" }
        elsif info[:duration_seconds].to_f <= 0
          rejected << { path: p, reason: "zero_duration" }
        else
          accepted << { path: p, duration_seconds: info[:duration_seconds], size_bytes: File.size(p) }
        end
      end

      { accepted: accepted, rejected: rejected }
    end

    private

    def probe(path)
      cmd = ["ffprobe", "-v", "error", "-print_format", "json",
             "-show_format", "-show_streams", "-select_streams", "v:0", path]
      out, _err, status = Open3.capture3(*cmd)
      return nil unless status.success?
      data = JSON.parse(out) rescue nil
      return nil unless data && (data["streams"] || []).any? { |s| s["codec_type"] == "video" }
      duration = (data.dig("format", "duration") || 0).to_f
      { duration_seconds: duration }
    rescue StandardError
      nil
    end
  end
end
