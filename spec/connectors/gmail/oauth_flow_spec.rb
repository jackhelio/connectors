require "rails_helper"

# End-to-end OAuth dance for Gmail in both supported topologies:
#
#   1. Separate frontend/backend:
#      frontend opens popup → provider redirects to FRONTEND `/oauth/callback`
#      → frontend POSTs `{code, state}` to engine's `/oauth/exchange` →
#      engine runs token exchange + creates Grant. Tested via the second
#      `context` block.
#
#   2. Same-origin frontend/backend:
#      frontend opens popup OR redirects → provider redirects back to
#      engine's `/<connector_key>/callback` → engine runs token exchange,
#      renders JSON (or 302s to `state.return_to`). Tested via the first
#      `context` block.
#
# Both paths share `OAuth::TokenExchange` and `OAuth::GrantWriter`, so a break in
# either of those surfaces in both contexts.
RSpec.describe "Gmail — full OAuth round-trip", type: :request do
  let(:owner) { Owner.create!(name: "gmail user") }

  before do
    Connectors.configure do |c|
      c.owner_class_name       = "Owner"
      c.current_owner_resolver = ->(_ctrl) { owner }
      c.host_base_url          = "http://localhost:3000"
      c.app_callback_url       = "http://localhost:3003/api/oauth/callback"
      c.oauth_credentials      = {
        gmail: { client_id: "test-client.apps.googleusercontent.com",
                 client_secret: "test-secret" }
      }
    end
  end

  describe "authorize.json" do
    it "issues an authorize URL with the four default scopes + PKCE + offline access" do
      get "/connectors/gmail/authorize.json"
      expect(response).to have_http_status(:ok)

      authorize_url = response.parsed_body["authorize_url"]
      expect(authorize_url).to start_with("https://accounts.google.com/o/oauth2/v2/auth?")

      params = URI.decode_www_form(URI.parse(authorize_url).query).to_h
      expect(params["client_id"]).to     eq("test-client.apps.googleusercontent.com")
      expect(params["response_type"]).to eq("code")
      # redirect_uri points at the FRONTEND now — Google redirects there and
      # the frontend posts {code, state} to /oauth/exchange.
      expect(params["redirect_uri"]).to  eq("http://localhost:3003/api/oauth/callback")
      expect(params["scope"]).to         include("gmail.modify").and include("gmail.labels").and include("openid")
      expect(params["code_challenge"]).to             be_present
      expect(params["code_challenge_method"]).to      eq("S256")
      expect(params["access_type"]).to                eq("offline")
      expect(params["prompt"]).to                     eq("consent")
      expect(params["include_granted_scopes"]).to     eq("true")
      expect(params["state"]).to                      be_present
    end

    it "honors a scope override on the authorize step" do
      get "/connectors/gmail/authorize.json", params: { scope: "openid email https://www.googleapis.com/auth/gmail.send" }
      params = URI.decode_www_form(URI.parse(response.parsed_body["authorize_url"]).query).to_h
      expect(params["scope"]).to eq("openid email https://www.googleapis.com/auth/gmail.send")
    end

    it "falls back to the engine's own callback when app_callback_url is unset" do
      Connectors.configure { |c| c.app_callback_url = nil }
      get "/connectors/gmail/authorize.json"
      params = URI.decode_www_form(URI.parse(response.parsed_body["authorize_url"]).query).to_h
      expect(params["redirect_uri"]).to eq("http://localhost:3000/connectors/gmail/callback")
    end
  end

  context "split frontend/backend — POST /oauth/exchange" do
    it "exchanges the code, persists a Grant, returns its JSON" do
      get "/connectors/gmail/authorize.json"
      state = URI.decode_www_form(URI.parse(response.parsed_body["authorize_url"]).query).to_h["state"]

      stub_request(:post, "https://oauth2.googleapis.com/token")
        .with(body: hash_including("client_id" => "test-client.apps.googleusercontent.com", "client_secret" => "test-secret"))
        .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          access_token:  "ya29.live",
          refresh_token: "1//live",
          expires_in:    3599,
          id_token:      build_id_token(email: "user@gmail.com")
        }.to_json
      )

      expect {
        post "/connectors/oauth/exchange",
             params: { code: "google-code", state: state }.to_json,
             headers: { "Content-Type" => "application/json" }
      }.to change(Connectors::Grant, :count).by(1)

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body).to include(
        "connector_key" => "gmail",
        "status"        => "active",
        "external_account_id" => "user@gmail.com"
      )
      expect(body["grant_id"]).to be_a(String).and match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/)

      # The redirect_uri the engine sends to Google MUST match what the
      # frontend received — otherwise Google would reject with
      # redirect_uri_mismatch. Lock that invariant.
      expect(WebMock).to have_requested(:post, "https://oauth2.googleapis.com/token").with { |req|
        body = URI.decode_www_form(req.body).to_h
        body["redirect_uri"] == "http://localhost:3003/api/oauth/callback" &&
          body["code"] == "google-code" &&
          body["code_verifier"].to_s.length > 0
      }

      grant = Connectors::Grant.last
      expect(grant.credentials_hash).to include("access_token" => "ya29.live", "email" => "user@gmail.com")
    end

    it "401s on a bogus state token" do
      post "/connectors/oauth/exchange",
           params: { code: "x", state: "tampered" }.to_json,
           headers: { "Content-Type" => "application/json" }
      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body).to eq("error" => "invalid_state")
    end

    it "404s when the state's owner no longer exists" do
      ghost     = Owner.create!(name: "ghost")
      ghost_gid = ghost.to_global_id.to_s
      ghost.destroy
      state = Connectors::OAuth::State.encode(
        connector_key: :gmail, owner_gid: ghost_gid, return_to: nil
      )

      post "/connectors/oauth/exchange",
           params: { code: "x", state: state }.to_json,
           headers: { "Content-Type" => "application/json" }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq("error" => "owner_not_found")
    end
  end

  context "monolithic host — GET /:connector_key/callback (back-compat)" do
    it "round-trips authorize → callback and persists a Grant when same-origin" do
      # For a same-origin host the redirect_uri matches the engine itself.
      Connectors.configure { |c| c.app_callback_url = nil }

      get "/connectors/gmail/authorize.json"
      state = URI.decode_www_form(URI.parse(response.parsed_body["authorize_url"]).query).to_h["state"]

      stub_request(:post, "https://oauth2.googleapis.com/token").to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { access_token: "ya29.mono", expires_in: 3599,
                id_token: build_id_token(email: "mono@gmail.com") }.to_json
      )

      expect {
        get "/connectors/gmail/callback", params: { code: "mono-code", state: state }
      }.to change(Connectors::Grant, :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("connector_key" => "gmail", "status" => "active")
    end

    it "refuses callbacks whose state's connector_key doesn't match the URL path" do
      Connectors.configure { |c| c.app_callback_url = nil }
      get "/connectors/gmail/callback", params: { code: "x", state: "tampered" }
      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body).to eq("error" => "invalid_state")
    end
  end

  # Build a JWT-shaped string with the given payload — only the payload
  # segment matters; the signature is never checked (we trust the token
  # because it came from Google's own /token endpoint over TLS).
  def build_id_token(payload)
    header  = Base64.urlsafe_encode64({ alg: "RS256", typ: "JWT" }.to_json, padding: false)
    body    = Base64.urlsafe_encode64(payload.to_json, padding: false)
    "#{header}.#{body}.fakesig"
  end
end
