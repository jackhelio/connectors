require "rails_helper"

RSpec.describe Connectors::Middleware::ErrorNormalization do
  let(:owner) { Owner.create!(name: "x") }
  let(:grant) do
    Connectors::Grant.create!(
      owner: owner,
      connector_key: "slack",
      credentials: { "access_token" => "xoxb-x" }
    )
  end

  describe "429 with Retry-After header" do
    it "raises Connectors::RateLimited and surfaces retry_after as an integer" do
      stub_request(:post, "https://slack.com/api/chat.postMessage").to_return(
        status:  429,
        headers: { "Retry-After" => "42", "Content-Type" => "application/json" },
        body:    { ok: false, error: "ratelimited" }.to_json
      )

      expect { grant.connector.post_message(channel: "C", text: "t") }
        .to raise_error(Connectors::RateLimited) { |e|
          expect(e.retry_after).to eq(42)
          expect(e.status).to      eq(429)
        }
    end

    it "leaves retry_after nil when the header is absent" do
      stub_request(:post, "https://slack.com/api/chat.postMessage").to_return(
        status:  429,
        headers: { "Content-Type" => "application/json" },
        body:    { ok: false, error: "ratelimited" }.to_json
      )

      expect { grant.connector.post_message(channel: "C", text: "t") }
        .to raise_error(Connectors::RateLimited) { |e|
          expect(e.retry_after).to be_nil
        }
    end
  end

  describe "401" do
    it "raises Connectors::AuthenticationFailed" do
      Connectors.configure { |c| c.oauth_credentials = { slack: { client_id: "i", client_secret: "s" } } }
      stub_request(:post, "https://slack.com/api/oauth.v2.access").to_return(
        status: 200, headers: { "Content-Type" => "application/json" },
        body: { ok: false, error: "invalid_auth" }.to_json
      )
      stub_request(:post, "https://slack.com/api/chat.postMessage").to_return(
        status: 401, headers: { "Content-Type" => "application/json" },
        body: { ok: false, error: "invalid_auth" }.to_json
      )

      expect { grant.connector.post_message(channel: "C", text: "t") }
        .to raise_error(Connectors::AuthenticationFailed)
    end
  end

  describe "other 5xx" do
    it "raises a generic Connectors::ApiError" do
      stub_request(:post, "https://slack.com/api/chat.postMessage").to_return(
        status: 500, body: '{"error":"oops"}',
        headers: { "Content-Type" => "application/json" }
      )

      expect { grant.connector.post_message(channel: "C", text: "t") }
        .to raise_error(Connectors::ApiError) { |e|
          expect(e.status).to eq(500)
        }
    end
  end
end
