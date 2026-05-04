# frozen_string_literal: true

module ButtercutUiSidecar
  class JobRegistry
    def initialize
      @mutex = Mutex.new
      @jobs = {}
    end

    def put(id, job)
      @mutex.synchronize { @jobs[id] = job }
    end

    def get(id)
      @mutex.synchronize { @jobs[id] }
    end

    def delete(id)
      @mutex.synchronize { @jobs.delete(id) }
    end

    def each(&block)
      @mutex.synchronize { @jobs.values.dup }.each(&block)
    end
  end
end
