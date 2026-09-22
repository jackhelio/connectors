require "rails_helper"

RSpec.describe "MCP remote tools" do
  let(:owner) { Owner.create!(name: "MCP owner") }
  let(:grant) { Connectors::Grant.create!(owner: owner, connector_key: "mcp", credentials: { "server_url" => "https://mcp.example.test/mcp", "auth_mode" => "none" }) }
  let(:client) { Connectors::MCP::Client.new(grant: grant, actor: owner) }
  let(:tool) { { "name" => "echo", "title" => "Echo", "_meta" => { "example.test/tag" => "value" }, "inputSchema" => { "type" => "object", "required" => [ "value" ], "properties" => { "value" => { "type" => "string" } } } } }

  before do
    stub_mcp_dns
  end

  def respond(&block)
    stub_request(:post, "https://mcp.example.test/mcp").to_return do |req|
      body = JSON.parse(req.body)
      { status: 200, headers: { "Content-Type" => "application/json" }, body: { jsonrpc: "2.0", id: body["id"], result: block.call(body) }.to_json }
    end
  end

  it "preserves full descriptors and stamps modern requests without initialization" do
    requests = []
    respond { |body| requests << body; { "resultType" => "complete", "tools" => [ tool ], "ttlMs" => 0, "cacheScope" => "private" } }
    expect(client.tools).to eq([ tool ])
    expect(requests.map { |r| r["method"] }).to eq([ "tools/list" ])
    expect(requests.first.dig("params", "_meta", "io.modelcontextprotocol/protocolVersion")).to eq("2026-07-28")
  end

  it "rejects missing required arguments before sending tools/call" do
    respond { |_| { "tools" => [ tool ] } }
    expect { client.call_tool(name: "echo", arguments: {}) }.to raise_error(Connectors::MCP::ValidationError)
    expect(WebMock).not_to have_requested(:post, "https://mcp.example.test/mcp").with { |req| JSON.parse(req.body)["method"] == "tools/call" }
  end

  it "refuses a repeated pagination cursor instead of returning an incomplete catalog" do
    respond { |_| { "tools" => [ tool ], "nextCursor" => "repeat" } }
    expect { client.tools }.to raise_error(Connectors::MCP::ProtocolError, /cursor/)
  end

  it "rejects callers who do not own or share the grant before networking" do
    stranger = Owner.create!(name: "Stranger")
    expect { Connectors::MCP::Client.new(grant: grant, actor: stranger).tools }.to raise_error(Connectors::MCP::AccessDenied)
  end
  it "follows an empty string cursor and stops only when it is absent" do
    seen = []
    respond do |body|
      seen << body.dig("params", "cursor")
      seen.size == 1 ? { "tools" => [ tool ], "nextCursor" => "" } : { "tools" => [] }
    end
    expect(client.tools).to eq([ tool ])
    expect(seen).to eq([ nil, "" ])
  end

  it "excludes invalid header annotations while retaining valid tools" do
    bad = tool.deep_dup.merge("name" => "invalid")
    bad["inputSchema"]["properties"]["value"] = { "type" => "number", "x-mcp-header" => "Value" }
    respond { |_| { "tools" => [ bad, tool ] } }
    expect(client.tools).to eq([ tool ])
  end

  it "mirrors annotated nested arguments into encoded headers" do
    tool["inputSchema"] = { "type" => "object", "properties" => { "nested" => { "type" => "object", "properties" => { "region" => { "type" => "string", "x-mcp-header" => "Region" } } } } }
    respond { |body| body["method"] == "tools/list" ? { "tools" => [ tool ] } : { "content" => [] } }
    client.call_tool(name: "echo", arguments: { "nested" => { "region" => "éurope" } })
    expect(WebMock).to have_requested(:post, "https://mcp.example.test/mcp").with(headers: { "Mcp-Param-Region" => "=?base64?#{Base64.strict_encode64('éurope')}?=" })
  end

  it "validates structured array output without changing the result" do
    tool["outputSchema"] = { "type" => "array", "items" => { "type" => "integer" } }
    respond { |body| body["method"] == "tools/list" ? { "tools" => [ tool ] } : { "content" => [], "structuredContent" => [ 1, 2 ] } }
    expect(client.call_tool(name: "echo", arguments: { "value" => "input" })["structuredContent"]).to eq([ 1, 2 ])
  end

  it "does not return results to an actor whose share was revoked during the request" do
    other = Owner.create!(name: "Shared editor")
    share = Connectors::CredentialShare.create!(grant: grant, principal_type: "Owner", principal_id: other.id, role: "editor")
    respond do |body|
      if body["method"] == "tools/list"
        { "tools" => [ tool ] }
      else
        share.destroy!
        { "content" => [] }
      end
    end
    shared = Connectors::MCP::Client.new(grant: grant, actor: other)
    expect { shared.call_tool(name: "echo", arguments: { "value" => "x" }) }.to raise_error(Connectors::MCP::AccessDenied)
  end
end
