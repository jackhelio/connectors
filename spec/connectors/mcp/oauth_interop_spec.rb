require "rails_helper"
require "open3"
require "timeout"

RSpec.describe "MCP independent OAuth server interoperability" do
  self.use_transactional_tests = false

  before do
    Connectors.configuration.mcp.allow_loopback_http = true
    Connectors.configuration.mcp.callback_url = "https://app.example.test/callback"
    @stdin, @stdout, @stderr, @process = Open3.popen3(ENV.fetch("PYTHON", "python3"), File.expand_path("../../support/mcp/oauth_server.py", __dir__))
    port = Timeout.timeout(5) { Integer(@stdout.gets) }
    @origin = "http://127.0.0.1:#{port}"
    @owner = Owner.create!(name: "Independent OAuth")
    @grants = []
  end

  after do
    @grants.each(&:destroy!)
    @owner&.destroy!
    Process.kill("TERM", @process.pid) if @process&.alive?
    @process&.join
    [ @stdin, @stdout, @stderr ].compact.each(&:close)
  end

  def grant(path, mode, extra = {})
    @grants << Connectors::Grant.create!(owner: @owner, connector_key: "mcp", credentials: { "server_url" => @origin + path, "auth_mode" => mode }.merge(extra))
    @grants.last
  end

  def consent(url)
    response = Net::HTTP.get_response(URI(url))
    expect(response.code).to eq("302")
    URI.decode_www_form(URI(response.fetch("location")).query).to_h
  end

  it "performs consent, callback in a separate Rails process, scope upgrade and refresh" do
    connection = grant("/mcp", "oauth")
    client = Connectors::MCP::Client.new(grant: connection, actor: @owner)
    auth = Connectors::MCP::Authorization.new(grant: connection, actor: @owner)
    challenge = begin
      client.tools
    rescue Connectors::MCP::AuthorizationRequired => error
      error.challenge
    end
    callback = consent(auth.start(challenge: challenge))
    script = <<~RUBY_CODE
      require #{Rails.root.join('config/environment').to_s.inspect}
      Connectors.configuration.mcp.allow_loopback_http = true
      input = JSON.parse(STDIN.read)
      grant = Connectors::Grant.find(input.fetch("grant_id"))
      Connectors::MCP::Authorization.new(grant: grant, actor: grant.owner).complete(**input.fetch("callback").symbolize_keys)
    RUBY_CODE
    output, errors, status = Open3.capture3(RbConfig.ruby, "-rbundler/setup", "-e", script, stdin_data: { grant_id: connection.id, callback: callback }.to_json)
    expect(status.success?).to be(true), "Separate callback failed: #{output} #{errors}"
    expect(client.tools.first["name"]).to eq("echo")
    step_up = begin
      client.call_tool(name: "echo", arguments: {})
    rescue Connectors::MCP::AuthorizationRequired => error
      error.challenge
    end
    upgraded = consent(auth.start(challenge: step_up))
    auth.complete(**upgraded.symbolize_keys)
    expect(connection.reload.credentials_hash.dig("mcp_oauth", "requested_scopes")).to contain_exactly("read", "write")
    expect(client.call_tool(name: "echo", arguments: {})["content"].first["text"]).to eq("called")
    previous = connection.credentials_hash.dig("mcp_oauth", "tokens", "access_token")
    Net::HTTP.post(URI(@origin + "/expire"), "")
    expect(client.tools.size).to eq(1)
    expect(connection.reload.credentials_hash.dig("mcp_oauth", "tokens", "access_token")).not_to eq(previous)
  end

  it "connects to public and static-bearer servers without OAuth" do
    [ grant("/public", "none"), grant("/static", "bearer", "bearer_token" => "fixture-static") ].each do |connection|
      client = Connectors::MCP::Client.new(grant: connection, actor: @owner)
      expect(client.call_tool(name: "echo", arguments: {})["content"].first["text"]).to eq("called")
    end
  end
end
