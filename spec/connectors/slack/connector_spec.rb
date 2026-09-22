require "rails_helper"

RSpec.describe Slack::Connector do
  let(:owner) { Owner.create!(name: "spec owner") }
  let(:grant) do
    Connectors::Grant.create!(
      owner:         owner,
      connector_key: "slack",
      credentials:   {
        "access_token"  => "xoxb-test-1234",
        "refresh_token" => "xoxe-refresh",
        "team_id"       => "T08AB",
        "bot_user_id"   => "U089XYZ"
      }
    )
  end

  describe "registration & DSL" do
    it "registers itself in the Connectors::Registry under :slack" do
      expect(Connectors::Registry.fetch(:slack)).to eq(described_class)
    end

    it "declares OAuth2 endpoints" do
      cfg = described_class.oauth2_config
      expect(cfg[:authorize_url]).to eq("https://slack.com/oauth/v2/authorize")
      expect(cfg[:token_url]).to     eq("https://slack.com/api/oauth.v2.access")
      expect(cfg[:scope]).to         include("chat:write")
    end

    it "inherits the OAuth2 form via `extends :oauth2`" do
      expect(described_class.credential_schema.extends).to eq([ :oauth2 ])
    end

    it "locks Slack-specific endpoints as hidden fields with defaults" do
      authorization_url = described_class.credential_schema.resolved_fields
                                          .find { |f| f.name == :authorization_url }
      expect(authorization_url.type).to    eq("hidden")
      expect(authorization_url.default).to eq("https://slack.com/oauth/v2/authorize")
    end

    it "wires the webhook verifier" do
      expect(described_class.webhook_verifier).to eq(Slack::WebhookVerifier)
    end
  end

  describe ".post_token_exchange" do
    it "extracts Slack-specific fields from the OAuth response" do
      raw = {
        "ok"           => true,
        "access_token" => "xoxb-a",
        "bot_user_id"  => "U089XYZ",
        "app_id"       => "A123",
        "team"         => { "id" => "T08AB", "name" => "Acme" },
        "authed_user"  => { "id" => "U001" }
      }
      normalized = { "access_token" => "xoxb-a", "scope" => "chat:write" }
      result     = described_class.post_token_exchange(raw, normalized)

      expect(result).to include(
        "access_token"   => "xoxb-a",
        "scope"          => "chat:write",
        "team_id"        => "T08AB",
        "team_name"      => "Acme",
        "bot_user_id"    => "U089XYZ",
        "app_id"         => "A123",
        "authed_user_id" => "U001"
      )
    end
  end

  describe "#post_message" do
    it "POSTs to chat.postMessage with the access_token as Bearer" do
      stub_request(:post, "https://slack.com/api/chat.postMessage")
        .with(
          body: hash_including("channel" => "C12345", "text" => "hi"),
          headers: { "Authorization" => "Bearer xoxb-test-1234" }
        )
        .to_return(
          status:  200,
          headers: { "Content-Type" => "application/json" },
          body:    { ok: true, channel: "C12345", ts: "1735689600.000200" }.to_json
        )

      response = grant.connector.post_message(channel: "C12345", text: "hi")
      expect(response).to include("ok" => true, "channel" => "C12345")
    end

    it "raises Connectors::ApiError on ok:false responses" do
      stub_request(:post, "https://slack.com/api/chat.postMessage").to_return(
        status:  200,
        headers: { "Content-Type" => "application/json" },
        body:    { ok: false, error: "channel_not_found" }.to_json
      )

      expect { grant.connector.post_message(channel: "X", text: "y") }
        .to raise_error(Connectors::ApiError, /channel_not_found/)
    end

    it "raises Connectors::AuthenticationFailed on 401 (after auto-refresh attempt)" do
      # First call returns 401, refresh endpoint succeeds, second call still 401.
      stub_request(:post, "https://slack.com/api/oauth.v2.access").to_return(
        status:  200,
        headers: { "Content-Type" => "application/json" },
        body:    { ok: true, access_token: "xoxb-new", refresh_token: "xoxe-new" }.to_json
      )
      stub_request(:post, "https://slack.com/api/chat.postMessage").to_return(
        status:  401,
        headers: { "Content-Type" => "application/json" },
        body:    { ok: false, error: "invalid_auth" }.to_json
      )

      Connectors.configure { |c| c.oauth_credentials = { slack: { client_id: "x", client_secret: "y" } } }
      expect { grant.connector.post_message(channel: "C", text: "t") }
        .to raise_error(Connectors::AuthenticationFailed)
    end
  end

  describe "#refresh!" do
    it "exchanges the refresh_token and merges new tokens into credentials" do
      Connectors.configure do |c|
        c.host_base_url     = "https://app.test"
        c.oauth_credentials = { slack: { client_id: "ID", client_secret: "SECRET" } }
      end

      stub_request(:post, "https://slack.com/api/oauth.v2.access")
        .with(body: hash_including("grant_type" => "refresh_token", "refresh_token" => "xoxe-refresh"))
        .to_return(
          status:  200,
          headers: { "Content-Type" => "application/json" },
          body:    {
            ok:            true,
            access_token:  "xoxb-rotated",
            refresh_token: "xoxe-rotated",
            expires_in:    43_200,
            scope:         "chat:write,channels:read"
          }.to_json
        )

      grant.connector.refresh!
      reloaded = grant.reload.credentials

      expect(reloaded["access_token"]).to  eq("xoxb-rotated")
      expect(reloaded["refresh_token"]).to eq("xoxe-rotated")
      expect(reloaded["expires_at"]).to    be_within(5).of(Time.now.to_i + 43_200)
      expect(reloaded["team_id"]).to       eq("T08AB")   # untouched fields preserved
    end
  end
end
