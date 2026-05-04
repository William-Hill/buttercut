# frozen_string_literal: true

module ButtercutUiSidecar
  # Shared blank-check for transcript paths, YAML fields, etc.
  module Presence
    module_function

    def present?(value)
      !value.nil? && !value.to_s.empty?
    end
  end
end
