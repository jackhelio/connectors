require "rails_helper"

RSpec.describe Connectors::OAuth::TokenResponse do
  def response(body, status: 200)
    instance_double(Faraday::Response, status: status, body: body)
  end

  it "accepts form-encoded token responses" do
    expect(described_class.parse(response("access_token=token&expires_in=3600")))
      .to eq("access_token" => "token", "expires_in" => "3600")
  end

  [ "", "null", "[]", '"token"', '{"scope":"read"}', '{"access_token":["secret"]}', '{"ok":false,"access_token":"secret"}' ].each do |body|
    it "rejects an invalid token response #{body.inspect} without leaking its contents" do
      expect { described_class.parse(response(body)) }.to raise_error(Connectors::AuthenticationFailed) { |error|
        expect(error.message).to include("invalid token response")
        expect(error.message).not_to include("secret")
      }
    end
  end

  it "rejects non-success status even if the body contains a token" do
    expect { described_class.parse(response('{"access_token":"secret"}', status: 500)) }
      .to raise_error(Connectors::AuthenticationFailed, /invalid token response/)
  end

  it "normalizes string absolute expiries and preserves omitted refresh tokens as absent" do
    tokens = described_class.normalize("access_token" => "token", "expires_at" => "1900000000")
    expect(tokens).to eq("access_token" => "token", "expires_at" => 1900000000)
  end
end
