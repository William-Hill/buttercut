require "spec_helper"
require_relative "../../../lib/buttercut_ui_sidecar/anthropic_client"

RSpec.describe ButtercutUiSidecar::AnthropicClient do
  # The wrapper takes a client factory so tests can inject a fake.
  class FakeSdk
    def initialize(response: nil, raise_with: nil)
      @response = response
      @raise_with = raise_with
      @calls = []
    end
    attr_reader :calls

    def messages
      self
    end

    def create(**kwargs)
      @calls << kwargs
      raise @raise_with if @raise_with
      @response
    end
  end

  it "validates a key with a 1-token Haiku ping and returns true on success" do
    fake = FakeSdk.new(response: { "content" => [{ "type" => "text", "text" => "ok" }] })
    client = described_class.new(api_key: "sk-test", sdk: fake)
    expect(client.validate_key!).to be true
    expect(fake.calls.first[:model]).to match(/haiku/i)
    expect(fake.calls.first[:max_tokens]).to eq(1)
  end

  it "raises InvalidApiKey when the SDK raises an auth error" do
    fake = FakeSdk.new(raise_with: described_class::FakeAuthError.new("invalid x-api-key"))
    client = described_class.new(api_key: "sk-bad", sdk: fake, auth_error_classes: [described_class::FakeAuthError])
    expect { client.validate_key! }.to raise_error(ButtercutUiSidecar::AnthropicClient::InvalidApiKey, /invalid/)
  end
end
