require "rails_helper"

RSpec.describe "MCP interactive tool calls" do
  let(:owner) { Owner.create!(name: "Interaction owner") }
  let(:grant) { Connectors::Grant.create!(owner: owner, connector_key: "mcp", credentials: { "server_url" => "https://mcp.example.test/mcp", "auth_mode" => "none" }) }
  let(:client) { Connectors::MCP::Client.new(grant: grant, actor: owner) }
  before do
    allow(Addrinfo).to receive(:getaddrinfo).and_return([ Addrinfo.ip("93.184.216.34") ])
    Connectors.configuration.mcp.elicitation_modes = [ "url" ]
    @calls = []
    stub_request(:post, "https://mcp.example.test/mcp").to_return do |req|
      body = JSON.parse(req.body)
      @calls << body
      result = if body["method"] == "tools/list"
        { tools: [ { name: "pay", inputSchema: { type: "object" } } ] }
      elsif body.dig("params", "inputResponses")
        { resultType: "complete", content: [ { type: "text", text: "done" } ] }
      else
        { resultType: "input_required", requestState: "opaque", inputRequests: { "approval" => { method: "elicitation/create", params: { mode: "url", message: "Authorize", url: "https://provider.example.test/consent" } } } }
      end
      { headers: { "Content-Type" => "application/json" }, body: { jsonrpc: "2.0", id: body["id"], result: result }.to_json }
    end
  end

  it "resumes a durable interaction once using the original arguments and a new request ID" do
    pending = client.call_tool(name: "pay", arguments: { "amount" => 5 })
    expect(pending).to include("resultType" => "input_required", "interaction_id" => be_a(String))
    result = Connectors::MCP::Client.new(grant: grant.reload, actor: owner).resume(interaction_id: pending["interaction_id"], responses: { "approval" => { "action" => "accept" } })
    expect(result["content"]).to eq([ { "type" => "text", "text" => "done" } ])
    calls = @calls.select { |r| r["method"] == "tools/call" }
    expect(calls.last.dig("params", "requestState")).to eq("opaque")
    expect(calls.last.dig("params", "arguments")).to eq("amount" => 5)
    expect(calls.map { |r| r["id"] }.uniq.size).to eq(2)
    expect { client.resume(interaction_id: pending["interaction_id"], responses: {}) }.to raise_error(Connectors::MCP::AccessDenied)
  end

  it "rejects undeclared elicitation modes" do
    Connectors.configuration.mcp.elicitation_modes = []
    expect { client.call_tool(name: "pay", arguments: {}) }.to raise_error(Connectors::MCP::ProtocolError)
  end
  it "accepts decimal form values permitted by the normative protocol definition" do
    Connectors.configuration.mcp.elicitation_modes = [ "form" ]
    stub_request(:post, "https://mcp.example.test/mcp").to_return do |req|
      request = JSON.parse(req.body)
      result = if request["method"] == "tools/list"
        { tools: [ { name: "pay", inputSchema: { type: "object" } } ] }
      elsif request.dig("params", "inputResponses")
        expect(request.dig("params", "inputResponses", "amount", "content", "value")).to eq(0.5)
        { content: [] }
      else
        { resultType: "input_required", requestState: "opaque", inputRequests: { amount: { method: "elicitation/create", params: { mode: "form", message: "Amount", requestedSchema: { type: "object", properties: { value: { type: "number" } }, required: [ "value" ] } } } } }
      end
      { headers: { "Content-Type" => "application/json" }, body: { jsonrpc: "2.0", id: request["id"], result: result }.to_json }
    end
    pending = client.call_tool(name: "pay", arguments: {})
    expect(client.resume(interaction_id: pending["interaction_id"], responses: { "amount" => { "action" => "accept", "content" => { "value" => 0.5 } } })).to eq("content" => [])
  end

  it "allows correcting invalid input without consuming the pending interaction" do
    pending = client.call_tool(name: "pay", arguments: {})
    expect { client.resume(interaction_id: pending["interaction_id"], responses: { "approval" => { "action" => "unknown" } }) }.to raise_error(Connectors::MCP::ValidationError)
    result = client.resume(interaction_id: pending["interaction_id"], responses: { "approval" => { "action" => "accept" } })
    expect(result["content"].first["text"]).to eq("done")
    expect(@calls.count { |r| r["method"] == "tools/call" }).to eq(2)
  end
end
