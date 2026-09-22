require "rails_helper"

RSpec.describe "MCP cancellation" do
  it "cancels before opening a network connection" do
    cancellation = Connectors::MCP::Cancellation.new
    cancellation.cancel
    expect { Connectors::MCP::Transport.new(url: "https://mcp.example.test/").request("tools/list", {}, cancellation: cancellation) }.to raise_error(Connectors::MCP::Cancelled)
  end
end
