require "rails_helper"

RSpec.describe "MCP authorization challenge handoff" do
  let(:owner) { Owner.create!(name: "Challenge owner") }
  let(:grant) { Connectors::Grant.create!(owner: owner, connector_key: "mcp", credentials: { "server_url" => "https://mcp.example.test", "auth_mode" => "oauth" }) }
  let(:access) { Connectors::MCP::Access.new(grant: grant, actor: owner) }

  it "preserves a server scope challenge through encrypted browser state" do
    token = Connectors::MCP::AuthorizationContext.encode(grant: grant, challenge: { "scope" => "write" })
    expect(token).not_to include("write")
    expect(Connectors::MCP::AuthorizationContext.decode(token, access: access)).to eq("scope" => "write")
  end

  it "rejects tampered state" do
    expect { Connectors::MCP::AuthorizationContext.decode("forged", access: access) }.to raise_error(Connectors::MCP::AccessDenied)
  end

  it "rejects state issued for a previous destination" do
    token = Connectors::MCP::AuthorizationContext.encode(grant: grant, challenge: { "scope" => "write" })
    grant.update_credentials!("server_url" => "https://new.example.test")
    expect { Connectors::MCP::AuthorizationContext.decode(token, access: access) }.to raise_error(Connectors::MCP::AccessDenied)
  end
end
