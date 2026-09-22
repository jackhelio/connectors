require "rails_helper"

RSpec.describe "Slack OAuth flow", type: :request do
  let(:owner) { Owner.create!(name: "callback owner") }

  before do
    Connectors.configure do |c|
      c.owner_class_name       = "Owner"
      c.current_owner_resolver = ->(_ctrl) { owner }
      c.host_base_url          = "https://app.test"
      c.oauth_credentials      = {
        slack: { client_id: "client-abc", client_secret: "secret-xyz" }
      }
    end
  end

  describe "GET /connectors/slack/authorize" do
    it "redirects to Slack's authorize URL with the right params" do
      get "/connectors/slack/authorize"

      expect(response).to have_http_status(:redirect)
      uri = URI.parse(response.location)
      expect(uri.host).to eq("slack.com")
      expect(uri.path).to eq("/oauth/v2/authorize")

      params = URI.decode_www_form(uri.query).to_h
      expect(params["response_type"]).to eq("code")
      expect(params["client_id"]).to     eq("client-abc")
      expect(params["redirect_uri"]).to  eq("https://app.test/connectors/slack/callback")
      expect(params["scope"]).to         include("chat:write")
      expect(params["state"]).to         be_present
    end
  end

  describe "GET /connectors/slack/callback" do
    let(:state) do
      Connectors::OAuth::State.encode(
        connector_key: :slack,
        owner_gid:     owner.to_global_id.to_s
      )
    end

    before do
      stub_request(:post, "https://slack.com/api/oauth.v2.access")
        .with(body: hash_including("code" => "AUTH-CODE-1", "grant_type" => "authorization_code"))
        .to_return(
          status:  200,
          headers: { "Content-Type" => "application/json" },
          body:    {
            ok:            true,
            access_token:  "xoxb-real-token",
            token_type:    "bot",
            scope:         "chat:write,channels:read,users:read",
            bot_user_id:   "U089XYZ",
            app_id:        "A0123",
            team:          { id: "T08AB", name: "Acme Inc" },
            authed_user:   { id: "U001" }
          }.to_json
        )
    end

    it "exchanges the code, persists a Grant, and includes Slack-specific fields in credentials" do
      expect {
        get "/connectors/slack/callback", params: { code: "AUTH-CODE-1", state: state }
      }.to change(Connectors::Grant, :count).by(1)

      expect(response).to have_http_status(:ok)

      grant = Connectors::Grant.last
      expect(grant.owner).to              eq(owner)
      expect(grant.connector_key).to      eq("slack")
      expect(grant.status).to             eq("active")
      expect(grant.external_account_id).to eq("T08AB")   # denormalized for webhook routing
      expect(grant.credentials).to include(
        "access_token"   => "xoxb-real-token",
        "scope"          => "chat:write,channels:read,users:read",
        "team_id"        => "T08AB",
        "team_name"      => "Acme Inc",
        "bot_user_id"    => "U089XYZ",
        "app_id"         => "A0123",
        "authed_user_id" => "U001"
      )
    end

    it "rejects a callback with a missing state token" do
      get "/connectors/slack/callback", params: { code: "AUTH-CODE-1" }
      expect(response).to have_http_status(:unauthorized)
    end

    it "rejects a callback whose state token was signed for a different connector" do
      wrong_state = Connectors::OAuth::State.encode(
        connector_key: :linear,
        owner_gid:     owner.to_global_id.to_s
      )
      get "/connectors/slack/callback", params: { code: "AUTH-CODE-1", state: wrong_state }
      expect(response).to have_http_status(:unauthorized)
    end

    it "surfaces Slack's ok:false token-exchange errors as 401" do
      stub_request(:post, "https://slack.com/api/oauth.v2.access").to_return(
        status:  200,
        headers: { "Content-Type" => "application/json" },
        body:    { ok: false, error: "invalid_code" }.to_json
      )

      get "/connectors/slack/callback", params: { code: "BAD", state: state }
      expect(response).to have_http_status(:unauthorized)
      expect(response.body).to include("invalid_code")
    end
  end
end
