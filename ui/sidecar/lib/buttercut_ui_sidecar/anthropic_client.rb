# frozen_string_literal: true

module ButtercutUiSidecar
  # Thin wrapper around the anthropic gem. Holds the api_key, exposes
  # `validate_key!` (single Haiku ping) and `messages_create` (regular calls).
  # Auth errors surface as InvalidApiKey; everything else propagates.
  class AnthropicClient
    HAIKU_MODEL = "claude-haiku-4-5-20251001"
    VISION_MODEL = "claude-sonnet-4-6"

    class InvalidApiKey < StandardError; end
    class FakeAuthError < StandardError; end # used only in tests

    def initialize(api_key:, sdk: nil, auth_error_classes: nil)
      raise ArgumentError, "api_key required" if api_key.nil? || api_key.empty?
      @api_key = api_key
      @sdk = sdk || build_sdk(api_key)
      @auth_error_classes = auth_error_classes || default_auth_error_classes
    end

    def validate_key!
      @sdk.messages.create(
        model: HAIKU_MODEL,
        max_tokens: 1,
        messages: [{ role: "user", content: "ping" }]
      )
      true
    rescue *@auth_error_classes => e
      raise InvalidApiKey, e.message
    end

    def messages_create(**kwargs)
      @sdk.messages.create(**kwargs)
    rescue *@auth_error_classes => e
      raise InvalidApiKey, e.message
    end

    private

    def build_sdk(api_key)
      require "anthropic"
      Anthropic::Client.new(api_key: api_key)
    end

    def default_auth_error_classes
      classes = []
      begin
        require "anthropic"
        classes << Anthropic::AuthenticationError if defined?(Anthropic::AuthenticationError)
      rescue LoadError
        # fall through; tests inject explicit classes
      end
      classes
    end
  end
end
