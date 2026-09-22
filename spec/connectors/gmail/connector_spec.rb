require "rails_helper"

RSpec.describe Gmail::Connector do
  let(:owner) { Owner.create!(name: "gmail owner") }
  let(:grant) do
    Connectors::Grant.create!(
      owner:         owner,
      connector_key: "gmail",
      credentials:   {
        "access_token"  => "ya29.test-access",
        "refresh_token" => "1//test-refresh",
        "email"         => "user@example.com",
        "scope"         => Gmail::Connector::DEFAULT_SCOPES.join(" ")
      }
    )
  end

  describe "registration & DSL" do
    it "registers itself in the Connectors::Registry under :gmail" do
      expect(Connectors::Registry.fetch(:gmail)).to eq(described_class)
    end

    it "declares Google's OAuth2 endpoints + PKCE flow" do
      cfg = described_class.oauth2_config
      expect(cfg[:authorize_url]).to eq("https://accounts.google.com/o/oauth2/v2/auth")
      expect(cfg[:token_url]).to     eq("https://oauth2.googleapis.com/token")
      expect(cfg[:grant_type]).to    eq("pkce")
      expect(cfg[:extra_authorize_params]).to include(
        access_type: "offline", prompt: "consent"
      )
    end

    it "suggests the four default scopes" do
      expect(described_class.oauth2_config[:scope]).to eq(
        "openid email https://www.googleapis.com/auth/gmail.modify https://www.googleapis.com/auth/gmail.labels"
      )
    end

    it "declares its token-revocation endpoint" do
      expect(described_class.revoke_token_url).to eq("https://oauth2.googleapis.com/revoke")
    end

    it "inherits the OAuth2 form via `extends :oauth2`" do
      expect(described_class.credential_schema.extends).to eq([ :oauth2 ])
    end

    it "exposes llm_docs pointing at Google's REST reference" do
      expect(described_class.llm_docs).to eq("https://developers.google.com/gmail/api/reference/rest")
    end

    it "declares a conservative rate limit (2 req/s) under Gmail's per-user quota" do
      expect(described_class.rate_limit_config).to eq(limit: 2, per: 1.second)
    end

    it "declares the full action surface (messages, threads, labels, drafts) at n8n parity" do
      expect(described_class.actions.map(&:key)).to match_array([
        # messages
        :send_message, :reply_to_message,
        :list_messages, :list_all_messages, :get_message,
        :delete_message, :trash_message, :untrash_message,
        :mark_message_as_read, :mark_message_as_unread,
        :add_labels, :remove_labels,
        # threads
        :list_threads, :list_all_threads, :get_thread,
        :delete_thread, :trash_thread, :untrash_thread,
        :add_labels_to_thread, :remove_labels_from_thread,
        # labels
        :list_labels, :get_label, :create_label, :delete_label,
        # drafts
        :create_draft, :get_draft, :list_drafts, :list_all_drafts, :delete_draft
      ])
    end
  end

  describe ".post_token_exchange" do
    it "extracts the user's email from the id_token JWT" do
      id_token = build_id_token(email: "user@example.com")
      raw      = { "access_token" => "ya29.x", "id_token" => id_token }
      result   = described_class.post_token_exchange(raw, { "access_token" => "ya29.x" })
      expect(result).to include("email" => "user@example.com")
    end

    it "is a no-op when the response carries no id_token (e.g., refresh)" do
      result = described_class.post_token_exchange({ "access_token" => "ya29.x" }, { "access_token" => "ya29.x" })
      expect(result.keys).to eq([ "access_token" ])
    end

    it "tolerates a malformed id_token without raising" do
      result = described_class.post_token_exchange({ "id_token" => "not.a.jwt" }, {})
      expect(result).to eq({})
    end
  end

  describe ".external_account_id_from_credentials" do
    it "uses the persisted email as the routable account id" do
      expect(described_class.external_account_id_from_credentials("email" => "u@x.com")).to eq("u@x.com")
    end
  end

  describe "#refresh!" do
    it "exchanges the refresh_token at Google's token endpoint and merges new tokens" do
      Connectors.configure do |c|
        c.host_base_url     = "https://app.test"
        c.oauth_credentials = { gmail: { client_id: "google-id", client_secret: "google-secret" } }
      end

      stub_request(:post, "https://oauth2.googleapis.com/token")
        .with(body: hash_including("grant_type" => "refresh_token", "refresh_token" => "1//test-refresh"))
        .to_return(
          status:  200,
          headers: { "Content-Type" => "application/json" },
          body:    {
            access_token: "ya29.rotated",
            expires_in:   3600,
            token_type:   "Bearer",
            scope:        "openid email"
          }.to_json
        )

      grant.connector.refresh!
      reloaded = grant.reload.credentials
      expect(reloaded["access_token"]).to eq("ya29.rotated")
      expect(reloaded["email"]).to        eq("user@example.com")  # untouched
    end
  end

  describe "test_request" do
    it "hits /users/me/profile with the Bearer token" do
      stub_request(:get, "https://gmail.googleapis.com/gmail/v1/users/me/profile")
        .with(headers: { "Authorization" => "Bearer ya29.test-access" })
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body:   { emailAddress: "user@example.com", messagesTotal: 12_345 }.to_json
        )

      result = Connectors::CredentialTester.run(grant)
      expect(result[:status]).to eq("OK")
    end
  end

  # Helper: produce a JWT-shaped string with the given payload (no signing —
  # we only ever decode it, and only trust it because it came from Google's
  # own token endpoint over TLS).
  def build_id_token(payload)
    header  = Base64.urlsafe_encode64({ alg: "RS256", typ: "JWT" }.to_json, padding: false)
    body    = Base64.urlsafe_encode64(payload.to_json, padding: false)
    signature = "fakesig"
    "#{header}.#{body}.#{signature}"
  end
end
