# frozen_string_literal: true

require "concurrent"

module ButtercutUiSidecar
  class AnalysisJob
    attr_reader :id, :library

    def initialize(id:, library:)
      @id = id
      @library = library
      @cancel_flag = Concurrent::AtomicBoolean.new(false)
      @pids = Concurrent::Array.new
      @abortables = Concurrent::Array.new
      @library_yaml_mutex = Mutex.new
    end

    def canceled?
      @cancel_flag.true?
    end

    def cancel!
      return if @cancel_flag.true?
      @cancel_flag.make_true
      pids = @pids.dup
      pids.each do |pid|
        Process.kill("TERM", pid)
      rescue Errno::ESRCH
      end
      sleep 2
      pids.each do |pid|
        Process.kill("KILL", pid)
      rescue Errno::ESRCH, Errno::ECHILD
      end
      @abortables.dup.each do |h|
        h.abort! if h.respond_to?(:abort!)
      end
    end

    def register_pid(pid)
      if @cancel_flag.true?
        terminate_pid_immediate(pid)
      else
        @pids << pid
      end
    end

    def unregister_pid(pid)
      @pids.delete(pid)
    end

    def register_abortable(handle)
      @abortables << handle
    end

    def unregister_abortable(handle)
      @abortables.delete(handle)
    end

    # Yields with the per-library yaml mutex held. Use for read-modify-write of library.yaml.
    def with_yaml_lock
      @library_yaml_mutex.synchronize { yield }
    end

    private

    def terminate_pid_immediate(pid)
      Process.kill("TERM", pid)
      sleep 0.1
      Process.kill("KILL", pid)
    rescue Errno::ESRCH, Errno::ECHILD
      # already gone
    end
  end
end
