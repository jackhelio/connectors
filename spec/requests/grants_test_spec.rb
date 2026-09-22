require "rails_helper"

RSpec.describe "POST /connectors/grants/:id/test", type: :request do
  let(:owner) { Owner.create!(name: "tester") }

  before do
    Connectors.configure do |c|
      c.owner_class_name       = "Owner"
      c.current_owner_resolver = ->(_ctrl) { owner }
    end
  end

  describe "Resend grant" do
    let!(:grant) do
      Connectors::Grant.create!(owner: owner, connector_key: "resend",
                                 credentials: { "api_key" => "re_valid" })
    end

    it "returns {status: OK} when the live endpoint responds 200" do
      stub_request(:get, "https://api.resend.com/domains")
        .with(headers: { "Authorization" => "Bearer re_valid" })
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                    body: { data: [] }.to_json)

      post "/connectors/grants/#{grant.id}/test"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("status" => "OK", "message" => "Connection successful")
    end

    it "returns {status: Error} with the upstream message on 401" do
      stub_request(:get, "https://api.resend.com/domains")
        .to_return(status: 401, headers: { "Content-Type" => "application/json" },
                    body: { name: "unauthorized", message: "Invalid API key" }.to_json)

      post "/connectors/grants/#{grant.id}/test"

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["status"]).to eq("Error")
      expect(response.parsed_body["message"]).to match(/401|invalid|authentication/i)
    end

    it "404s on an unknown grant id" do
      post "/connectors/grants/999999/test"
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /connectors/types — test_supported flag" do
    it "marks Resend as test_supported because it declared test_request" do
      get "/connectors/types/resend"
      expect(response.parsed_body.dig("connector", "test_supported")).to be true
    end

    it "marks Echo as NOT test_supported (no test_request)" do
      get "/connectors/types/echo"
      expect(response.parsed_body.dig("connector", "test_supported")).to be false
    end
  end
end
