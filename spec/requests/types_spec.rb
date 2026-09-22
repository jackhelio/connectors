require "rails_helper"

RSpec.describe "GET /connectors/types", type: :request do
  it "returns the registered connector catalog using n8n vocabulary" do
    get "/connectors/types"
    expect(response).to have_http_status(:ok)

    names = response.parsed_body["types"].map { |t| t["name"] }
    expect(names).to include("slack", "echo")
  end

  describe "OAuth2 connector (Slack)" do
    let(:slack) do
      get "/connectors/types"
      response.parsed_body["types"].find { |t| t["name"] == "slack" }
    end

    it "declares oauth2 as a parent via extends" do
      expect(slack["extends"]).to include("oauth2")
    end

    it "merges parent + own properties into a single resolved list" do
      names = slack["properties"].map { |p| p["name"] }
      # Parent OAuth2 fields (from CredentialTypeRegistry::OAUTH2)
      expect(names).to include("client_id", "client_secret", "scope",
                                "authorization_url", "access_token_url", "grant_type")
    end

    it "child overrides parent fields by re-declaring (hidden + default)" do
      authorization_url = slack["properties"].find { |p| p["name"] == "authorization_url" }
      expect(authorization_url["type"]).to    eq("hidden")
      expect(authorization_url["default"]).to eq("https://slack.com/oauth/v2/authorize")
    end

    it "client_secret keeps typeOptions.password = true (n8n password convention)" do
      client_secret = slack["properties"].find { |p| p["name"] == "client_secret" }
      expect(client_secret["typeOptions"]).to include("password" => true)
    end

    it "exposes connector capabilities under their own block (webhook_style, rate_limit, authorize_url)" do
      expect(slack["connector"]).to include(
        "base_url"      => "https://slack.com/api",
        "webhook_style" => "app_level",
        "authorize_url" => "/connectors/slack/authorize"
      )
      expect(slack["connector"]["rate_limit"]).to eq("limit" => 50, "per" => 60)
    end
  end

  describe "API-key connector (echo)" do
    let(:echo) do
      get "/connectors/types"
      response.parsed_body["types"].find { |t| t["name"] == "echo" }
    end

    it "has empty extends (no inheritance) and one declared api_key field" do
      expect(echo["extends"]).to eq([])
      api_key = echo["properties"].find { |p| p["name"] == "api_key" }
      expect(api_key).to include("type" => "string", "required" => true)
      expect(api_key["typeOptions"]).to include("password" => true)
    end

    it "puts webhook_style + rate_limit under the connector block" do
      expect(echo["connector"]["webhook_style"]).to eq("per_grant")
    end
  end

  it "returns types sorted by name for deterministic frontend rendering" do
    get "/connectors/types"
    names = response.parsed_body["types"].map { |t| t["name"] }
    expect(names).to eq(names.sort)
  end
end

RSpec.describe "GET /connectors/types/:name", type: :request do
  it "returns one type by name" do
    get "/connectors/types/echo"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["name"]).to eq("echo")
  end

  it "404s on unknown name" do
    get "/connectors/types/missing"
    expect(response).to have_http_status(:not_found)
  end
end
