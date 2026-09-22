require "rails_helper"
require "timeout"

RSpec.describe "MCP concurrent authorization", :mcp_concurrency do
  self.use_transactional_tests = false
  before do
    @owner = Owner.create!(name: "Concurrent MCP")
    @grant = Connectors::Grant.create!(owner: @owner, connector_key: "mcp", credentials: { "server_url" => "https://mcp.example.test/mcp", "auth_mode" => "oauth" })
    access = Connectors::MCP::Access.new(grant: @grant, actor: @owner)
    @grant.update_credentials!("mcp_oauth" => { "fingerprint" => access.fingerprint, "requested_scopes" => [ "read" ], "resource" => "https://mcp.example.test/mcp",
      "client" => { "client_id" => "client", "token_endpoint_auth_method" => "none" },
      "metadata" => { "issuer" => "https://auth.example.test", "token_endpoint" => "https://auth.example.test/token" },
      "tokens" => { "access_token" => "old", "refresh_token" => "rotating" } })
    allow(Addrinfo).to receive(:getaddrinfo).and_return([ Addrinfo.ip("93.184.216.34") ])
  end
  after do
    @threads&.each { |t| t.kill if t.alive? }
    @threads&.each(&:join)
    @grant&.destroy!
    @owner&.destroy!
  end

  def workers(&block)
    ready, go = Queue.new, Queue.new
    @threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          Timeout.timeout(5) { go.pop }
          block.call(Connectors::Grant.find(@grant.id))
        end
      end
    end
    Timeout.timeout(5) { 2.times { ready.pop } }
    2.times { go << true }
    Timeout.timeout(10) { @threads.map(&:value) }
  end

  it "exchanges a rotating refresh token once across separate connections" do
    exchange = stub_request(:post, "https://auth.example.test/token").with(body: hash_including("refresh_token" => "rotating"))
      .to_return(headers: { "Content-Type" => "application/json" }, body: { access_token: "fresh", token_type: "Bearer", refresh_token: "rotated" }.to_json)
    results = workers { |grant| Connectors::MCP::Authorization.new(grant: grant, actor: @owner).refresh(expected_token: "old") }
    expect(results).to eq([ "fresh", "fresh" ])
    expect(exchange).to have_been_requested.once
    expect(@grant.reload.credentials_hash.dig("mcp_oauth", "tokens", "refresh_token")).to eq("rotated")
  end

  it "allows only one worker to claim a pending interaction" do
    access = Connectors::MCP::Access.new(grant: @grant, actor: @owner)
    interaction = Connectors::McpInteraction.create!(grant: @grant, actor_key: access.actor_key, fingerprint: access.fingerprint, expires_at: 1.minute.from_now, payload: { "test" => true })
    results = workers do |grant|
      Connectors::McpInteraction.find(interaction.id).claim!(Connectors::MCP::Access.new(grant: grant, actor: @owner))
      :claimed
    rescue Connectors::MCP::AccessDenied
      :rejected
    end
    expect(results).to contain_exactly(:claimed, :rejected)
  end

  it "preserves credentials and avoids interactive consent on a transient refresh failure" do
    stub_request(:post, "https://auth.example.test/token").to_return(status: 503, body: "unavailable")
    expect { Connectors::MCP::Authorization.new(grant: @grant, actor: @owner).refresh(expected_token: "old") }.to raise_error(Connectors::MCP::HTTPError)
    expect(@grant.reload.credentials_hash.dig("mcp_oauth", "tokens", "refresh_token")).to eq("rotating")
  end

  it "keeps the previous refresh token when no replacement is issued" do
    stub_request(:post, "https://auth.example.test/token").to_return(headers: { "Content-Type" => "application/json" }, body: { access_token: "fresh", token_type: "Bearer" }.to_json)
    Connectors::MCP::Authorization.new(grant: @grant, actor: @owner).refresh(expected_token: "old")
    expect(@grant.reload.credentials_hash.dig("mcp_oauth", "tokens", "refresh_token")).to eq("rotating")
  end

  it "clears invalid authorization without reviving revoked grants" do
    stub_request(:post, "https://auth.example.test/token").to_return(status: 400, body: { error: "invalid_grant" }.to_json)
    expect { Connectors::MCP::Authorization.new(grant: @grant, actor: @owner).refresh(expected_token: "old") }.to raise_error(Connectors::MCP::AuthorizationRequired)
    expect(@grant.reload.credentials_hash["mcp_oauth"]).to be_nil
    @grant.update!(status: :revoked)
    expect { Connectors::MCP::Authorization.new(grant: @grant, actor: @owner).access_token }.to raise_error(Connectors::MCP::AccessDenied)
  end
end
