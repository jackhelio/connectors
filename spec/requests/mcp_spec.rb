require "rails_helper"

RSpec.describe "MCP connection endpoints", type: :request do
  let(:owner) { Owner.create!(name: "MCP API owner") }
  let(:grant) { Connectors::Grant.create!(owner: owner, connector_key: "mcp", credentials: { "server_url" => "https://mcp.example.test/mcp", "auth_mode" => "bearer", "bearer_token" => "secret-token", "headers" => { "X-Api-Key" => "header-secret" } }) }
  before do
    Connectors.configuration.current_owner_resolver = ->(_) { owner }
    allow(Addrinfo).to receive(:getaddrinfo).and_return([ Addrinfo.ip("93.184.216.34") ])
  end

  it "never returns MCP secrets through include_data" do
    get "/connectors/credentials/#{grant.id}", params: { include_data: true }
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("secret-token", "header-secret")
    expect(response.parsed_body.fetch("data")).to eq("server_url" => "https://mcp.example.test/mcp", "auth_mode" => "bearer")
  end

  [ "30", "Wed, 23 Sep 2026 12:00:00 GMT", nil, "invalid" ].each do |retry_after|
    it "returns MCP rate limits with #{retry_after.inspect} retry guidance" do
      upstream = stub_request(:post, "https://mcp.example.test/mcp").to_return(status: 429,
        headers: (retry_after ? { "Retry-After" => retry_after } : {}), body: "upstream-sensitive-body")
      get "/connectors/credentials/#{grant.id}/mcp/tools"
      expect(response).to have_http_status(:too_many_requests)
      expect(response.parsed_body.dig("error", "type")).to eq("rate_limited")
      expected = retry_after == "invalid" ? nil : retry_after
      expect(response.headers["Retry-After"]).to eq(expected)
      expect(response.parsed_body.dig("error", "retry_after")).to eq(expected)
      expect(response.body).not_to include("upstream-sensitive-body", "secret-token")
      expect(upstream).to have_been_requested.once
    end
  end

  it "does not replay a rate-limited tool invocation" do
    stub_request(:post, "https://mcp.example.test/mcp")
      .with { |request| JSON.parse(request.body)["method"] == "tools/list" }.to_return do |request|
        { status: 200, headers: { "Content-Type" => "application/json" }, body: {
          jsonrpc: "2.0", id: JSON.parse(request.body)["id"],
          result: { tools: [ { name: "write", inputSchema: { type: "object" } } ] }
        }.to_json }
      end
    invocation = stub_request(:post, "https://mcp.example.test/mcp")
      .with { |request| JSON.parse(request.body)["method"] == "tools/call" }
      .to_return(status: 429, headers: { "Retry-After" => "30" })
    post "/connectors/credentials/#{grant.id}/mcp/tools/call", params: { name: "write", arguments: {} }, as: :json
    expect(response).to have_http_status(:too_many_requests)
    expect(response.headers["Retry-After"]).to eq("30")
    expect(invocation).to have_been_requested.once
  end

  it "keeps other upstream errors sanitized as bad gateway" do
    stub_request(:post, "https://mcp.example.test/mcp").to_return(status: 503,
      headers: { "Retry-After" => "30" }, body: "upstream-sensitive-body")
    get "/connectors/credentials/#{grant.id}/mcp/tools"
    expect(response).to have_http_status(:bad_gateway)
    expect(response.parsed_body.dig("error", "type")).to eq("transport_error")
    expect(response.headers["Retry-After"]).to be_nil
    expect(response.body).not_to include("upstream-sensitive-body")
  end

  it "allows shared viewers to read only public MCP configuration" do
    connection = grant
    viewer = Owner.create!(name: "MCP viewer")
    Connectors::CredentialShare.create!(grant: connection, principal_type: "Owner", principal_id: viewer.id, role: "viewer")
    Connectors.configuration.current_owner_resolver = ->(_) { viewer }
    get "/connectors/credentials/#{connection.id}", params: { include_data: true }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("data")).to eq("server_url" => "https://mcp.example.test/mcp", "auth_mode" => "bearer")
  end

  it "rejects injected OAuth state at credential creation" do
    post "/connectors/credentials", params: { type: "mcp", data: { server_url: "https://mcp.example.test/mcp", auth_mode: "oauth", mcp_oauth: { tokens: { access_token: "injected" } } } }, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(Connectors::Grant.where(connector_key: "mcp")).to be_empty
  end

  it "rejects caller headers that could override the transport" do
    post "/connectors/credentials", params: { type: "mcp", data: { server_url: "https://mcp.example.test/mcp", auth_mode: "none", headers: { "Host" => "internal" } } }, as: :json
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "lists native tool descriptors for an authorized grant" do
    stub_request(:post, "https://mcp.example.test/mcp").with(headers: { "Authorization" => "Bearer secret-token" }).to_return do |req|
      { headers: { "Content-Type" => "application/json" }, body: { jsonrpc: "2.0", id: JSON.parse(req.body)["id"], result: { tools: [] } }.to_json }
    end
    get "/connectors/credentials/#{grant.id}/mcp/tools"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("tools" => [])
  end
  it "disconnects an MCP credential locally and clears its stored secrets" do
    post "/connectors/credentials/#{grant.id}/revoke"
    expect(response).to have_http_status(:ok)
    expect(grant.reload).to be_revoked
    expect(grant.stored_credentials_hash).not_to have_key("bearer_token")
    expect { Connectors::MCP::Client.new(grant: grant, actor: owner).tools }.to raise_error(Connectors::MCP::AccessDenied)
  end

  it "prevents a shared viewer from calling tools and a shared editor from replacing auth" do
    connection = grant
    other = Owner.create!(name: "Shared user")
    share = Connectors::CredentialShare.create!(grant: connection, principal_type: "Owner", principal_id: other.id, role: "viewer")
    Connectors.configuration.current_owner_resolver = ->(_) { other }
    post "/connectors/credentials/#{connection.id}/mcp/tools/call", params: { name: "write", arguments: {} }, as: :json
    expect(response).to have_http_status(:forbidden)
    share.update!(role: "editor")
    post "/connectors/credentials/#{connection.id}/mcp/authorize", as: :json
    expect(response).to have_http_status(:forbidden)
    patch "/connectors/credentials/#{connection.id}", params: { data: { bearer_token: "replacement" } }, as: :json
    expect(response).to have_http_status(:unauthorized)
    expect(connection.reload.credentials_hash["bearer_token"]).to eq("secret-token")
  end
  it "creates managed bearer credentials without copying the vault token into the database" do
    Connectors.configuration.secrets_resolver = ->(_) { { "bearer_token" => "vault-only" } }
    post "/connectors/credentials", params: { type: "mcp", is_managed: true, external_ref: "vault/mcp", data: { server_url: "https://mcp.example.test/mcp", auth_mode: "bearer" } }, as: :json
    expect(response).to have_http_status(:created)
    created = Connectors::Grant.find(response.parsed_body.fetch("id"))
    expect(created.stored_credentials_hash).not_to have_key("bearer_token")
    expect(created.credentials_hash["bearer_token"]).to eq("vault-only")
  end
end
