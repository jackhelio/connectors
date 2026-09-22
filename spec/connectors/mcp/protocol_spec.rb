require "rails_helper"

RSpec.describe "MCP protocol contracts" do
  let(:url) { "https://mcp.example.test/mcp" }
  let(:transport) { Connectors::MCP::Transport.new(url: url) }
  before { allow(Addrinfo).to receive(:getaddrinfo).and_return([ Addrinfo.ip("93.184.216.34") ]) }

  def json_result(result = {}, &block)
    stub_request(:post, url).to_return do |req|
      body = JSON.parse(req.body)
      response = block ? block.call(body) : { jsonrpc: "2.0", id: body["id"], result: result }
      { headers: { "Content-Type" => "application/json" }, body: response.to_json }
    end
  end

  it "rejects unknown result types" do
    json_result("resultType" => "surprise")
    expect { transport.request("tools/list") }.to raise_error(Connectors::MCP::ProtocolError, /result type/)
  end

  it "accepts absent resultType for backward compatibility" do
    json_result("tools" => [])
    expect(transport.request("tools/list")).to eq("tools" => [])
  end

  it "rejects mismatched IDs" do
    json_result { |_| { jsonrpc: "2.0", id: "wrong", result: {} } }
    expect { transport.request("tools/list") }.to raise_error(Connectors::MCP::ProtocolError, /ID/)
  end

  it "does not downgrade modern protocol errors or expose untrusted error text" do
    request = json_result { |r| { jsonrpc: "2.0", id: r["id"], error: { code: -32020, message: "secret" } } }
    expect { transport.request("tools/list") }.to raise_error(Connectors::MCP::ProtocolError) { |error| expect(error.code).to eq(-32020); expect(error.message).not_to include("secret") }
    expect(request).to have_been_requested.once
  end

  it "reads an SSE result after progress notifications" do
    stub_request(:post, url).to_return do |req|
      id = JSON.parse(req.body)["id"]
      { headers: { "Content-Type" => "text/event-stream" }, body: "data: #{ { jsonrpc: '2.0', method: 'notifications/progress', params: {} }.to_json }\n\ndata: #{ { jsonrpc: '2.0', id: id, result: { content: [] } }.to_json }\n\n" }
    end
    expect(transport.request("tools/call", { "name" => "echo" })).to eq("content" => [])
  end

  it "does not resume a dropped modern stream with a legacy GET or repeat a call" do
    request = stub_request(:post, url).to_return(headers: { "Content-Type" => "text/event-stream" }, body: "id: event-1\ndata: #{ { jsonrpc: '2.0', method: 'notifications/progress' }.to_json }\n\n")
    expect { transport.request("tools/call", { "name" => "write" }) }.to raise_error(Connectors::MCP::TransportError, /unknown/)
    expect(request).to have_been_requested.once
    expect(WebMock).not_to have_requested(:get, url)
  end

  it "rejects oversized JSON" do
    Connectors.configuration.mcp.max_bytes = 1024
    json_result("content" => [ "x" * 2000 ])
    expect { transport.request("tools/list") }.to raise_error(Connectors::MCP::TransportError, /size/)
  end

  it "delivers acknowledged subscription notifications and closes normally" do
    stub_request(:post, url).to_return do |req|
      id = JSON.parse(req.body)["id"]
      meta = { "io.modelcontextprotocol/subscriptionId" => id }
      messages = [ { jsonrpc: "2.0", method: "notifications/subscriptions/acknowledged", params: { _meta: meta, notifications: { toolsListChanged: true } } },
        { jsonrpc: "2.0", method: "notifications/tools/list_changed", params: { _meta: meta } },
        { jsonrpc: "2.0", id: id, result: { resultType: "complete", _meta: meta } } ]
      { headers: { "Content-Type" => "text/event-stream" }, body: messages.map { |m| "data: #{m.to_json}\n\n" }.join }
    end
    seen = []
    result = transport.request("subscriptions/listen", { "notifications" => { "toolsListChanged" => true } }, subscription: true) { |m| seen << m["method"] }
    expect(seen).to eq(%w[notifications/subscriptions/acknowledged notifications/tools/list_changed])
    expect(result["resultType"]).to eq("complete")
  end

  it "rejects subscription notifications before acknowledgment" do
    stub_request(:post, url).to_return do |req|
      id = JSON.parse(req.body)["id"]
      { headers: { "Content-Type" => "text/event-stream" }, body: "data: #{ { jsonrpc: '2.0', method: 'notifications/tools/list_changed', params: { _meta: { 'io.modelcontextprotocol/subscriptionId' => id } } }.to_json }\n\n" }
    end
    expect { transport.request("subscriptions/listen", {}, subscription: true) { } }.to raise_error(Connectors::MCP::ProtocolError, /acknowledgment/)
  end

  it "rejects notifications outside the acknowledged subscription filter" do
    stub_request(:post, url).to_return do |req|
      meta = { "io.modelcontextprotocol/subscriptionId" => JSON.parse(req.body)["id"] }
      messages = [ { jsonrpc: "2.0", method: "notifications/subscriptions/acknowledged", params: { _meta: meta, notifications: { toolsListChanged: true } } },
        { jsonrpc: "2.0", method: "notifications/resources/list_changed", params: { _meta: meta } } ]
      { headers: { "Content-Type" => "text/event-stream" }, body: messages.map { |m| "data: #{m.to_json}\n\n" }.join }
    end
    expect { transport.request("subscriptions/listen", { "notifications" => { "toolsListChanged" => true } }, subscription: true) { } }.to raise_error(Connectors::MCP::ProtocolError, /filter/)
  end

  it "does not automatically follow redirects carrying credentials" do
    stub_request(:post, url).to_return(status: 302, headers: { "Location" => "https://evil.example.test/" })
    expect { transport.request("tools/list") }.to raise_error(Connectors::MCP::HTTPError)
    expect(WebMock).not_to have_requested(:get, "https://evil.example.test/")
  end

  it "distinguishes insufficient scope from an unrelated 403" do
    stub_request(:post, url).to_return(status: 403, headers: { "WWW-Authenticate" => 'Bearer error="insufficient_scope", scope="write"' })
    expect { transport.request("tools/list") }.to raise_error(Connectors::MCP::AuthorizationRequired) { |e| expect(e.challenge["scope"]).to eq("write") }
    stub_request(:post, url).to_return(status: 403)
    expect { transport.request("tools/list") }.to raise_error(Connectors::MCP::HTTPError)
  end
