#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "yaml"
require "time"
require "pathname"

class ButtercutUiSidecar
  def self.run(libraries_root:, io_in: $stdin, io_out: $stdout)
    new(libraries_root: libraries_root, io_in: io_in, io_out: io_out).run
  end

  def initialize(libraries_root:, io_in:, io_out:)
    raise ArgumentError, "libraries_root required" if libraries_root.nil? || libraries_root.to_s.empty?

    @libraries_root = Pathname.new(libraries_root)
    @io_in = io_in
    @io_out = io_out
    @io_out.sync = true
  end

  def run
    @io_in.each_line do |line|
      line = line.strip
      next if line.empty?

      handle_line(line)
    end
  end

  private

  def handle_line(line)
    request = JSON.parse(line)
    id = request["id"]
    method = request["method"]
    params = request["params"] || {}

    result = dispatch(method, params)
    respond(id: id, result: result)
  rescue JSON::ParserError => e
    respond_error(id: nil, code: -32700, message: "parse error: #{e.message}")
  rescue UnknownMethod => e
    respond_error(id: id, code: -32601, message: e.message)
  rescue StandardError => e
    respond_error(id: id, code: -32000, message: "#{e.class}: #{e.message}")
  end

  def dispatch(method, _params)
    case method
    when "ping"           then "pong"
    when "list_libraries" then list_libraries
    else raise UnknownMethod, "unknown method: #{method}"
    end
  end

  def list_libraries
    Pathname.glob(@libraries_root.join("*", "library.yaml")).filter_map do |yaml_path|
      summarize_library(yaml_path)
    rescue Errno::ENOENT, Errno::EISDIR
      nil
    end.sort_by { |lib| -Time.parse(lib[:last_touched_at]).to_i }
  end

  def summarize_library(yaml_path)
    data = YAML.safe_load(yaml_path.read, permitted_classes: [Date, Time], aliases: true) || {}
    {
      name: data["library_name"] || yaml_path.parent.basename.to_s,
      video_count: (data["videos"] || []).length,
      last_touched_at: yaml_path.mtime.utc.iso8601
    }
  end

  def respond(id:, result:)
    @io_out.puts JSON.generate(jsonrpc: "2.0", id: id, result: result)
  end

  def respond_error(id:, code:, message:)
    @io_out.puts JSON.generate(jsonrpc: "2.0", id: id, error: { code: code, message: message })
  end

  class UnknownMethod < StandardError; end
end

if __FILE__ == $PROGRAM_NAME
  libraries_root = ARGV[0]
  if libraries_root.nil? || libraries_root.empty?
    warn "usage: buttercut_ui_sidecar.rb <libraries_root>"
    exit 1
  end

  ButtercutUiSidecar.run(libraries_root: libraries_root)
end
