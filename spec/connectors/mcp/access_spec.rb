require "rails_helper"

RSpec.describe Connectors::MCP::Access do
  let(:owner) { Owner.create!(name: "Access owner") }
  let(:grant) { Connectors::Grant.create!(owner: owner, connector_key: "mcp", credentials: { "server_url" => "https://mcp.example.test", "auth_mode" => "headers", "headers" => { "X-One" => "one", "X-Two" => "two" } }) }
  let(:access) { described_class.new(grant: grant, actor: owner) }

  it "binds credential values without depending on JSON object key order" do
    grant.update!(is_managed: true)
    Connectors.configuration.secrets_resolver = ->(_) { { "headers" => { "X-One" => "one", "X-Two" => "two" } } }
    first = access.fingerprint
    Connectors.configuration.secrets_resolver = ->(_) { { "headers" => { "X-Two" => "two", "X-One" => "one" } } }
    access.require!
    expect(access.fingerprint).to eq(first)
  end

  it "invalidates pending work when the managed-secret reference changes" do
    first = access.fingerprint
    grant.update!(external_ref: "vault/new-reference")
    expect(access.fingerprint).not_to eq(first)
  end
end
