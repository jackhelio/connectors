require "rails_helper"

RSpec.describe Gmail::Api do
  let(:owner) { Owner.create!(name: "api owner") }
  let(:grant) do
    Connectors::Grant.create!(owner: owner, connector_key: "gmail",
                               credentials: { "access_token" => "ya29.x" })
  end
  let(:client) { grant.connector.client }

  describe ".request error translation" do
    it "404 → 'Message not found'" do
      stub_request(:get, "https://gmail.googleapis.com/gmail/v1/users/me/messages/bad")
        .to_return(status: 404, headers: { "Content-Type" => "application/json" },
                   body: { error: { code: 404, message: "Requested entity was not found." } }.to_json)
      expect {
        described_class.request(client, :get, "users/me/messages/bad", resource: "message")
      }.to raise_error(Connectors::ApiError, "Message not found")
    end

    it "404 on a label resource → 'Label not found'" do
      stub_request(:get, "https://gmail.googleapis.com/gmail/v1/users/me/labels/x")
        .to_return(status: 404, body: { error: { code: 404, message: "Not Found" } }.to_json,
                   headers: { "Content-Type" => "application/json" })
      expect {
        described_class.request(client, :get, "users/me/labels/x", resource: "label")
      }.to raise_error(Connectors::ApiError, "Label not found")
    end

    it "409 on a label create → 'Label name already exists'" do
      stub_request(:post, "https://gmail.googleapis.com/gmail/v1/users/me/labels")
        .to_return(status: 409, body: { error: { code: 409, message: "Label name exists" } }.to_json,
                   headers: { "Content-Type" => "application/json" })
      expect {
        described_class.request(client, :post, "users/me/labels", body: { name: "x" }, resource: "label")
      }.to raise_error(Connectors::ApiError, "Label name already exists")
    end

    it "400 with 'Invalid id value' → friendly resource-specific message" do
      stub_request(:get, "https://gmail.googleapis.com/gmail/v1/users/me/messages/zzz")
        .to_return(status: 400, body: { error: { code: 400, message: "Invalid id value" } }.to_json,
                   headers: { "Content-Type" => "application/json" })
      expect {
        described_class.request(client, :get, "users/me/messages/zzz", resource: "message")
      }.to raise_error(Connectors::ApiError, /Invalid message ID/)
    end

    it "401 → Connectors::AuthenticationFailed (so auto-refresh middleware kicks in)" do
      stub_request(:get, "https://gmail.googleapis.com/gmail/v1/users/me/profile")
        .to_return(status: 401, body: { error: { code: 401, message: "Invalid credentials" } }.to_json,
                   headers: { "Content-Type" => "application/json" })
      expect {
        described_class.request(client, :get, "users/me/profile", resource: "profile")
      }.to raise_error(Connectors::AuthenticationFailed)
    end

    it "429 → Connectors::RateLimited" do
      stub_request(:get, "https://gmail.googleapis.com/gmail/v1/users/me/messages")
        .to_return(status: 429, body: { error: { code: 429, message: "Rate exceeded" } }.to_json,
                   headers: { "Content-Type" => "application/json" })
      expect {
        described_class.request(client, :get, "users/me/messages", resource: "message")
      }.to raise_error(Connectors::RateLimited)
    end

    it "non-matched status passes the original error through" do
      stub_request(:get, "https://gmail.googleapis.com/gmail/v1/users/me/messages")
        .to_return(status: 500, body: { error: { code: 500, message: "boom" } }.to_json,
                   headers: { "Content-Type" => "application/json" })
      expect {
        described_class.request(client, :get, "users/me/messages", resource: "message")
      }.to raise_error(Connectors::ApiError)
    end
  end

  describe ".request_all (auto-paginate)" do
    it "walks every nextPageToken until exhausted and flattens by property_name" do
      stub_request(:get, /messages\?.*pageToken=p2/)
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { messages: [ { id: "m3" } ] }.to_json)
      stub_request(:get, /messages\?.*pageToken=p1/)
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { messages: [ { id: "m2" } ], nextPageToken: "p2" }.to_json)
      stub_request(:get, "https://gmail.googleapis.com/gmail/v1/users/me/messages?maxResults=100")
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { messages: [ { id: "m1" } ], nextPageToken: "p1" }.to_json)

      result = described_class.request_all(
        client, "messages", :get, "users/me/messages", resource: "message"
      )
      expect(result.map { |m| m["id"] }).to eq(%w[m1 m2 m3])
    end

    it "returns [] when the first page is empty" do
      stub_request(:get, /messages/)
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { messages: [] }.to_json)
      expect(described_class.request_all(client, "messages", :get, "users/me/messages", resource: "message")).to eq([])
    end
  end
end
