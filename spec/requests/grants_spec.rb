require "rails_helper"

RSpec.describe "GET /connectors/grants", type: :request do
  let(:owner)       { Owner.create!(name: "primary owner") }
  let(:other_owner) { Owner.create!(name: "other owner") }

  before do
    Connectors.configure do |c|
      c.owner_class_name       = "Owner"
      c.current_owner_resolver = ->(_ctrl) { owner }
      c.host_base_url          = "https://app.test"
    end
  end

  context "with no grants" do
    it "returns an empty list" do
      get "/connectors/grants"
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq("grants" => [])
    end
  end

  context "with grants for several owners and connectors" do
    let!(:slack_grant) do
      Connectors::Grant.create!(
        owner: owner,
        connector_key: "slack",
        display_name: "Acme Slack",
        external_account_id: "T123",
        status: :active,
        last_used_at: 1.hour.ago,
        credentials: { "access_token" => "xoxb", "scope" => "chat:write,channels:read,users:read" }
      )
    end

    let!(:echo_grant) do
      Connectors::Grant.create!(
        owner: owner,
        connector_key: "echo",
        status: :errored,
        credentials: { "api_key" => "k" }
      )
    end

    let!(:other_grant) do
      Connectors::Grant.create!(
        owner: other_owner,
        connector_key: "slack",
        credentials: { "access_token" => "leaked-if-returned" }
      )
    end

    it "returns only the current owner's grants" do
      get "/connectors/grants"
      expect(response).to have_http_status(:ok)
      ids = response.parsed_body["grants"].map { |g| g["id"] }
      expect(ids).to match_array([ slack_grant.id, echo_grant.id ])
    end

    it "serializes metadata without leaking credentials" do
      get "/connectors/grants"
      slack = response.parsed_body["grants"].find { |g| g["connector_key"] == "slack" }

      expect(slack).to include(
        "id"                  => slack_grant.id,
        "connector_key"       => "slack",
        "display_name"        => "Acme Slack",
        "external_account_id" => "T123",
        "status"              => "active"
      )
      expect(slack["scopes"]).to match_array(%w[chat:write channels:read users:read])
      expect(slack).not_to have_key("credentials")
      expect(response.body).not_to include("xoxb")
    end

    it "filters by connector_key when supplied" do
      get "/connectors/grants", params: { connector_key: "echo" }
      keys = response.parsed_body["grants"].map { |g| g["connector_key"] }
      expect(keys).to eq([ "echo" ])
    end

    it "returns scopes as null when the grant has none recorded" do
      get "/connectors/grants", params: { connector_key: "echo" }
      echo = response.parsed_body["grants"].first
      expect(echo["scopes"]).to be_nil
    end
  end

  context "when no owner is configured" do
    before do
      Connectors.configure { |c| c.current_owner_resolver = ->(_ctrl) { nil } }
    end

    it "returns 401" do
      get "/connectors/grants"
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
