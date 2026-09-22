require "rails_helper"
require "puma"
require "mcp/server/transports/streamable_http_transport"

RSpec.describe "MCP official Ruby server interoperability" do
  let(:owner) { Owner.create!(name: "Interop owner") }
  before do
    Connectors.configuration.mcp.allow_loopback_http = true
    sdk_server = ::MCP::Server.new(name: "independent-sdk-server", version: "1.6.0")
    sdk_server.define_tool(name: "greet", input_schema: { type: "object", properties: { name: { type: "string" } }, required: [ "name" ] }) do |name:|
      ::MCP::Tool::Response.new([ { type: "text", text: "Hello #{name}" } ])
    end
    app = ::MCP::Server::Transports::StreamableHTTPTransport.new(sdk_server, enable_json_response: true)
    @server = Puma::Server.new(app)
    @server.add_tcp_listener("127.0.0.1", 0)
    @port = @server.binder.connected_ports.first
    @server.run
  end
  after { @server&.stop(true) }

  it "discovers and calls a tool over real HTTP with the official server" do
    grant = Connectors::Grant.create!(owner: owner, connector_key: "mcp", credentials: { "server_url" => "http://127.0.0.1:#{@port}/mcp", "auth_mode" => "none" })
    client = Connectors::MCP::Client.new(grant: grant, actor: owner)
    expect(client.tools.map { |t| t["name"] }).to eq([ "greet" ])
    expect(client.call_tool(name: "greet", arguments: { "name" => "Ruby" })["content"]).to eq([ { "type" => "text", "text" => "Hello Ruby" } ])
  end
end
