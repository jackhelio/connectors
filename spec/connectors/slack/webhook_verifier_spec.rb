require "rails_helper"

RSpec.describe Slack::WebhookVerifier do
  let(:signing_secret) { "8f7a3b2c1d0e9f8a7b6c5d4e3f2a1b0c" }
  let(:grant)          { instance_double(Connectors::Grant, id: 1) }
  let(:body)           { '{"type":"event_callback","event":{"type":"message"}}' }
  let(:timestamp)      { Time.now.to_i.to_s }

  before do
    Connectors.configure { |c| c.oauth_credentials = { slack: { signing_secret: signing_secret } } }
  end

  def signature_for(ts, raw_body, secret: signing_secret)
    "v0=" + OpenSSL::HMAC.hexdigest("SHA256", secret, "v0:#{ts}:#{raw_body}")
  end

  def fake_request(headers: {}, raw_post: body)
    instance_double(ActionDispatch::Request, headers: headers, raw_post: raw_post)
  end

  it "accepts a request with a valid signature within the timestamp tolerance" do
    req = fake_request(
      headers: {
        "X-Slack-Request-Timestamp" => timestamp,
        "X-Slack-Signature"         => signature_for(timestamp, body)
      }
    )
    expect { described_class.verify!(grant, req) }.not_to raise_error
  end

  it "rejects a request with a mismatched signature" do
    req = fake_request(
      headers: {
        "X-Slack-Request-Timestamp" => timestamp,
        "X-Slack-Signature"         => "v0=deadbeef"
      }
    )
    expect { described_class.verify!(grant, req) }
      .to raise_error(Connectors::Webhooks::SignatureInvalid, /mismatch/)
  end

  it "rejects a request signed with the wrong secret" do
    req = fake_request(
      headers: {
        "X-Slack-Request-Timestamp" => timestamp,
        "X-Slack-Signature"         => signature_for(timestamp, body, secret: "other-secret")
      }
    )
    expect { described_class.verify!(grant, req) }
      .to raise_error(Connectors::Webhooks::SignatureInvalid, /mismatch/)
  end

  it "rejects a stale request beyond the timestamp tolerance" do
    old_ts = (Time.now.to_i - 10 * 60).to_s
    req = fake_request(
      headers: {
        "X-Slack-Request-Timestamp" => old_ts,
        "X-Slack-Signature"         => signature_for(old_ts, body)
      }
    )
    expect { described_class.verify!(grant, req) }
      .to raise_error(Connectors::Webhooks::SignatureInvalid, /stale/)
  end

  it "rejects a request with missing signature headers" do
    req = fake_request(headers: {})
    expect { described_class.verify!(grant, req) }
      .to raise_error(Connectors::Webhooks::SignatureInvalid, /missing/)
  end

  it "raises if the signing_secret is not configured" do
    Connectors.reset_configuration!
    req = fake_request(
      headers: {
        "X-Slack-Request-Timestamp" => timestamp,
        "X-Slack-Signature"         => signature_for(timestamp, body)
      }
    )
    expect { described_class.verify!(grant, req) }.to raise_error(Connectors::Error)
  end
end
