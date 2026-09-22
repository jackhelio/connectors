require "rails_helper"

RSpec.describe Connectors::MCP::TokenEndpoint do
  let(:metadata) { { "token_endpoint" => "https://auth.example.test/token", "token_endpoint_auth_methods_supported" => [ method ] } }
  let(:method) { "client_secret_basic" }
  let(:client) { { "client_id" => "client:id", "client_secret" => "client secret", "token_endpoint_auth_method" => method } }
  let(:params) { { "grant_type" => "authorization_code", "code" => "code", "resource" => "https://mcp.example.test/mcp" } }
  before { allow(Addrinfo).to receive(:getaddrinfo).and_return([ Addrinfo.ip("93.184.216.34") ]) }

  def token_request
    stub_request(:post, "https://auth.example.test/token").to_return(headers: { "Content-Type" => "application/json" }, body: { access_token: "access", token_type: "Bearer" }.to_json)
  end

  it "encodes HTTP Basic client credentials and sends the resource indicator" do
    request = token_request.with(headers: { "Authorization" => "Basic #{Base64.strict_encode64('client%3Aid:client+secret')}" }, body: hash_including("resource" => "https://mcp.example.test/mcp"))
    expect(described_class.exchange(metadata: metadata, client: client, params: params)["access_token"]).to eq("access")
    expect(request).to have_been_requested.once
  end

  context "client_secret_post" do
    let(:method) { "client_secret_post" }
    it "uses the configured advertised method" do
      request = token_request.with(body: hash_including("client_secret" => "client secret", "client_id" => "client:id"))
      described_class.exchange(metadata: metadata, client: client, params: params)
      expect(request).to have_been_requested.once
    end
  end

  context "private_key_jwt" do
    let(:method) { "private_key_jwt" }
    it "uses a host assertion signer without storing a private key" do
      Connectors.configuration.mcp.assertion_provider = ->(id, audience) { expect(id).to eq("client:id"); expect(audience).to eq(metadata["token_endpoint"]); "signed-assertion" }
      request = token_request.with(body: hash_including("client_assertion" => "signed-assertion", "client_assertion_type" => "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"))
      described_class.exchange(metadata: metadata, client: client, params: params)
      expect(request).to have_been_requested.once
    end
  end

  it "refuses an unadvertised authentication method" do
    metadata["token_endpoint_auth_methods_supported"] = [ "private_key_jwt" ]
    expect { described_class.exchange(metadata: metadata, client: client, params: params) }.to raise_error(Connectors::MCP::ConfigurationRequired)
  end

  it "refuses downgrading a confidential client to none" do
    client["token_endpoint_auth_method"] = "none"
    metadata["token_endpoint_auth_methods_supported"] = [ "none" ]
    expect { described_class.exchange(metadata: metadata, client: client, params: params) }.to raise_error(Connectors::MCP::ConfigurationRequired)
  end
  it "rejects tokens that cannot be safely used in a Bearer header" do
    stub_request(:post, "https://auth.example.test/token").to_return(headers: { "Content-Type" => "application/json" }, body: { access_token: "token\r\ninjected", token_type: "Bearer" }.to_json)
    expect { described_class.exchange(metadata: metadata, client: client, params: params) }.to raise_error(Connectors::MCP::ProtocolError)
  end
end
