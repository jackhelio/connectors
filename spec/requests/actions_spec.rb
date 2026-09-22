require "rails_helper"

RSpec.describe "Actions endpoint", type: :request do
  let(:owner) { Owner.create!(name: "actions http") }
  let(:grant) do
    Connectors::Grant.create!(
      owner:         owner,
      connector_key: "resend",
      credentials:   { "api_key" => "re_test" }
    )
  end

  before do
    Connectors.configure do |c|
      c.owner_class_name       = "Owner"
      c.current_owner_resolver = ->(_ctrl) { owner }
    end
  end

  describe "GET /connectors/credentials/:id/actions" do
    it "returns the action manifest for the grant's connector" do
      get "/connectors/credentials/#{grant.id}/actions"
      expect(response).to have_http_status(:ok)

      actions = response.parsed_body["actions"]
      send_email = actions.find { |a| a["name"] == "send_email" }
      expect(send_email).to be_a(Hash)
      expect(send_email["display_name"]).to eq("Send Email")
      required = send_email["properties"].select { |p| p["required"] }.map { |p| p["name"] }
      expect(required).to match_array([ "from", "to", "subject" ])
      expect(send_email["output"].first).to include("name" => "id", "type" => "string")
    end
  end

  describe "POST /connectors/credentials/:id/actions/:name" do
    it "returns a forbidden envelope for provider permission denial" do
      stub_request(:post, "https://api.resend.com/emails").to_return(status: 403, body: "forbidden")
      post "/connectors/credentials/#{grant.id}/actions/send_email",
        params: { data: { from: "a@x.com", to: "b@x.com", subject: "s", text: "body" } }, as: :json
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig("error", "type")).to eq("forbidden")
    end

    it "dispatches to the connector method and returns its payload" do
      stub_request(:post, "https://api.resend.com/emails")
        .with(headers: { "Authorization" => "Bearer re_test" },
              body: hash_including("from"    => "x@example.com",
                                   "to"      => [ "alice@example.com" ],
                                   "subject" => "Hi",
                                   "html"    => "<p>Hi</p>"))
        .to_return(status: 200,
                   headers: { "Content-Type" => "application/json" },
                   body: { id: "msg_abc" }.to_json)

      post "/connectors/credentials/#{grant.id}/actions/send_email",
           params: { data: {
             from: "x@example.com", to: "alice@example.com",
             subject: "Hi", html: "<p>Hi</p>"
           } }.to_json,
           headers: { "Content-Type" => "application/json" }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include(
        "status" => "ok",
        "action" => "send_email",
        "data"   => { "id" => "msg_abc" }
      )
    end

    it "rejects a revoked grant before contacting the provider" do
      grant.update!(status: :revoked)
      endpoint = stub_request(:post, "https://api.resend.com/emails").to_return(status: 200)
      post "/connectors/credentials/#{grant.id}/actions/send_email",
        params: { data: { from: "a@example.test", to: "b@example.test", subject: "s", text: "body" } }, as: :json
      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body.dig("error", "type")).to eq("authentication_failed")
      expect(endpoint).not_to have_been_requested
    end

    it "422s when required params are missing" do
      post "/connectors/credentials/#{grant.id}/actions/send_email",
           params: { data: { subject: "Hi" } }.to_json,
           headers: { "Content-Type" => "application/json" }

      expect(response).to have_http_status(:unprocessable_content)
      body = response.parsed_body
      expect(body["status"]).to eq("error")
      expect(body.dig("error", "type")).to eq("invalid_params")
      expect(body.dig("error", "missing")).to match_array([ "from", "to" ])
    end

    it "404s when the action isn't declared on the connector" do
      post "/connectors/credentials/#{grant.id}/actions/does_not_exist",
           params: { data: {} }.to_json,
           headers: { "Content-Type" => "application/json" }
      expect(response).to have_http_status(:not_found)
    end

    it "404s for grants the requester does not own / share" do
      stranger = Owner.create!(name: "stranger")
      stranger_grant = Connectors::Grant.create!(
        owner: stranger, connector_key: "resend",
        credentials: { "api_key" => "re_other" }
      )

      post "/connectors/credentials/#{stranger_grant.id}/actions/send_email",
           params: { data: { from: "a", to: "b", subject: "c", html: "d" } }.to_json,
           headers: { "Content-Type" => "application/json" }

      expect(response).to have_http_status(:not_found)
    end

    it "promotes Resend's upstream error into a bad_gateway with the api_error envelope" do
      stub_request(:post, "https://api.resend.com/emails").to_return(
        status: 422,
        headers: { "Content-Type" => "application/json" },
        body: { name: "validation_error", message: "Invalid `to` field", statusCode: 422 }.to_json
      )

      post "/connectors/credentials/#{grant.id}/actions/send_email",
           params: { data: { from: "a@x.com", to: "bogus", subject: "s", html: "h" } }.to_json,
           headers: { "Content-Type" => "application/json" }

      expect(response).to have_http_status(:bad_gateway)
      body = response.parsed_body
      expect(body["status"]).to eq("error")
      expect(body.dig("error", "type")).to eq("api_error")
      expect(body.dig("error", "status")).to eq(422)
    end
  end

  describe "/connectors/types/resend" do
    it "exposes the action manifest in the catalog" do
      get "/connectors/types/resend"
      expect(response).to have_http_status(:ok)
      actions = response.parsed_body["actions"]
      expect(actions.map { |a| a["name"] }).to include("send_email")
    end
  end
end
