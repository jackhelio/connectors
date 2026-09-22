require "rails_helper"

RSpec.describe "MCP OAuth" do
  let(:owner) { Owner.create!(name: "OAuth owner") }
  let(:grant) { Connectors::Grant.create!(owner: owner, connector_key: "mcp", credentials: { "server_url" => "https://resource.example.test/mcp", "auth_mode" => "oauth" }) }
  let(:authorization) { Connectors::MCP::Authorization.new(grant: grant, actor: owner) }
  let(:metadata) { { issuer: "https://auth.example.test", authorization_endpoint: "https://auth.example.test/authorize", token_endpoint: "https://auth.example.test/token", registration_endpoint: "https://auth.example.test/register", code_challenge_methods_supported: [ "S256" ], authorization_response_iss_parameter_supported: true } }

  before do
    allow(Addrinfo).to receive(:getaddrinfo).and_return([ Addrinfo.ip("93.184.216.34") ])
    Connectors.configuration.mcp.callback_url = "https://app.example.test/mcp/callback"
    stub_request(:get, "https://resource.example.test/.well-known/oauth-protected-resource/mcp").to_return(headers: { "Content-Type" => "application/json" }, body: { resource: "https://resource.example.test/mcp", authorization_servers: [ "https://auth.example.test" ], scopes_supported: [ "read" ] }.to_json)
    stub_request(:get, "https://auth.example.test/.well-known/oauth-authorization-server").to_return { { headers: { "Content-Type" => "application/json" }, body: metadata.to_json } }
    stub_request(:post, "https://auth.example.test/register").to_return(headers: { "Content-Type" => "application/json" }, body: { client_id: "registered", token_endpoint_auth_method: "none" }.to_json)
  end

  def start(challenge = {})
    url = authorization.start(challenge: challenge)
    URI.decode_www_form(URI(url).query).to_h
  end

  def token_response(payload = {})
    stub_request(:post, "https://auth.example.test/token").to_return(headers: { "Content-Type" => "application/json" }, body: { access_token: "access", token_type: "Bearer", refresh_token: "refresh", expires_in: 3600 }.merge(payload).to_json)
  end

  it "persists PKCE state and completes on a fresh service instance exactly once" do
    params = start
    expect(params).to include("scope" => "read", "resource" => "https://resource.example.test/mcp", "code_challenge_method" => "S256")
    exchange = token_response
    new_service = Connectors::MCP::Authorization.new(grant: Connectors::Grant.find(grant.id), actor: owner)
    new_service.complete(state: params.fetch("state"), code: "code", iss: "https://auth.example.test")
    expect(grant.reload.credentials_hash.dig("mcp_oauth", "tokens", "access_token")).to eq("access")
    expect { new_service.complete(state: params.fetch("state"), code: "code", iss: "https://auth.example.test") }.to raise_error(Connectors::MCP::AccessDenied)
    expect(exchange).to have_been_requested.once
    expect(Connectors::McpAuthorization.first.read_attribute_before_type_cast(:payload)).not_to include("code_verifier")
  end

  it "rejects a missing required issuer without exchanging the code" do
    params = start
    exchange = token_response
    expect { authorization.complete(state: params["state"], code: "code") }.to raise_error(Connectors::MCP::AccessDenied)
    expect(exchange).not_to have_been_requested
  end

  it "refuses the callback after the destination changes" do
    params = start
    grant.update_credentials!("server_url" => "https://different.example.test/mcp")
    expect { authorization.complete(state: params["state"], code: "code", iss: "https://auth.example.test") }.to raise_error(Connectors::MCP::AccessDenied)
  end

  it "preserves previously requested scopes even when the token omits scope" do
    params = start("scope" => "read")
    token_response
    authorization.complete(state: params["state"], code: "code", iss: "https://auth.example.test")
    expect(start("scope" => "write")["scope"].split).to contain_exactly("read", "write")
  end

  it "rejects an authorization server without S256" do
    metadata[:code_challenge_methods_supported] = [ "plain" ]
    expect { start }.to raise_error(Connectors::MCP::ConfigurationRequired, /S256/)
  end

  it "registers only grant types supported by the authorization server" do
    metadata[:grant_types_supported] = [ "authorization_code" ]
    start
    expect(WebMock).to have_requested(:post, "https://auth.example.test/register").with { |request| JSON.parse(request.body)["grant_types"] == [ "authorization_code" ] }
  end
  it "uses a pre-registered client bound to the selected issuer" do
    grant.update_credentials!("client_information" => { "client_id" => "configured", "issuer" => "https://auth.example.test", "token_endpoint_auth_method" => "none" })
    expect(start["client_id"]).to eq("configured")
    expect(WebMock).not_to have_requested(:post, "https://auth.example.test/register")
  end

  it "does not persist a configured client secret in transaction or token namespaces" do
    grant.update_credentials!("client_information" => { "client_id" => "configured", "issuer" => "https://auth.example.test", "client_secret" => "vault-secret", "token_endpoint_auth_method" => "client_secret_basic" })
    params = start
    expect(Connectors::McpAuthorization.first.payload.to_json).not_to include("vault-secret")
    exchange = token_response
    authorization.complete(state: params["state"], code: "code", iss: "https://auth.example.test")
    expect(exchange).to have_been_requested.once
    expect(grant.reload.credentials_hash["mcp_oauth"].to_json).not_to include("vault-secret")
  end

  it "prefers a valid advertised client metadata document over DCR" do
    metadata[:client_id_metadata_document_supported] = true
    Connectors.configuration.mcp.client_metadata_url = "https://app.example.test/client.json"
    stub_request(:get, "https://app.example.test/client.json").to_return(headers: { "Content-Type" => "application/json" }, body: {
      client_id: "https://app.example.test/client.json", client_name: "Test", redirect_uris: [ Connectors.configuration.mcp.callback_url ]
    }.to_json)
    expect(start["client_id"]).to eq("https://app.example.test/client.json")
    expect(WebMock).not_to have_requested(:post, "https://auth.example.test/register")
  end

  it "reports configuration required when neither registration option is available" do
    metadata.delete(:registration_endpoint)
    expect { start }.to raise_error(Connectors::MCP::ConfigurationRequired, /client information/)
  end

  it "rejects issuer mismatches during discovery" do
    metadata[:issuer] = "https://other.example.test"
    expect { start }.to raise_error(Connectors::MCP::ConfigurationRequired, /issuer/)
  end

  it "rejects a callback from another local actor" do
    params = start
    other = Owner.create!(name: "Other")
    expect { Connectors::MCP::Authorization.new(grant: grant, actor: other).complete(state: params["state"], code: "code", iss: "https://auth.example.test") }.to raise_error(Connectors::MCP::AccessDenied)
  end

  it "rejects expired state before exchanging a code" do
    params = start
    Connectors::McpAuthorization.first.update!(expires_at: 1.second.ago)
    exchange = token_response
    expect { authorization.complete(state: params["state"], code: "code", iss: "https://auth.example.test") }.to raise_error(Connectors::MCP::AccessDenied)
    expect(exchange).not_to have_been_requested
  end

  it "validates issuer on error callbacks and does not reflect server error text" do
    params = start
    expect { authorization.complete(state: params["state"], iss: "https://evil.example.test", error: "secret") }.to raise_error(Connectors::MCP::AccessDenied) { |e| expect(e.message).not_to include("secret") }
    expect(Connectors::McpAuthorization.first.status).to eq("failed")
  end

  it "sends the matching PKCE verifier and resource to the token endpoint" do
    params = start
    exchange = token_response.with do |req|
      form = URI.decode_www_form(req.body).to_h
      Base64.urlsafe_encode64(Digest::SHA256.digest(form.fetch("code_verifier")), padding: false) == params["code_challenge"] &&
        form["resource"] == "https://resource.example.test/mcp" && form["redirect_uri"] == Connectors.configuration.mcp.callback_url
    end
    authorization.complete(state: params["state"], code: "code", iss: "https://auth.example.test")
    expect(exchange).to have_been_requested.once
  end

  it "does not guess a legacy issuer after transient discovery failures" do
    stub_request(:get, "https://resource.example.test/.well-known/oauth-protected-resource/mcp").to_return(status: 503)
    expect { start }.to raise_error(Connectors::MCP::HTTPError)
    expect(WebMock).not_to have_requested(:post, "https://auth.example.test/register")
  end

  it "requests offline_access only when the authorization server advertises it" do
    expect(start("scope" => "read offline_access")["scope"]).to eq("read")
    metadata[:scopes_supported] = [ "offline_access" ]
    expect(start["scope"].split).to contain_exactly("read", "offline_access")
  end
end
