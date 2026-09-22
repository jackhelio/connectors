require "rails_helper"

RSpec.describe "Slack webhook flow", type: :request do
  let(:signing_secret) { "abcdef0123456789" }
  let(:owner_a)        { Owner.create!(name: "team A owner") }
  let(:owner_b)        { Owner.create!(name: "team B owner") }

  let!(:grant_team_a) do
    Connectors::Grant.create!(
      owner:               owner_a,
      connector_key:       "slack",
      external_account_id: "T_ALPHA",
      credentials:         { "access_token" => "xoxb-a", "team_id" => "T_ALPHA" }
    )
  end

  let!(:grant_team_b) do
    Connectors::Grant.create!(
      owner:               owner_b,
      connector_key:       "slack",
      external_account_id: "T_BETA",
      credentials:         { "access_token" => "xoxb-b", "team_id" => "T_BETA" }
    )
  end

  before do
    Connectors.configure { |c| c.oauth_credentials = { slack: { signing_secret: signing_secret } } }
  end

  # Helpers --------------------------------------------------------------------

  def sign(body, ts: Time.now.to_i.to_s, secret: signing_secret)
    sig = "v0=" + OpenSSL::HMAC.hexdigest("SHA256", secret, "v0:#{ts}:#{body}")
    { ts: ts, sig: sig }
  end

  def post_webhook(payload:, ts: Time.now.to_i.to_s, secret: signing_secret)
    body  = payload.to_json
    h     = sign(body, ts: ts, secret: secret)
    post "/connectors/slack/webhook",
         params:  body,
         headers: {
           "Content-Type"              => "application/json",
           "X-Slack-Request-Timestamp" => h[:ts],
           "X-Slack-Signature"         => h[:sig]
         }
  end

  # Tests ----------------------------------------------------------------------

  describe "URL verification challenge" do
    it "echoes the challenge string when Slack sets up Event Subscriptions" do
      post_webhook(payload: { "type" => "url_verification", "challenge" => "3eZbrw1aBm2rZgRNFdxV2595E9CY3gmdALWMmHkvFXO7tYXAYM8P" })

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq("challenge" => "3eZbrw1aBm2rZgRNFdxV2595E9CY3gmdALWMmHkvFXO7tYXAYM8P")

      # No event should have been persisted for the challenge ping.
      expect(Connectors::WebhookEvent.count).to eq(0)
    end

    it "still requires a valid signature for the challenge" do
      body = { type: "url_verification", challenge: "x" }.to_json
      post "/connectors/slack/webhook",
           params:  body,
           headers: {
             "Content-Type"              => "application/json",
             "X-Slack-Request-Timestamp" => Time.now.to_i.to_s,
             "X-Slack-Signature"         => "v0=deadbeef"
           }
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "per-team routing" do
    it "routes to the grant whose external_account_id matches payload team_id" do
      expect {
        post_webhook(payload: {
          "team_id"  => "T_ALPHA",
          "event_id" => "Ev_AAA",
          "type"     => "event_callback",
          "event"    => { "type" => "message", "user" => "U1", "text" => "hi" }
        })
      }.to change(Connectors::WebhookEvent, :count).by(1)

      expect(response).to have_http_status(:accepted)
      event = Connectors::WebhookEvent.last
      expect(event.grant).to             eq(grant_team_a)
      expect(event.external_event_id).to eq("Ev_AAA")
    end

    it "routes a different team_id to the other team's grant" do
      post_webhook(payload: { "team_id" => "T_BETA", "event_id" => "Ev_BBB", "type" => "event_callback" })
      expect(response).to have_http_status(:accepted)
      expect(Connectors::WebhookEvent.last.grant).to eq(grant_team_b)
    end

    it "also accepts the nested form team: { id: ... }" do
      post_webhook(payload: { "team" => { "id" => "T_ALPHA" }, "event_id" => "Ev_NESTED", "type" => "event_callback" })
      expect(response).to have_http_status(:accepted)
      expect(Connectors::WebhookEvent.last.grant).to eq(grant_team_a)
    end

    it "returns 404 when no grant matches the team_id" do
      post_webhook(payload: { "team_id" => "T_UNKNOWN", "event_id" => "Ev_X", "type" => "event_callback" })
      expect(response).to have_http_status(:not_found)
      expect(Connectors::WebhookEvent.count).to eq(0)
    end
  end

  describe "idempotency" do
    it "returns 'duplicate' on the second delivery of the same event_id" do
      payload = { "team_id" => "T_ALPHA", "event_id" => "Ev_SAME", "type" => "event_callback" }

      post_webhook(payload: payload)
      expect(response).to have_http_status(:accepted)

      post_webhook(payload: payload)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["status"]).to eq("duplicate")

      expect(Connectors::WebhookEvent.where(connector_key: "slack", external_event_id: "Ev_SAME").count).to eq(1)
    end
  end

  describe "signature failures" do
    it "rejects a request signed with the wrong secret" do
      post_webhook(payload: { "team_id" => "T_ALPHA", "event_id" => "Ev_X" }, secret: "wrong-secret")
      expect(response).to have_http_status(:unauthorized)
      expect(Connectors::WebhookEvent.count).to eq(0)
    end

    it "rejects a stale request" do
      post_webhook(payload: { "team_id" => "T_ALPHA", "event_id" => "Ev_X" }, ts: (Time.now.to_i - 10 * 60).to_s)
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
