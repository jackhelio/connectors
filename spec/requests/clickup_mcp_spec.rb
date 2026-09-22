require "rails_helper"

RSpec.describe "ClickUp MCP connector", type: :request do
  let(:owner) { Owner.create!(name: "ClickUp owner") }
  let(:endpoint) { "https://mcp.clickup.com/mcp" }
  let(:issuer) { "https://mcp.clickup.com" }
  let(:callback) { "https://app.example.test/connectors/mcp/oauth/callback" }

  before do
    Connectors.configuration.current_owner_resolver = ->(_) { owner }
    Connectors.configuration.mcp.callback_url = callback
    stub_mcp_dns("mcp.clickup.com")
  end

  def create_connection(data = {})
    post "/connectors/credentials", params: { type: "clickup", name: "ClickUp workspace", data: data }, as: :json
    expect(response).to have_http_status(:created)
    Connectors::Grant.find(response.parsed_body.fetch("id"))
  end

  def fixture(name)
    File.read(Rails.root.join("../../spec/fixtures/mcp/clickup/#{name}.json"))
  end

  it "advertises ClickUp and its grant-scoped MCP workflow in the catalog" do
    get "/connectors/types/clickup"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("display_name" => "ClickUp", "actions" => [])
    expect(response.parsed_body.dig("connector", "mcp")).to include("server_url" => endpoint, "auth_mode" => "oauth")
    expect(response.parsed_body.dig("connector", "mcp", "authorize_url")).to eq("/connectors/credentials/:id/mcp/authorize")
    expect(response.parsed_body.dig("connector", "redirect_uri")).to eq(callback)
    expect(response.parsed_body.fetch("properties").map { |field| field["name"] }).not_to include("bearer_token", "headers", "server_url")
  end

  it "creates the fixed official endpoint and OAuth configuration without requiring data" do
    post "/connectors/credentials", params: { type: "clickup", name: "ClickUp" }, as: :json
    expect(response).to have_http_status(:created)
    grant = Connectors::Grant.find(response.parsed_body.fetch("id"))
    expect(grant.credentials_hash).to eq("server_url" => endpoint, "auth_mode" => "oauth")
  end

  it "rejects alternate destinations, static authentication and internal OAuth state" do
    [ { server_url: "https://other.example.test/mcp" }, { auth_mode: "bearer", bearer_token: "personal-token" },
      { headers: { Authorization: "personal-token" } }, { mcp_oauth: { tokens: { access_token: "injected" } } } ].each do |data|
      post "/connectors/credentials", params: { type: "clickup", data: data }, as: :json
      expect(response).to have_http_status(:unprocessable_content)
    end
    expect(Connectors::Grant.where(connector_key: "clickup")).to be_empty
  end

  it "enforces provider configuration for direct Ruby grants and managed secrets" do
    grant = Connectors::Grant.create!(owner: owner, connector_key: "clickup", credentials: { server_url: "https://other.example.test/mcp", auth_mode: "oauth" })
    client = Connectors::MCP::Client.new(grant: grant, actor: owner)
    expect { client.tools }.to raise_error(Connectors::MCP::ValidationError)
    grant.update!(credentials: { server_url: endpoint, auth_mode: "oauth" }, is_managed: true, external_ref: "vault/clickup")
    Connectors.configuration.secrets_resolver = ->(_) { { "server_url" => "https://other.example.test/mcp" } }
    expect { client.tools }.to raise_error(Connectors::MCP::ValidationError)
    expect(WebMock).not_to have_requested(:post, "https://other.example.test/mcp")
  end

  it "uses ClickUp discovery and PKCE, then discovers and invokes native tools after consent" do
    grant = create_connection
    stub_request(:post, endpoint).to_return(status: 401, headers: {
      "WWW-Authenticate" => 'Bearer realm="MCP Server", error="invalid_token", error_description="Bearer token required", resource_metadata="https://mcp.clickup.com/.well-known/oauth-protected-resource/mcp"'
    })
    stub_request(:get, "#{issuer}/.well-known/oauth-protected-resource/mcp").to_return(headers: { "Content-Type" => "application/json" }, body: fixture("resource"))
    stub_request(:get, "#{issuer}/.well-known/oauth-authorization-server").to_return(headers: { "Content-Type" => "application/json" }, body: fixture("authorization_server"))
    registration = stub_request(:post, "#{issuer}/oauth/register").with do |request|
      body = JSON.parse(request.body)
      body["grant_types"] == [ "authorization_code" ] && body["redirect_uris"] == [ callback ] && body["token_endpoint_auth_method"] == "none"
    end.to_return(headers: { "Content-Type" => "application/json" }, body: { client_id: "fixture-client", token_endpoint_auth_method: "none" }.to_json)

    get "/connectors/credentials/#{grant.id}/mcp/tools"
    expect(response).to have_http_status(:unauthorized)
    context = response.parsed_body.fetch("authorization_context")
    post "/connectors/credentials/#{grant.id}/mcp/authorize", params: { authorization_context: context }, as: :json
    expect(response).to have_http_status(:ok)
    url = URI(response.parsed_body.fetch("authorization_url"))
    expect("#{url.scheme}://#{url.host}#{url.path}").to eq("#{issuer}/oauth/authorize")
    query = URI.decode_www_form(url.query).to_h
    expect(query).to include("scope" => "read write", "resource" => endpoint, "code_challenge_method" => "S256")
    expect(registration).to have_been_requested.once

    exchange = stub_request(:post, "#{issuer}/oauth/token").with do |request|
      form = URI.decode_www_form(request.body).to_h
      form["client_id"] == "fixture-client" && form["resource"] == endpoint &&
        Base64.urlsafe_encode64(Digest::SHA256.digest(form.fetch("code_verifier")), padding: false) == query["code_challenge"]
    end.to_return(headers: { "Content-Type" => "application/json" }, body: { access_token: "fixture-access", token_type: "Bearer", scope: "read write" }.to_json)
    post "/connectors/mcp/oauth/callback", params: { state: query["state"], code: "fixture-code", iss: issuer }, as: :json
    expect(response).to have_http_status(:ok)
    expect(exchange).to have_been_requested.once

    # Synthetic tool: the real account-scoped catalog requires user consent.
    tool = { "name" => "fixture_tool", "inputSchema" => { "type" => "object", "properties" => { "text" => { "type" => "string" } }, "required" => [ "text" ] } }
    remote = stub_request(:post, endpoint).with(headers: { "Authorization" => "Bearer fixture-access" }).to_return do |request|
      message = JSON.parse(request.body)
      result = message["method"] == "tools/list" ? { tools: [ tool ] } : { content: [ { type: "text", text: message.dig("params", "arguments", "text") } ] }
      { headers: { "Content-Type" => "application/json" }, body: { jsonrpc: "2.0", id: message["id"], result: result }.to_json }
    end
    get "/connectors/credentials/#{grant.id}/mcp/tools"
    expect(response.parsed_body).to eq("tools" => [ tool ])
    post "/connectors/credentials/#{grant.id}/mcp/tools/call", params: { name: "fixture_tool", arguments: { text: "preserved" } }, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq("content" => [ { "type" => "text", "text" => "preserved" } ])
    expect(remote).to have_been_requested.times(3)
    get "/connectors/credentials", params: { type: "clickup", include_data: true }
    expect(response.body).not_to include("fixture-access", "fixture-client", "code_verifier")
    expect(response.parsed_body.fetch("credentials").first.fetch("data")).to eq("server_url" => endpoint, "auth_mode" => "oauth")
  end

  it "keeps shared editors from replacing ClickUp authentication" do
    grant = create_connection
    other = Owner.create!(name: "Shared editor")
    Connectors::CredentialShare.create!(grant: grant, principal_type: "Owner", principal_id: other.id, role: "editor")
    Connectors.configuration.current_owner_resolver = ->(_) { other }
    patch "/connectors/credentials/#{grant.id}", params: { data: { client_information: { client_id: "replacement" } } }, as: :json
    expect(response).to have_http_status(:unauthorized)
    post "/connectors/credentials/#{grant.id}/mcp/authorize", as: :json
    expect(response).to have_http_status(:forbidden)
  end

  it "rejects provider overrides on update without clearing existing authorization" do
    grant = create_connection
    grant.update_credentials!("mcp_oauth" => { "tokens" => { "access_token" => "existing" } })
    patch "/connectors/credentials/#{grant.id}", params: { data: { server_url: "https://other.example.test/mcp" } }, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    expect(grant.reload.credentials_hash.dig("mcp_oauth", "tokens", "access_token")).to eq("existing")
    expect(grant.credentials_hash.fetch("server_url")).to eq(endpoint)
  end

  it "invalidates previous authorization when the owner replaces client registration" do
    grant = create_connection
    grant.update_credentials!("mcp_oauth" => { "tokens" => { "access_token" => "existing" } })
    patch "/connectors/credentials/#{grant.id}", params: { data: { client_information: { client_id: "replacement", issuer: issuer, token_endpoint_auth_method: "none" } } }, as: :json
    expect(response).to have_http_status(:ok)
    expect(grant.reload.credentials_hash["mcp_oauth"]).to be_nil
    get "/connectors/credentials/#{grant.id}", params: { include_data: true }
    expect(response.parsed_body.fetch("data")).not_to have_key("client_information")
  end

  it "disconnects locally and clears authorization state" do
    grant = create_connection
    grant.update_credentials!("mcp_oauth" => { "tokens" => { "access_token" => "secret" } })
    post "/connectors/credentials/#{grant.id}/revoke"
    expect(response).to have_http_status(:ok)
    expect(grant.reload).to be_revoked
    expect(grant.credentials_hash).not_to have_key("mcp_oauth")
  end
end
