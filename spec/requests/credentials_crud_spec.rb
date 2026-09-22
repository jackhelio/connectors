require "rails_helper"

RSpec.describe "Credentials CRUD", type: :request do
  let(:owner)       { Owner.create!(name: "alice") }
  let(:other_owner) { Owner.create!(name: "bob") }

  before do
    Connectors.configure do |c|
      c.owner_class_name       = "Owner"
      c.current_owner_resolver = ->(_ctrl) { owner }
    end
  end

  describe "POST /connectors/credentials" do
    it "creates a Grant via the paste-the-key flow" do
      expect {
        post "/connectors/credentials",
             params: { type: "resend", name: "Personal Resend", data: { api_key: "re_123" } }.to_json,
             headers: { "Content-Type" => "application/json" }
      }.to change(Connectors::Grant, :count).by(1)

      expect(response).to have_http_status(:created)
      body = response.parsed_body
      expect(body).to include(
        "type" => "resend",
        "name" => "Personal Resend",
        "status" => "active"
      )
      expect(body).not_to have_key("data")   # data omitted by default
    end

    it "404s on unknown connector type" do
      post "/connectors/credentials",
           params: { type: "made-up", data: { api_key: "x" } }.to_json,
           headers: { "Content-Type" => "application/json" }
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /connectors/credentials" do
    let!(:mine)   { Connectors::Grant.create!(owner: owner, connector_key: "resend", credentials: { "api_key" => "k1" }, display_name: "Mine") }
    let!(:theirs) { Connectors::Grant.create!(owner: other_owner, connector_key: "resend", credentials: { "api_key" => "k2" }, display_name: "Theirs") }

    it "scopes to the current owner" do
      get "/connectors/credentials"
      names = response.parsed_body["credentials"].map { |c| c["name"] }
      expect(names).to eq([ "Mine" ])
    end

    it "filters by type" do
      Connectors::Grant.create!(owner: owner, connector_key: "echo", credentials: { "api_key" => "x" }, display_name: "Echo cred")
      get "/connectors/credentials", params: { type: "resend" }
      types = response.parsed_body["credentials"].map { |c| c["type"] }.uniq
      expect(types).to eq([ "resend" ])
    end

    it "includes data only when include_data=true" do
      get "/connectors/credentials/#{mine.id}", params: { include_data: "true" }
      expect(response.parsed_body["data"]).to eq("api_key" => "k1")

      get "/connectors/credentials/#{mine.id}"
      expect(response.parsed_body).not_to have_key("data")
    end
  end

  describe "shared credential data" do
    %w[viewer editor].each do |role|
      [ false, true ].each do |managed|
        it "withholds #{managed ? 'managed' : 'stored'} secrets from a shared #{role} on show and index" do
          grant = Connectors::Grant.create!(owner: other_owner, connector_key: "resend",
            credentials: { "api_key" => "stored-secret" }, is_managed: managed, external_ref: ("vault/resend" if managed))
          Connectors::CredentialShare.create!(grant: grant, principal_type: "Owner", principal_id: owner.id, role: role)
          Connectors.configuration.secrets_resolver = ->(_) { { "api_key" => "vault-secret" } }

          get "/connectors/credentials/#{grant.id}", params: { include_data: true }
          expect(response).to have_http_status(:ok)
          expect(response.parsed_body).not_to have_key("data")
          expect(response.body).not_to include("stored-secret", "vault-secret")

          get "/connectors/credentials", params: { include_data: true }
          expect(response).to have_http_status(:ok)
          expect(response.parsed_body.fetch("credentials").map { |credential| credential.fetch("id") }).to include(grant.id)
          expect(response.parsed_body.fetch("credentials").flat_map(&:keys)).not_to include("data")
          expect(response.body).not_to include("stored-secret", "vault-secret")
        end
      end
    end

    it "preserves owner access to managed data and omits shared data in the same list" do
      mine = Connectors::Grant.create!(owner: owner, connector_key: "resend", credentials: {}, is_managed: true, external_ref: "vault/resend")
      shared = Connectors::Grant.create!(owner: other_owner, connector_key: "resend", credentials: { "api_key" => "shared-secret" })
      Connectors::CredentialShare.create!(grant: shared, principal_type: "Owner", principal_id: owner.id, role: "viewer")
      Connectors.configuration.secrets_resolver = ->(_) { { "api_key" => "owner-vault-secret" } }

      get "/connectors/credentials", params: { include_data: true }
      records = response.parsed_body.fetch("credentials").index_by { |credential| credential.fetch("id") }
      expect(records.fetch(mine.id).fetch("data")).to eq("api_key" => "owner-vault-secret")
      expect(records.fetch(shared.id)).not_to have_key("data")
    end
  end

  describe "PATCH /connectors/credentials/:id" do
    let!(:grant) { Connectors::Grant.create!(owner: owner, connector_key: "resend", credentials: { "api_key" => "old" }, display_name: "Old name") }

    it "updates the name" do
      patch "/connectors/credentials/#{grant.id}",
            params: { name: "Renamed" }.to_json,
            headers: { "Content-Type" => "application/json" }
      expect(grant.reload.display_name).to eq("Renamed")
    end

    it "merges data into existing credentials" do
      patch "/connectors/credentials/#{grant.id}",
            params: { data: { api_key: "fresh", extra: "value" } }.to_json,
            headers: { "Content-Type" => "application/json" }
      expect(grant.reload.credentials).to include("api_key" => "fresh", "extra" => "value")
    end
  end

  describe "DELETE /connectors/credentials/:id" do
    let!(:grant) { Connectors::Grant.create!(owner: owner, connector_key: "resend", credentials: { "api_key" => "x" }) }

    it "deletes the credential" do
      expect { delete "/connectors/credentials/#{grant.id}" }.to change(Connectors::Grant, :count).by(-1)
      expect(response).to have_http_status(:no_content)
    end
  end

  describe "POST /connectors/credentials/test (unsaved draft)" do
    it "runs the test against the live API without persisting" do
      stub_request(:get, "https://api.resend.com/domains")
        .with(headers: { "Authorization" => "Bearer re_draft" })
        .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: { data: [] }.to_json)

      expect {
        post "/connectors/credentials/test",
             params: { type: "resend", data: { api_key: "re_draft" } }.to_json,
             headers: { "Content-Type" => "application/json" }
      }.not_to change(Connectors::Grant, :count)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["status"]).to eq("OK")
    end
  end

  describe "GET /connectors/credentials/for-workflow" do
    let!(:g1) { Connectors::Grant.create!(owner: owner, connector_key: "resend", credentials: { "api_key" => "1" }, display_name: "Resend 1") }
    let!(:g2) { Connectors::Grant.create!(owner: owner, connector_key: "echo",   credentials: { "api_key" => "2" }, display_name: "Echo 1") }

    it "lists the current owner's credentials" do
      get "/connectors/credentials/for-workflow", params: { workflow_id: 1 }
      names = response.parsed_body["credentials"].map { |c| c["name"] }
      expect(names).to match_array([ "Resend 1", "Echo 1" ])
    end

    it "honors the type filter" do
      get "/connectors/credentials/for-workflow", params: { workflow_id: 1, type: "resend" }
      types = response.parsed_body["credentials"].map { |c| c["type"] }.uniq
      expect(types).to eq([ "resend" ])
    end
  end
end
