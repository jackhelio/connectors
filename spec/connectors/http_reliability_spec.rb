require "rails_helper"

RSpec.describe "Connector HTTP reliability" do
  let(:owner) { Owner.create!(name: "HTTP owner") }
  let(:grant) do
    Connectors::Grant.create!(owner: owner, connector_key: "slack",
      credentials: { "access_token" => "old", "refresh_token" => "refresh" })
  end
  let(:url) { "https://slack.com/api/example" }
  let(:json_headers) { { "Content-Type" => "application/json" } }

  before do
    Connectors.configuration.oauth_credentials = { slack: { client_id: "id", client_secret: "secret" } }
  end

  %w[slack resend].each do |connector_key|
    it "rejects a cached #{connector_key} client after another worker revokes the grant" do
      grant.update!(connector_key: connector_key, credentials: { "api_key" => "key", "access_token" => "token" })
      client = grant.connector.client
      Connectors::Grant.find(grant.id).update!(status: :revoked)
      expect { client.get("example") }.to raise_error(Connectors::AuthenticationFailed, /revoked/)
      expect(WebMock).not_to have_requested(:any, /slack.com|resend.com/)
    end
  end

  it "checks revocation before a transient response is retried" do
    endpoint = stub_request(:get, url).to_return do
      Connectors::Grant.find(grant.id).update!(status: :revoked)
      { status: 503, body: "unavailable" }
    end
    expect { grant.connector.client.get("example") }.to raise_error(Connectors::AuthenticationFailed, /revoked/)
    expect(endpoint).to have_been_requested.once
  end

  it "rejects revoked grants before running pre-authentication" do
    hook = instance_double(Proc)
    expect(hook).not_to receive(:call)
    grant.update!(status: :revoked)
    client = Connectors::ClientBuilder.new(base_url: "https://example.test", grant: grant,
      auth_scheme: Connectors::Auth::Scheme::OAuth2, pre_auth_block: hook).build
    expect { client.get("data") }.to raise_error(Connectors::AuthenticationFailed, /revoked/)
  end

  it "preserves unsaved connector state when checking revocation" do
    grant.static_data = { "polling" => { "cursor" => "pending" } }
    stub_request(:get, url).to_return(status: 200)
    expect(grant.connector.client.get("example").status).to eq(200)
    expect(grant.static_data).to eq("polling" => { "cursor" => "pending" })
    expect(grant).to be_changed
  end

  it "retries a transient GET response before normalizing errors" do
    endpoint = stub_request(:get, url).to_return(
      { status: 503, body: '{"error":"unavailable"}', headers: json_headers },
      { status: 200, body: '{"result":"ok"}', headers: json_headers })
    expect(grant.connector.client.get("example").body).to eq("result" => "ok")
    expect(endpoint).to have_been_requested.twice
  end

  it "raises the parsed error after the retry budget is exhausted" do
    endpoint = stub_request(:get, url).to_return(status: 502, body: '{"error":"upstream"}', headers: json_headers)
    expect { grant.connector.client.get("example") }.to raise_error(Connectors::ApiError) { |error|
      expect(error.status).to eq(502)
      expect(error.body).to eq("error" => "upstream")
    }
    expect(endpoint).to have_been_requested.times(3)
  end

  it "does not automatically repeat a non-idempotent POST on server failure" do
    endpoint = stub_request(:post, url).to_return(status: 503, body: "unavailable")
    expect { grant.connector.client.post("example", { text: "once" }) }.to raise_error(Connectors::ApiError)
    expect(endpoint).to have_been_requested.once
  end

  it "treats a default 403 as forbidden without refreshing or changing the grant" do
    stub_request(:get, url).to_return(status: 403, body: '{"error":"missing_scope"}', headers: json_headers)
    refresh = stub_request(:post, "https://slack.com/api/oauth.v2.access")
    expect { grant.connector.client.get("example") }.to raise_error(Connectors::Forbidden) { |error|
      expect(error.body).to eq("error" => "missing_scope")
    }
    expect(refresh).not_to have_been_requested
    expect(grant.reload).to be_active
  end

  it "preserves the original POST body when retrying with a refreshed token" do
    body = { "text" => "send exactly this" }
    old = stub_request(:post, url).with(body: body.to_json, headers: { "Authorization" => "Bearer old" })
      .to_return(status: 401, body: '{"error":"expired"}', headers: json_headers)
    fresh = stub_request(:post, url).with(body: body.to_json, headers: { "Authorization" => "Bearer fresh" })
      .to_return(status: 200, body: '{"ok":true}', headers: json_headers)
    stub_request(:post, "https://slack.com/api/oauth.v2.access").to_return(
      status: 200, body: '{"access_token":"fresh"}', headers: json_headers)
    expect(grant.connector.client.post("example", body).body).to eq("ok" => true)
    expect(old).to have_been_requested.once
    expect(fresh).to have_been_requested.once
  end

  it "stops after one refresh when the replacement token is also rejected" do
    request = stub_request(:get, url).to_return(status: 401, body: "unauthorized")
    refresh = stub_request(:post, "https://slack.com/api/oauth.v2.access").to_return(
      status: 200, body: '{"access_token":"fresh"}', headers: json_headers)
    expect { grant.connector.client.get("example") }.to raise_error(Connectors::AuthenticationFailed)
    expect(request).to have_been_requested.twice
    expect(refresh).to have_been_requested.once
  end

  it "supports an explicitly declared provider token-expiry status" do
    klass = Class.new(Connectors::Connector) do
      connector key: :custom_expiry, auth: :oauth2, base_url: "https://expiry.test"
      oauth2 token_url: "https://expiry.test/token", token_expired_status: 403
      def refresh!
        # Existing connector implementations can also persist with ActiveRecord.
        grant.update!(credentials: { "access_token" => "fresh" })
      end
    end
    grant.update!(connector_key: klass.connector_key, credentials: { "access_token" => "old" })
    stub_request(:get, "https://expiry.test/data").with(headers: { "Authorization" => "Bearer old" }).to_return(status: 403)
    stub_request(:get, "https://expiry.test/data").with(headers: { "Authorization" => "Bearer fresh" }).to_return(status: 200)
    expect(grant.connector.client.get("data").status).to eq(200)
    expect(grant.reload.credentials_hash["access_token"]).to eq("fresh")
  end
end
