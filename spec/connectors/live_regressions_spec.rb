require "rails_helper"

# Regressions found during the Step 4 end-to-end smoke against flow-api.
# Two bugs surfaced when actually hitting the running server with curl:
#
# 1. `POST /credentials/:id/revoke` returned 500 (unhandled Connectors::Error)
#    when the connector hadn't declared `revoke_token_url` — should be 401.
# 2. `DELETE /credentials/:id` returned 500 (PG::ForeignKeyViolation) when the
#    grant had any `WebhookEvent` rows pointing at it — should cascade-delete
#    them.
RSpec.describe "Live-test regressions" do
  let(:owner) { Owner.create!(name: "regression owner") }

  let!(:connector_class) do
    Class.new(Connectors::Connector) do
      connector key: :live_reg, auth: :api_key, base_url: "https://api.live.test"
      credentials { field :api_key, required: true, secret: true }
    end
  end

  after { Connectors::Registry.instance_variable_get(:@store)&.delete(:live_reg) }

  describe "POST /connectors/credentials/:id/revoke without revoke_token_url", type: :request do
    let(:grant) do
      Connectors::Grant.create!(owner: owner, connector_key: "live_reg",
                                 credentials: { "api_key" => "k" })
    end

    it "returns 401 with the configuration error in the body (not a 500)" do
      Connectors.configure do |c|
        c.owner_class_name       = "Owner"
        c.current_owner_resolver = ->(_) { owner }
        c.host_base_url          = "https://app.test"
      end

      post "/connectors/credentials/#{grant.id}/revoke"
      expect(response).to            have_http_status(:unauthorized)
      expect(response.body).to       include("no revoke_token_url")
      expect(grant.reload.status).to eq("active")
    end
  end

  describe "DELETE /connectors/credentials/:id with associated webhook events" do
    it "cascade-deletes WebhookEvent rows so the FK constraint doesn't fire" do
      grant = Connectors::Grant.create!(owner: owner, connector_key: "live_reg",
                                         credentials: { "api_key" => "k" })
      Connectors::WebhookEvent.create!(grant: grant, connector_key: "live_reg",
                                        payload: { "type" => "ping" },
                                        received_at: Time.current)

      expect { grant.destroy! }.to change(Connectors::WebhookEvent, :count).by(-1)
    end
  end
end
