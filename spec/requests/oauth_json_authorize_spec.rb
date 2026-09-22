require "rails_helper"

RSpec.describe "OAuth — JSON authorize for popup-based connect", type: :request do
  let(:owner) { Owner.create!(name: "popup user") }

  before do
    Connectors.configure do |c|
      c.owner_class_name       = "Owner"
      c.current_owner_resolver = ->(_ctrl) { owner }
      c.host_base_url          = "https://app.test"
      c.oauth_credentials      = {
        slack: { client_id: "client-abc", client_secret: "secret-xyz" }
      }
    end
  end

  describe "GET /connectors/slack/authorize.json" do
    it "returns the authorize URL as JSON instead of redirecting" do
      get "/connectors/slack/authorize.json"

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["connector_key"]).to eq("slack")
      expect(body["authorize_url"]).to start_with("https://slack.com/oauth/v2/authorize?")

      params = URI.decode_www_form(URI.parse(body["authorize_url"]).query).to_h
      expect(params["client_id"]).to    eq("client-abc")
      expect(params["redirect_uri"]).to eq("https://app.test/connectors/slack/callback")
      expect(params["state"]).to        be_present
    end

    it "uses the connector's declared default scope when none is supplied" do
      get "/connectors/slack/authorize.json"
      params = URI.decode_www_form(URI.parse(response.parsed_body["authorize_url"]).query).to_h
      # Slack connector declares chat:write,channels:read,users:read — see spec/connectors/slack/connector_spec.rb
      expect(params["scope"]).to be_present
    end

    it "honors a `?scope=` override so the host can ask for a wider / narrower set" do
      override = "openid email profile"
      get "/connectors/slack/authorize.json", params: { scope: override }
      params = URI.decode_www_form(URI.parse(response.parsed_body["authorize_url"]).query).to_h
      expect(params["scope"]).to eq(override)
    end
  end

  describe "GET /connectors/types — exposes redirect_uri on OAuth connectors" do
    it "returns the canonical callback URL the admin pastes into the provider console" do
      get "/connectors/types/slack"
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("connector", "redirect_uri"))
        .to eq("https://app.test/connectors/slack/callback")
      expect(response.parsed_body.dig("connector", "authorize_json_url"))
        .to eq("/connectors/slack/authorize.json")
    end
  end
end
