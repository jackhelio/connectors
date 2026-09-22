require "rails_helper"

RSpec.describe "Webhook provider isolation", type: :request do
  let(:owner) { Owner.create!(name: "Webhook owner") }
  let(:grant) { Connectors::Grant.create!(owner: owner, connector_key: "slack", credentials: {}) }
  let!(:connector_class) do
    Class.new(Connectors::Connector) do
      connector key: :unsigned_hook, auth: :api_key, base_url: "https://hook.test"
    end
  end

  it "rejects an explicit grant belonging to another connector" do
    expect {
      post "/connectors/unsigned_hook/#{grant.id}/webhook", params: { id: "event" }, as: :json
    }.not_to change(Connectors::WebhookEvent, :count)
    expect(response).to have_http_status(:not_found)
  end

  it "rejects a resolver returning a grant from another connector" do
    allow(connector_class).to receive(:resolve_grant_from_webhook).and_return(grant)
    expect {
      post "/connectors/unsigned_hook/webhook", params: { id: "event" }, as: :json
    }.not_to change(Connectors::WebhookEvent, :count)
    expect(response).to have_http_status(:not_found)
  end

  it "preserves intentionally unsigned webhooks for the correct connector" do
    grant.update!(connector_key: "unsigned_hook")
    expect {
      post "/connectors/unsigned_hook/#{grant.id}/webhook", params: { id: "event" }, as: :json
    }.to change(Connectors::WebhookEvent, :count).by(1)
    expect(response).to have_http_status(:accepted)
  end
end
