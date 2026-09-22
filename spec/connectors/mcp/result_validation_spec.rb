require "rails_helper"

RSpec.describe "MCP result validation" do
  let(:owner) { Owner.create!(name: "Result owner") }
  let(:grant) { Connectors::Grant.create!(owner: owner, connector_key: "mcp", credentials: { "server_url" => "https://mcp.example.test/mcp", "auth_mode" => "none" }) }
  let(:client) { Connectors::MCP::Client.new(grant: grant, actor: owner) }
  let(:result) { { "content" => [ { "type" => "text", "text" => "okay" } ] } }
  before do
    allow(Addrinfo).to receive(:getaddrinfo).and_return([ Addrinfo.ip("93.184.216.34") ])
    stub_request(:post, "https://mcp.example.test/mcp").to_return do |req|
      request = JSON.parse(req.body)
      data = request["method"] == "tools/list" ? { tools: [ { name: "echo", inputSchema: { type: "object" } } ] } : result
      { headers: { "Content-Type" => "application/json" }, body: { jsonrpc: "2.0", id: request["id"], result: data }.to_json }
    end
  end

  it "rejects a text block missing text" do
    result["content"] = [ { "type" => "text" } ]
    expect { client.call_tool(name: "echo", arguments: {}) }.to raise_error(Connectors::MCP::ProtocolError)
  end

  it "rejects an invalid isError type" do
    result["isError"] = "false"
    expect { client.call_tool(name: "echo", arguments: {}) }.to raise_error(Connectors::MCP::ProtocolError)
  end

  it "preserves a valid tool execution error as a result" do
    result["isError"] = true
    expect(client.call_tool(name: "echo", arguments: {})).to eq(result)
  end
end
