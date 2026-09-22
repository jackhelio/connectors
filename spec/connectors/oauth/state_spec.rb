require "rails_helper"

RSpec.describe Connectors::OAuth::State do
  include ActiveSupport::Testing::TimeHelpers

  let(:payload) do
    { connector_key: :example, owner_gid: "gid://dummy/Owner/123",
      extra: { "cv" => "private-pkce-verifier", "ts" => "private-oauth1-secret" } }
  end

  it "round-trips secrets without exposing them in base64-decodable state" do
    token = described_class.encode(**payload)
    expect(described_class.decode(token)).to include("k" => "example", "x" => payload[:extra])
    decoded_segments = token.split("--").map { |segment| Base64.decode64(segment) }.join
    payload[:extra].each_value { |secret| expect(decoded_segments).not_to include(secret) }
    expect(described_class.encode(**payload)).not_to eq(token)
  end

  it "rejects tampering" do
    token = described_class.encode(**payload)
    token[0] = token[0] == "a" ? "b" : "a"
    expect(described_class.decode(token)).to be_nil
  end

  it "expires after the authorization window" do
    token = described_class.encode(**payload)
    travel Connectors::OAuth::State::EXPIRES_IN + 1.second do
      expect(described_class.decode(token)).to be_nil
    end
  end

  it "rejects missing, malformed and legacy signed state" do
    legacy = Rails.application.message_verifier(described_class::PURPOSE).generate(payload)
    [ nil, "", "invalid", [], {}, legacy ].each { |token| expect(described_class.decode(token)).to be_nil }
  end
end
