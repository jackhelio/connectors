require "rails_helper"

# Phase 4 — OAuth completeness. Covers:
#   • OAuth2 `clientCredentials` grant (server-to-server, no redirect)
#   • OAuth2 PKCE flow (S256 challenge + verifier round-tripped in state)
#   • OAuth1.0a request-token + access-token legs
#   • RFC 7009 token revocation (declarative URL + override block)
RSpec.describe "Phase 4 — OAuth completeness", type: :request do
  let(:owner) { Owner.create!(name: "phase 4 owner") }

  # ---- shared setup helpers --------------------------------------------------
  def configure!(creds)
    Connectors.configure do |c|
      c.owner_class_name       = "Owner"
      c.current_owner_resolver = ->(_) { owner }
      c.host_base_url          = "https://app.test"
      c.oauth_credentials      = creds
    end
  end

  # =============================================================================
  # 4.1 — clientCredentials grant
  # =============================================================================
  describe "OAuth2 clientCredentials grant" do
    let!(:connector_class) do
      Class.new(Connectors::Connector) do
        connector key: :p4_cc, auth: :oauth2, base_url: "https://api.cc.test"
        credentials do
          field :access_token, required: true, secret: true
        end
        oauth2 token_url:      "https://api.cc.test/oauth/token",
               scope:          "read write",
               grant_type:     "clientCredentials",
               authentication: "header"
      end
    end

    before do
      configure!(p4_cc: { client_id: "cc-id", client_secret: "cc-secret" })
    end

    after { Connectors::Registry.instance_variable_get(:@store)&.delete(:p4_cc) }

    it "POSTs grant_type=client_credentials with Basic header and persists the access token" do
      token_stub = stub_request(:post, "https://api.cc.test/oauth/token")
        .with(
          body:    hash_including("grant_type" => "client_credentials", "scope" => "read write"),
          headers: { "Authorization" => "Basic #{Base64.strict_encode64('cc-id:cc-secret')}" }
        )
        .to_return(
          status: 200, headers: { "Content-Type" => "application/json" },
          body: { access_token: "cc-token-1", token_type: "Bearer", expires_in: 3600, scope: "read write" }.to_json
        )

      expect {
        get "/connectors/p4_cc/authorize"
      }.to change(Connectors::Grant, :count).by(1)

      expect(token_stub).to have_been_requested.once
      grant = Connectors::Grant.last
      expect(grant.credentials_hash["access_token"]).to eq("cc-token-1")
      expect(grant.status).to eq("active")
    end

    it "sends client_id/secret in the body when authentication: 'body' is configured" do
      Object.send(:remove_const, :P4CCBody) if Object.const_defined?(:P4CCBody)
      stub_const("P4CCBody", Class.new(Connectors::Connector) {
        connector key: :p4_cc_body, auth: :oauth2, base_url: "https://api.ccb.test"
        credentials { field :access_token, required: true, secret: true }
        oauth2 token_url:      "https://api.ccb.test/oauth/token",
               grant_type:     "clientCredentials",
               authentication: "body"
      })
      Connectors.configuration.oauth_credentials = { p4_cc: { client_id: "cc-id", client_secret: "cc-secret" },
                                                      p4_cc_body: { client_id: "bid", client_secret: "bsec" } }

      stub = stub_request(:post, "https://api.ccb.test/oauth/token")
        .with(body: hash_including("grant_type" => "client_credentials", "client_id" => "bid", "client_secret" => "bsec"))
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { access_token: "body-token" }.to_json)

      get "/connectors/p4_cc_body/authorize"
      expect(stub).to have_been_requested.once
      Connectors::Registry.instance_variable_get(:@store)&.delete(:p4_cc_body)
    end

    it "surfaces token-endpoint failures as 401" do
      stub_request(:post, "https://api.cc.test/oauth/token")
        .to_return(status: 401, headers: { "Content-Type" => "application/json" },
                   body: { error: "invalid_client" }.to_json)

      get "/connectors/p4_cc/authorize"
      expect(response).to have_http_status(:unauthorized)
      expect(response.body).to include("invalid_client")
    end
  end

  # =============================================================================
  # 4.2 — PKCE flow
  # =============================================================================
  describe "OAuth2 PKCE flow" do
    let!(:connector_class) do
      Class.new(Connectors::Connector) do
        connector key: :p4_pkce, auth: :oauth2, base_url: "https://api.pkce.test"
        credentials do
          field :access_token,  required: true, secret: true
          field :refresh_token, secret: true
        end
        oauth2 authorize_url: "https://auth.pkce.test/authorize",
               token_url:     "https://auth.pkce.test/token",
               scope:         "read",
               grant_type:    "pkce"
      end
    end

    before do
      configure!(p4_pkce: { client_id: "pkce-id", client_secret: "pkce-secret" })
    end

    after { Connectors::Registry.instance_variable_get(:@store)&.delete(:p4_pkce) }

    it "adds code_challenge + code_challenge_method=S256 to the authorize URL" do
      get "/connectors/p4_pkce/authorize"
      expect(response).to have_http_status(:redirect)

      params = URI.decode_www_form(URI.parse(response.location).query).to_h
      expect(params["response_type"]).to         eq("code")
      expect(params["code_challenge_method"]).to eq("S256")
      expect(params["code_challenge"]).to        be_present
      expect(params["code_challenge"].length).to be > 30
      expect(params["state"]).to                 be_present
    end

    it "round-trips the verifier through state and sends it on the token exchange" do
      get "/connectors/p4_pkce/authorize"
      authorize_url = URI.parse(response.location)
      params        = URI.decode_www_form(authorize_url.query).to_h
      state         = params["state"]
      challenge     = params["code_challenge"]

      decoded_state = Connectors::OAuth::State.decode(state)
      verifier      = decoded_state.dig("x", "cv")
      expect(verifier).to be_present

      # Verifier really derives the challenge (S256 = base64url(sha256(verifier)))
      expect(Connectors::OAuth::Pkce.base64url(Digest::SHA256.digest(verifier))).to eq(challenge)

      token_stub = stub_request(:post, "https://auth.pkce.test/token")
        .with(body: hash_including(
          "grant_type"    => "authorization_code",
          "code"          => "PKCE-CODE",
          "code_verifier" => verifier
        ), headers: { "Authorization" => "Basic #{Base64.strict_encode64('pkce-id:pkce-secret')}" })
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { access_token: "pkce-access", refresh_token: "pkce-refresh", expires_in: 3600 }.to_json)

      get "/connectors/p4_pkce/callback", params: { code: "PKCE-CODE", state: state }
      expect(token_stub).to have_been_requested.once
      expect(Connectors::Grant.last.credentials_hash["access_token"]).to eq("pkce-access")
    end
  end

  # =============================================================================
  # 4.3 — OAuth1.0a flow
  # =============================================================================
  describe "OAuth1.0a flow" do
    let!(:connector_class) do
      Class.new(Connectors::Connector) do
        connector key: :p4_o1, auth: :api_key, base_url: "https://api.o1.test"
        credentials do
          field :oauth_token,        required: true, secret: true
          field :oauth_token_secret, required: true, secret: true
        end
        oauth1 request_token_url: "https://api.o1.test/oauth/request_token",
               authorize_url:     "https://api.o1.test/oauth/authorize",
               access_token_url:  "https://api.o1.test/oauth/access_token",
               signature_method:  "HMAC-SHA1"
      end
    end

    before do
      configure!(p4_o1: { client_id: "consumer-key", client_secret: "consumer-secret" })
    end

    after { Connectors::Registry.instance_variable_get(:@store)&.delete(:p4_o1) }

    it "requests a request token, then redirects to authorize with oauth_token + state" do
      stub_request(:post, "https://api.o1.test/oauth/request_token")
        .with { |req|
          req.headers["Authorization"].to_s.start_with?("OAuth ") &&
          req.headers["Authorization"].include?("oauth_consumer_key=\"consumer-key\"") &&
          req.headers["Authorization"].include?("oauth_signature_method=\"HMAC-SHA1\"")
        }
        .to_return(status: 200, body: "oauth_token=req-tok&oauth_token_secret=req-tok-secret&oauth_callback_confirmed=true",
                   headers: { "Content-Type" => "application/x-www-form-urlencoded" })

      get "/connectors/p4_o1/authorize"
      expect(response).to have_http_status(:redirect)

      uri    = URI.parse(response.location)
      params = URI.decode_www_form(uri.query).to_h
      expect(uri.host).to            eq("api.o1.test")
      expect(uri.path).to            eq("/oauth/authorize")
      expect(params["oauth_token"]).to eq("req-tok")
      expect(params["state"]).to       be_present

      # State carries the request-token secret needed to sign the next leg.
      decoded = Connectors::OAuth::State.decode(params["state"])
      expect(decoded.dig("x", "ts")).to eq("req-tok-secret")
    end

    it "exchanges oauth_verifier + oauth_token for an access token and persists the grant" do
      stub_request(:post, "https://api.o1.test/oauth/request_token")
        .to_return(status: 200, body: "oauth_token=req-tok&oauth_token_secret=req-secret",
                   headers: { "Content-Type" => "application/x-www-form-urlencoded" })

      get "/connectors/p4_o1/authorize"
      state = URI.decode_www_form(URI.parse(response.location).query).to_h.fetch("state")

      # Access-token exchange must include oauth_verifier in the signed header
      # AND oauth_token=req-tok (echoed back by provider after user approval).
      stub_request(:post, "https://api.o1.test/oauth/access_token")
        .with { |req|
          auth = req.headers["Authorization"].to_s
          auth.include?("oauth_verifier=\"verify-me\"") &&
          auth.include?("oauth_token=\"req-tok\"") &&
          auth.include?("oauth_consumer_key=\"consumer-key\"")
        }
        .to_return(status: 200,
                   body: "oauth_token=access-tok&oauth_token_secret=access-secret&screen_name=jackson",
                   headers: { "Content-Type" => "application/x-www-form-urlencoded" })

      expect {
        get "/connectors/p4_o1/callback", params: { oauth_token: "req-tok", oauth_verifier: "verify-me", state: state }
      }.to change(Connectors::Grant, :count).by(1)

      grant = Connectors::Grant.last
      expect(grant.credentials_hash).to include(
        "oauth_token"        => "access-tok",
        "oauth_token_secret" => "access-secret",
        "signature_method"   => "HMAC-SHA1"
      )
    end

    it "signs the request-token call deterministically (HMAC-SHA1 base string)" do
      # Lock down the signing helper against a hand-computed reference so
      # signature regressions surface here, not in opaque provider 401s.
      sig = Connectors::OAuth1.sign(
        method:           "POST",
        url:              "https://api.example.com/oauth/request_token",
        params: {
          "oauth_consumer_key"     => "ck",
          "oauth_nonce"            => "nonce",
          "oauth_signature_method" => "HMAC-SHA1",
          "oauth_timestamp"        => "1700000000",
          "oauth_version"          => "1.0",
          "oauth_callback"         => "https://app.test/cb"
        },
        consumer_secret:  "cs",
        token_secret:     nil,
        signature_method: "HMAC-SHA1"
      )

      # Recompute via the same algorithm to confirm Base64 + HMAC are stable.
      base = "POST&https%3A%2F%2Fapi.example.com%2Foauth%2Frequest_token&" +
             Connectors::OAuth1.percent_encode(
               "oauth_callback=https%3A%2F%2Fapp.test%2Fcb&" \
               "oauth_consumer_key=ck&oauth_nonce=nonce&" \
               "oauth_signature_method=HMAC-SHA1&" \
               "oauth_timestamp=1700000000&oauth_version=1.0"
             )
      expected = Base64.strict_encode64(OpenSSL::HMAC.digest("SHA1", "cs&", base))
      expect(sig).to eq(expected)
    end
  end

  # =============================================================================
  # 4.4 — Token revocation
  # =============================================================================
  describe "RFC 7009 token revocation" do
    let!(:connector_class) do
      Class.new(Connectors::Connector) do
        connector key: :p4_rev, auth: :oauth2, base_url: "https://api.rev.test"
        credentials do
          field :access_token, required: true, secret: true
        end
        oauth2 authorize_url: "https://auth.rev.test/authorize",
               token_url:     "https://auth.rev.test/token"
        revoke_token_url "https://auth.rev.test/revoke"
      end
    end

    before do
      configure!(p4_rev: { client_id: "rev-id", client_secret: "rev-secret" })
    end

    let(:grant) do
      Connectors::Grant.create!(
        owner:         owner,
        connector_key: "p4_rev",
        credentials:   { "access_token" => "to-revoke" },
        status:        :active
      )
    end

    after { Connectors::Registry.instance_variable_get(:@store)&.delete(:p4_rev) }

    it "POSTs the token to the configured revoke URL and marks the grant revoked" do
      stub = stub_request(:post, "https://auth.rev.test/revoke")
        .with(body: hash_including(
          "token"         => "to-revoke",
          "client_id"     => "rev-id",
          "client_secret" => "rev-secret"
        ))
        .to_return(status: 200, body: "")

      post "/connectors/credentials/#{grant.id}/revoke"
      expect(response).to have_http_status(:ok)
      expect(stub).to have_been_requested.once
      expect(grant.reload.status).to eq("revoked")
    end

    it "honors a custom revoke_token block for providers with a non-RFC shape" do
      stub_const("P4RevCustom", Class.new(Connectors::Connector) {
        connector key: :p4_rev_custom, auth: :oauth2, base_url: "https://api.revc.test"
        credentials { field :access_token, required: true, secret: true }
        oauth2 authorize_url: "https://auth.revc.test/authorize",
               token_url:     "https://auth.revc.test/token"
        revoke_token do |g|
          Faraday.get("https://auth.revc.test/oauth/revoke", { token: g.credentials_hash["access_token"] })
        end
      })

      Connectors.configuration.oauth_credentials = {
        p4_rev:        { client_id: "rev-id", client_secret: "rev-secret" },
        p4_rev_custom: { client_id: "x", client_secret: "y" }
      }

      g = Connectors::Grant.create!(owner: owner, connector_key: "p4_rev_custom",
                                     credentials: { "access_token" => "tk-2" })
      stub = stub_request(:get, "https://auth.revc.test/oauth/revoke")
              .with(query: { token: "tk-2" }).to_return(status: 200, body: "")

      post "/connectors/credentials/#{g.id}/revoke"
      expect(response).to have_http_status(:ok)
      expect(stub).to have_been_requested.once
      expect(g.reload.status).to eq("revoked")
      Connectors::Registry.instance_variable_get(:@store)&.delete(:p4_rev_custom)
    end

    it "surfaces revoke endpoint failures as 401" do
      stub_request(:post, "https://auth.rev.test/revoke")
        .to_return(status: 500, body: "boom")

      post "/connectors/credentials/#{grant.id}/revoke"
      expect(response).to have_http_status(:unauthorized)
      expect(grant.reload.status).to eq("active")
    end
  end

  describe "OAuth1 base credential type registry" do
    it "is registered as :oauth1_api with the n8n field set" do
      schema = Connectors::CredentialTypeRegistry.fetch(:oauth1_api)
      field_names = schema.own_fields.map { |f| f.name.to_sym }
      expect(field_names).to include(
        :authorization_url, :access_token_url, :request_token_url,
        :consumer_key, :consumer_secret, :signature_method
      )
      expect(schema.generic_auth?).to be true
      expect(schema.display_name).to  eq("OAuth1 API")
    end
  end
end
