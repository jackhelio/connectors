require "rails_helper"

RSpec.describe Connectors::Middleware::AutoRefresh do
  let(:owner) { Owner.create!(name: "auto-refresh owner") }
  let(:grant) do
    Connectors::Grant.create!(
      owner:         owner,
      connector_key: "slack",
      credentials:   {
        "access_token"  => "xoxb-stale",
        "refresh_token" => "xoxe-refresh",
        "team_id"       => "T1"
      }
    )
  end

  before do
    Connectors.configure do |c|
      c.host_base_url     = "https://app.test"
      c.oauth_credentials = { slack: { client_id: "ID", client_secret: "SECRET" } }
    end
  end

  describe "successful refresh on 401" do
    it "rotates the token, retries once, and leaves the grant :active" do
      stub_request(:post, "https://slack.com/api/oauth.v2.access").to_return(
        status:  200,
        headers: { "Content-Type" => "application/json" },
        body:    { ok: true, access_token: "xoxb-fresh", refresh_token: "xoxe-fresh" }.to_json
      )

      stub_request(:post, "https://slack.com/api/chat.postMessage")
        .with(headers: { "Authorization" => "Bearer xoxb-stale" })
        .to_return(status: 401, headers: { "Content-Type" => "application/json" },
                   body:   { ok: false, error: "invalid_auth" }.to_json)
      stub_request(:post, "https://slack.com/api/chat.postMessage")
        .with(headers: { "Authorization" => "Bearer xoxb-fresh" })
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body:   { ok: true, channel: "C", ts: "1" }.to_json)

      grant.connector.post_message(channel: "C", text: "hi")
      expect(grant.reload.status).to eq("active")
      expect(grant.credentials_hash["access_token"]).to eq("xoxb-fresh")
    end
  end

  describe "terminal refresh failure" do
    it "flips the grant to :errored so the UI can surface a Reconnect banner" do
      # 401 from the API → triggers refresh
      stub_request(:post, "https://slack.com/api/chat.postMessage").to_return(
        status:  401,
        headers: { "Content-Type" => "application/json" },
        body:    { ok: false, error: "invalid_auth" }.to_json
      )
      # Refresh itself comes back 400 invalid_grant (refresh_token revoked)
      stub_request(:post, "https://slack.com/api/oauth.v2.access").to_return(
        status:  400,
        headers: { "Content-Type" => "application/json" },
        body:    { error: "invalid_grant" }.to_json
      )

      expect { grant.connector.post_message(channel: "C", text: "t") }
        .to raise_error(Connectors::AuthenticationFailed)

      expect(grant.reload.status).to eq("errored")
    end

    it "still raises the underlying auth error when the status update itself fails" do
      stub_request(:post, "https://slack.com/api/chat.postMessage").to_return(
        status:  401,
        headers: { "Content-Type" => "application/json" },
        body:    { ok: false, error: "invalid_auth" }.to_json
      )
      stub_request(:post, "https://slack.com/api/oauth.v2.access").to_return(
        status:  400,
        headers: { "Content-Type" => "application/json" },
        body:    { error: "invalid_grant" }.to_json
      )

      allow_any_instance_of(Connectors::Grant)
        .to receive(:update_columns).and_raise(ActiveRecord::StatementInvalid, "db down")

      expect { grant.connector.post_message(channel: "C", text: "t") }
        .to raise_error(Connectors::AuthenticationFailed)
    end
  end
end