end

RSpec.describe "MCP schemas and egress" do
  it "rejects remote refs before any network request" do
    expect { Connectors::MCP::Schema.new("$ref" => "https://schema.example.test/private") }.to raise_error(Connectors::MCP::ValidationError, /references/)
  end

  it "rejects unsupported dialects" do
    expect { Connectors::MCP::Schema.new("$schema" => "https://example.test/custom") }.to raise_error(Connectors::MCP::ValidationError, /dialect/)
  end

  it "validates local refs and preserves false, null and arrays" do
    schema = Connectors::MCP::Schema.new("$defs" => { "value" => { "type" => [ "boolean", "null", "array" ] } }, "$ref" => "#/$defs/value")
    [ false, nil, [ 1 ] ].each { |value| expect { schema.validate!(value) }.not_to raise_error }
    expect { schema.validate!("no") }.to raise_error(Connectors::MCP::ValidationError)
  end

  %w[127.0.0.1 169.254.169.254 10.0.0.1 ::1 ::ffff:127.0.0.1].each do |address|
    it "blocks DNS resolution to #{address}" do
      allow(Addrinfo).to receive(:getaddrinfo).and_return([ Addrinfo.ip(address) ])
      expect { Connectors::MCP::HTTP.new.call(url: "https://mcp.example.test/") }.to raise_error(Connectors::MCP::ConfigurationRequired, /restricted/)
    end
  end

  it "refuses mixed public and private DNS answers" do
    allow(Addrinfo).to receive(:getaddrinfo).and_return([ Addrinfo.ip("93.184.216.34"), Addrinfo.ip("10.0.0.1") ])
    expect { Connectors::MCP::HTTP.new.call(url: "https://mcp.example.test/") }.to raise_error(Connectors::MCP::ConfigurationRequired)
  end

  %w[http://remote.example.test/mcp https://user:pass@example.test/mcp https://example.test/mcp#fragment file:///etc/passwd].each do |url|
    it "rejects unsafe destination #{url}" do
      expect { Connectors::MCP::HTTP.new.validate_url!(url) }.to raise_error(Connectors::MCP::ConfigurationRequired)
    end
  end
end
