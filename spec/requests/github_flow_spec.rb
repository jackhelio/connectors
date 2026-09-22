require "rails_helper"

RSpec.describe "GitHub connector flow", type: :request do
  let(:owner) { Owner.create!(name: "gh owner") }

  before do
    Connectors.configure do |c|
      c.owner_class_name       = "Owner"
      c.current_owner_resolver = ->(_ctrl) { owner }
      c.host_base_url          = "https://app.test"
      c.oauth_credentials      = {
        github: { client_id: "gh-client", client_secret: "gh-secret" }
      }
    end
  end

  describe "OAuth callback" do
    let(:state) do
      Connectors::OAuth::State.encode(connector_key: :github, owner_gid: owner.to_global_id.to_s)
    end

    before do
      stub_request(:post, "https://github.com/login/oauth/access_token")
        .with(body: hash_including("client_id" => "gh-client", "client_secret" => "gh-secret"))
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { access_token: "ghu_live", token_type: "bearer", scope: "repo,read:user" }.to_json)

      stub_request(:get, "https://api.github.com/user")
        .with(headers: { "Authorization" => "Bearer ghu_live" })
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { id: 8675309, login: "octo-dev" }.to_json)
    end

    it "exchanges the code, persists a Grant, and denormalizes the GitHub login + user_id" do
      expect {
        get "/connectors/github/callback", params: { code: "ghc_abc", state: state }
      }.to change(Connectors::Grant, :count).by(1)

      grant = Connectors::Grant.last
      expect(grant.connector_key).to       eq("github")
      expect(grant.external_account_id).to eq("8675309")
      expect(grant.credentials).to include(
        "access_token" => "ghu_live",
        "login"        => "octo-dev",
        "user_id"      => 8675309,
        "scope"        => "repo,read:user"
      )
    end
  end

  describe "Per-grant webhook" do
    let(:webhook_secret) { "shh-this-is-the-repo-secret" }
    let!(:grant) do
      Connectors::Grant.create!(
        owner:               owner,
        connector_key:       "github",
        external_account_id: "8675309",
        credentials:         { "access_token" => "ghu_live", "webhook_secret" => webhook_secret }
      )
    end

    def sign(body, secret: webhook_secret)
      "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", secret, body)
    end

    def post_webhook(payload:, secret: webhook_secret, signature: nil)
      body = payload.to_json
      post "/connectors/github/#{grant.id}/webhook",
           params:  body,
           headers: {
             "Content-Type"          => "application/json",
             "X-Hub-Signature-256"   => signature || sign(body, secret: secret),
             "X-Github-Event"        => "issues"
           }
    end

    it "accepts a request signed with the grant's webhook_secret" do
      expect {
        post_webhook(payload: { "action" => "opened", "issue" => { "id" => 42, "title" => "bug" } })
      }.to change(Connectors::WebhookEvent, :count).by(1)

      expect(response).to have_http_status(:accepted)
      event = Connectors::WebhookEvent.last
      expect(event.grant_id).to eq(grant.id)
      expect(event.payload_hash["action"]).to eq("opened")
    end

    it "rejects a request signed with the wrong secret" do
      post_webhook(payload: { "action" => "opened" }, secret: "wrong-secret")
      expect(response).to have_http_status(:unauthorized)
      expect(Connectors::WebhookEvent.count).to eq(0)
    end

    it "rejects a request with no signature header" do
      body = { "action" => "opened" }.to_json
      post "/connectors/github/#{grant.id}/webhook",
           params:  body,
           headers: { "Content-Type" => "application/json" }
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "API methods" do
    let!(:grant) do
      Connectors::Grant.create!(
        owner: owner, connector_key: "github",
        credentials: { "access_token" => "ghu_live" }
      )
    end

    it "create_issue posts to repos/:owner/:repo/issues with the token" do
      stub_request(:post, "https://api.github.com/repos/octo/foo/issues")
        .with(headers: { "Authorization" => "Bearer ghu_live" },
              body:    hash_including("title" => "broken"))
        .to_return(status: 201, headers: { "Content-Type" => "application/json" },
                   body: { number: 7, html_url: "https://github.com/octo/foo/issues/7" }.to_json)

      issue = grant.connector.create_issue(repo: "octo/foo", title: "broken")
      expect(issue["number"]).to eq(7)
    end
  end
end
