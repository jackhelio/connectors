require "rails_helper"
require "timeout"

# Real committed rows and separate PostgreSQL connections are necessary here:
# transactional fixtures would hide the rows from the worker connections.
RSpec.describe "Concurrent credential use" do
  self.use_transactional_tests = false

  before do
    @owner = Owner.create!(name: "Concurrent owner")
    @grant = Connectors::Grant.create!(owner: @owner, connector_key: "slack",
      credentials: { "access_token" => "old", "refresh_token" => "rotating-token" })
    Connectors.configuration.oauth_credentials = { slack: { client_id: "id", client_secret: "secret" } }
  end

  after do
    @threads&.each { |thread| thread.kill if thread.alive? }
    @threads&.each(&:join)
    @grant&.destroy!
    @owner&.destroy!
  end

  def workers(&block)
    @threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          block.call(Connectors::Grant.find(@grant.id))
        end
      end
    end
  end

  def results
    Timeout.timeout(10) { @threads.map(&:value) }
  end

  it "exchanges a rotating refresh token once when two requests fail simultaneously" do
    failed = Queue.new
    release = Queue.new
    stub_request(:get, "https://slack.com/api/data").with(headers: { "Authorization" => "Bearer old" })
      .to_return do
        failed << true
        Timeout.timeout(5) { release.pop }
        { status: 401, body: "expired" }
      end
    refreshed = stub_request(:post, "https://slack.com/api/oauth.v2.access")
      .with(body: hash_including("refresh_token" => "rotating-token"))
      .to_return(status: 200, headers: { "Content-Type" => "application/json" },
        body: '{"access_token":"fresh","refresh_token":"rotated-token"}')
    stub_request(:get, "https://slack.com/api/data").with(headers: { "Authorization" => "Bearer fresh" })
      .to_return(status: 200)

    workers { |grant| grant.connector.client.get("data").status }
    Timeout.timeout(5) { 2.times { failed.pop } }
    2.times { release << true }
    expect(results).to eq([ 200, 200 ])
    expect(refreshed).to have_been_requested.once
    expect(@grant.reload.credentials_hash["refresh_token"]).to eq("rotated-token")
  end

  it "does not revive a grant revoked while an authenticated request was in flight" do
    stub_request(:get, "https://slack.com/api/data").to_return do
      Connectors::Grant.find(@grant.id).update!(status: :revoked)
      { status: 401, body: "expired" }
    end
    refresh = stub_request(:post, "https://slack.com/api/oauth.v2.access")
    expect { @grant.connector.client.get("data") }.to raise_error(Connectors::AuthenticationFailed, /revoked/)
    expect(refresh).not_to have_been_requested
    expect(@grant.reload).to be_revoked
  end

  it "rechecks expiry under the lock before running proactive authentication" do
    klass = Class.new(Connectors::Connector) do
      connector key: :concurrent_pre_auth, auth: :api_key, base_url: "https://preauth.test"
      authenticate type: :generic, properties: { headers: { "Authorization" => "=Bearer {{$credentials.access_token}}" } }
      pre_authentication do |_credentials, helpers|
        helpers.http_request(method: :post, url: "https://preauth.test/token")
        { "access_token" => "fresh", "expires_at" => 1.hour.from_now.to_i }
      end
    end
    @grant.update!(connector_key: klass.connector_key)
    token = stub_request(:post, "https://preauth.test/token").to_return(status: 200, body: "{}")
    stub_request(:get, "https://preauth.test/data").with(headers: { "Authorization" => "Bearer fresh" }).to_return(status: 200)
    ready = Queue.new
    release = Queue.new
    workers do |grant|
      grant.credentials_hash
      ready << true
      Timeout.timeout(5) { release.pop }
      grant.connector.client.get("data").status
    end
    Timeout.timeout(5) { 2.times { ready.pop } }
    2.times { release << true }
    expect(results).to eq([ 200, 200 ])
    expect(token).to have_been_requested.once
  end

  it "serializes concurrent ticks of the same polling instance, including first creation" do
    klass = Class.new(Connectors::Connector) do
      connector key: :concurrent_poll, auth: :api_key, base_url: "https://poll.test"
      polling do |_grant, data|
        data["position"] = data.fetch("position", 0) + 1
        [ data["position"] ]
      end
    end
    @grant.update!(connector_key: klass.connector_key)
    ready = Queue.new
    release = Queue.new
    workers do |grant|
      ready << true
      Timeout.timeout(5) { release.pop }
      Connectors::PollRunner.run(grant, instance_key: "trigger")[:items].first
    end
    Timeout.timeout(5) { 2.times { ready.pop } }
    2.times { release << true }
    expect(results.sort).to eq([ 1, 2 ])
    expect(@grant.poll_states.count).to eq(1)
    expect(@grant.poll_states.first.data).to eq("position" => 2)
  end
end
