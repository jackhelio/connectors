require "rails_helper"

RSpec.describe "OAuth connection safety", type: :request do
  let(:owner) { Owner.create!(name: "Connection owner") }
  let(:other_owner) { Owner.create!(name: "Other owner") }
  let!(:grant) do
    Connectors::Grant.create!(owner: owner, connector_key: "slack", external_account_id: "T1",
      credentials: { "access_token" => "old", "refresh_token" => "refresh", "team_id" => "T1" })
  end

  before do
    Connectors.configure do |c|
      c.current_owner_resolver = ->(_) { owner }
      c.host_base_url = "https://app.test"
      c.oauth_credentials = { slack: { client_id: "client", client_secret: "secret" } }
    end
  end

  def authorize(grant_id: nil, format: ".json")
    get "/connectors/slack/authorize#{format}", params: { grant_id: grant_id }.compact
    url = format.empty? ? response.location : response.parsed_body.fetch("authorize_url")
    URI.decode_www_form(URI.parse(url).query).to_h.fetch("state")
  end

  def token_response(account: "T1")
    stub_request(:post, "https://slack.com/api/oauth.v2.access").to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: { ok: true, access_token: "new", team: { id: account } }.to_json)
  end

  it "creates a second account without overwriting the first" do
    state = authorize
    token_response(account: "T2")
    expect {
      get "/connectors/slack/callback", params: { code: "code", state: state }
    }.to change(Connectors::Grant, :count).by(1)
    expect(response).to have_http_status(:ok)
    expect(grant.reload.credentials_hash["access_token"]).to eq("old")
    expect(Connectors::Grant.find(response.parsed_body["grant_id"]).external_account_id).to eq("T2")
  end

  [ "", ".json" ].each do |format|
    it "reconnects an explicit account through authorize#{format}, preserving its refresh token" do
      state = authorize(grant_id: grant.id, format: format)
      token_response
      expect {
        post "/connectors/oauth/exchange", params: { code: "code", state: state }
      }.not_to change(Connectors::Grant, :count)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["grant_id"]).to eq(grant.id)
      expect(grant.reload.credentials_hash).to include("access_token" => "new", "refresh_token" => "refresh")
    end
  end

  it "rejects switching a known account during reconnection" do
    state = authorize(grant_id: grant.id)
    token_response(account: "T2")
    get "/connectors/slack/callback", params: { code: "code", state: state }
    expect(response).to have_http_status(:unauthorized)
    expect(grant.reload.external_account_id).to eq("T1")
    expect(grant.credentials_hash["access_token"]).to eq("old")
  end

  it "rejects reconnection to another owner's connection" do
    grant.update!(owner: other_owner)
    get "/connectors/slack/authorize.json", params: { grant_id: grant.id }
    expect(response).to have_http_status(:not_found)
  end

  it "rejects reconnection through a different provider" do
    grant.update!(connector_key: "gmail")
    get "/connectors/slack/authorize.json", params: { grant_id: grant.id }
    expect(response).to have_http_status(:not_found)
  end

  it "rejects state issued before credential rotation without exchanging the code" do
    state = authorize(grant_id: grant.id)
    grant.update_credentials!(access_token: "rotated")
    endpoint = token_response
    get "/connectors/slack/callback", params: { code: "code", state: state }
    expect(response).to have_http_status(:unauthorized)
    expect(endpoint).not_to have_been_requested
    expect(grant.reload.credentials_hash["access_token"]).to eq("rotated")
  end

  it "rechecks the connection after the exchange so concurrent revocation wins" do
    state = authorize(grant_id: grant.id)
    stub_request(:post, "https://slack.com/api/oauth.v2.access").to_return do
      grant.update!(status: :revoked)
      { status: 200, headers: { "Content-Type" => "application/json" },
        body: { ok: true, access_token: "new", team: { id: "T1" } }.to_json }
    end
    get "/connectors/slack/callback", params: { code: "code", state: state }
    expect(response).to have_http_status(:unauthorized)
    expect(grant.reload).to be_revoked
    expect(grant.credentials_hash["access_token"]).to eq("old")
  end

  it "rejects revocation by an unrelated owner before calling the provider" do
    grant.update!(owner: other_owner)
    expect(Connectors::OAuth::Revoke).not_to receive(:call)
    post "/connectors/credentials/#{grant.id}/revoke"
    expect(response).to have_http_status(:not_found)
    expect(grant.reload).to be_active
  end

  %w[viewer editor].each do |role|
    it "rejects revocation by a shared #{role}" do
      grant.update!(owner: other_owner)
      grant.shares.create!(principal_type: "Team", principal_id: owner.id, role: role)
      Connectors.configuration.principal_resolver = ->(_) { [ [ "Team", owner.id ] ] }
      expect(Connectors::OAuth::Revoke).not_to receive(:call)
      post "/connectors/credentials/#{grant.id}/revoke"
      expect(response).to have_http_status(:unauthorized)
      expect(grant.reload).to be_active
    end
  end
end
