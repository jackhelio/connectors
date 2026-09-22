require "rails_helper"

# Phase 3 — `pre_authentication` hook. Runs before each outgoing request
# when the grant's credentials look stale (expires_at missing or past).
# Mirrors n8n's `ICredentialType.preAuthentication`
# (packages/workflow/src/interfaces.ts:374-377). Reference impl:
# CrowdStrikeOAuth2Api.credentials.ts:62-76 — fetches a session token
# from /oauth2/token and merges `{ sessionToken }` into credentials.
RSpec.describe "pre_authentication hook (Phase 3)" do
  let(:owner) { Owner.create!(name: "phase 3 owner") }

  # Build a CrowdStrike-shape test connector: client_id + client_secret →
  # /oauth2/token → session_token → injected as Bearer header on every call.
  let!(:test_connector_class) do
    Class.new(Connectors::Connector) do
      connector key: :p3_session_token, auth: :api_key, base_url: "https://api.crowdstrike.test"

      credentials do
        field :url,           type: "string", required: true
        field :client_id,     type: "string", required: true
        field :client_secret, type: "string", required: true, secret: true
        field :session_token, type: "hidden", default: ""
        field :expires_at,    type: "hidden", default: ""
      end

      authenticate type: :generic, properties: {
        headers: { "Authorization" => "=Bearer {{$credentials.session_token}}" }
      }

      pre_authentication do |credentials, helpers|
        response = helpers.http_request(
          method: :post,
          url:    "#{credentials['url'].sub(%r{/\z}, '')}/oauth2/token",
          body:   { client_id: credentials["client_id"], client_secret: credentials["client_secret"] },
          headers: { "Content-Type" => "application/x-www-form-urlencoded" }
        )
        {
          "session_token" => response["access_token"],
          "expires_at"    => Time.now.to_i + response["expires_in"].to_i
        }
      end
    end
  end

  let(:grant) do
    Connectors::Grant.create!(
      owner:         owner,
      connector_key: "p3_session_token",
      credentials:   { "url" => "https://api.crowdstrike.test", "client_id" => "id-1", "client_secret" => "secret-1" }
    )
  end

  after do
    Connectors::Registry.instance_variable_get(:@store)&.delete(:p3_session_token)
  end

  it "fires the hook on first request (no expires_at yet), refreshing credentials before AuthenticateGeneric injects" do
    token_stub = stub_request(:post, "https://api.crowdstrike.test/oauth2/token")
                  .with(body: { client_id: "id-1", client_secret: "secret-1" })
                  .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                             body: { access_token: "tok-fresh", expires_in: 3600 }.to_json)

    api_stub = stub_request(:get, "https://api.crowdstrike.test/users")
                .with(headers: { "Authorization" => "Bearer tok-fresh" })
                .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: { ok: true }.to_json)

    grant.connector.client.get("users")
    expect(token_stub).to have_been_requested.once
    expect(api_stub).to   have_been_requested.once

    # Credentials persisted on the grant for reuse.
    grant.reload
    expect(grant.credentials_hash["session_token"]).to eq("tok-fresh")
    expect(grant.credentials_hash["expires_at"]).to be_within(10).of(Time.now.to_i + 3600)
  end

  it "skips the hook when credentials are still fresh (expires_at in the future)" do
    grant.update_credentials!(
      "session_token" => "tok-cached",
      "expires_at"    => Time.now.to_i + 600
    )

    token_stub = stub_request(:post, "https://api.crowdstrike.test/oauth2/token")
    api_stub   = stub_request(:get,  "https://api.crowdstrike.test/users")
                  .with(headers: { "Authorization" => "Bearer tok-cached" })
                  .to_return(status: 200, body: "{}")

    grant.connector.client.get("users")
    expect(token_stub).not_to have_been_requested
    expect(api_stub).to       have_been_requested.once
  end

  it "re-fires the hook when the cached token has expired" do
    grant.update_credentials!(
      "session_token" => "tok-stale",
      "expires_at"    => Time.now.to_i - 60   # expired
    )

    token_stub = stub_request(:post, "https://api.crowdstrike.test/oauth2/token")
                  .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                             body: { access_token: "tok-new", expires_in: 3600 }.to_json)
    api_stub   = stub_request(:get, "https://api.crowdstrike.test/users")
                  .with(headers: { "Authorization" => "Bearer tok-new" })
                  .to_return(status: 200, body: "{}")

    grant.connector.client.get("users")
    expect(token_stub).to have_been_requested.once
    expect(api_stub).to   have_been_requested.once
  end

  it "raises AuthenticationFailed when the hook itself errors out" do
    stub_request(:post, "https://api.crowdstrike.test/oauth2/token")
      .to_return(status: 500, body: "boom")
    stub_request(:get, "https://api.crowdstrike.test/users")
      .to_return(status: 200, body: "{}")

    expect {
      grant.connector.client.get("users")
    }.to raise_error(Connectors::AuthenticationFailed, /pre_authentication failed/)
  end

  describe "PreAuthenticationHelpers" do
    let(:helpers) { Connectors::PreAuthenticationHelpers.new }

    it "performs a JSON POST and returns the parsed body" do
      stub_request(:post, "https://example.test/x")
        .with(body: { a: 1 }.to_json, headers: { "Content-Type" => /json/ })
        .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: { token: "abc" }.to_json)

      result = helpers.http_request(method: :post, url: "https://example.test/x", body: { a: 1 })
      expect(result).to eq("token" => "abc")
    end

    it "performs a form-urlencoded POST when content-type says so" do
      stub_request(:post, "https://example.test/y")
        .with(body: "client_id=cid&client_secret=cs",
              headers: { "Content-Type" => "application/x-www-form-urlencoded" })
        .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: { ok: true }.to_json)

      result = helpers.http_request(
        method:  :post,
        url:     "https://example.test/y",
        body:    { client_id: "cid", client_secret: "cs" },
        headers: { "Content-Type" => "application/x-www-form-urlencoded" }
      )
      expect(result).to eq("ok" => true)
    end
  end
end
