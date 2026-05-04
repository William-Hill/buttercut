# frozen_string_literal: true

require "json"
require "time"

module ButtercutUiSidecar
  # Writes JSON-RPC 2.0 notifications (payloads without an `id`) on a shared
  # output stream — the same stream that carries request/response. The Rust
  # reader distinguishes them by the absence of `id`. A mutex serializes
  # writes so notifications and responses don't interleave at the byte level.
  class Notifier
    def initialize(io:, mutex: Mutex.new)
      @io = io
      @mutex = mutex
      @io.sync = true if @io.respond_to?(:sync=)
    end

    def notify(method, **params)
      params[:ts] ||= Time.now.utc.iso8601(3)
      line = JSON.generate(jsonrpc: "2.0", method: method, params: params)
      @mutex.synchronize do
        @io.puts(line)
      end
    end
  end
end
