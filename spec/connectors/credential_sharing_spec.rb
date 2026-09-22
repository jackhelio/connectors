require "rails_helper"

# Phase 9 — credential sharing / scoping. n8n parity with
# `enterprise/credentials.controller.ee.ts`. Engine stays host-agnostic:
# the host wires `principal_resolver` to expose whatever set of identities
# (User + Team + Project + ...) the requester has.
RSpec.describe "Phase 9 — credential sharing", type: :request do
  let!(:alice) { Owner.create!(name: "alice") }
  let!(:bob)   { Owner.create!(name: "bob") }
  let!(:carol) { Owner.create!(name: "carol") }

  # Reusable test connector so the CRUD endpoints have something to bind to.
  let!(:connector_class) do
    Class.new(Connectors::Connector) do
      connector key: :p9_test, auth: :api_key, base_url: "https://api.p9.test"
      credentials { field :api_key, required: true, secret: true }
    end
  end

  let!(:alice_grant) do
    Connectors::Grant.create!(owner: alice, connector_key: "p9_test",
                               credentials: { "api_key" => "alice-key" }, display_name: "Alice's API")
  end

  let!(:bob_grant) do
    Connectors::Grant.create!(owner: bob, connector_key: "p9_test",
                               credentials: { "api_key" => "bob-key" }, display_name: "Bob's API")
  end

  after { Connectors::Registry.instance_variable_get(:@store)&.delete(:p9_test) }

  # Identity headers — the dummy app's configuration block honors these so
  # we can flip "who's asking" without touching session middleware.
  def as(owner, extra_principals: [])
    Connectors.configure do |c|
      c.owner_class_name       = "Owner"
      c.current_owner_resolver = ->(_) { owner }
      c.host_base_url          = "https://app.test"
      c.principal_resolver     = ->(_) { [ [ "Owner", owner.id ], *extra_principals ] }
    end
  end

  describe "GET /connectors/credentials returns owned + shared-with-me" do
    it "by default, an owner sees only their own credentials" do
      as(alice)
      get "/connectors/credentials"
      ids = response.parsed_body["credentials"].map { |c| c["id"] }
      expect(ids).to     contain_exactly(alice_grant.id)
      expect(ids).not_to include(bob_grant.id)
    end

    it "shares appear in the requester's list with the shared-on role visible later" do
      Connectors::CredentialShare.create!(grant: bob_grant, principal_type: "Owner",
                                            principal_id: alice.id, role: "viewer")
      as(alice)

      get "/connectors/credentials"
      ids = response.parsed_body["credentials"].map { |c| c["id"] }
      expect(ids).to contain_exactly(alice_grant.id, bob_grant.id)
    end

    it "host-supplied team principals receive shares too" do
      team_id = SecureRandom.uuid
      Connectors::CredentialShare.create!(grant: bob_grant, principal_type: "Team",
                                            principal_id: team_id, role: "editor")
      as(alice, extra_principals: [ [ "Team", team_id ] ])

      get "/connectors/credentials"
      ids = response.parsed_body["credentials"].map { |c| c["id"] }
      expect(ids).to contain_exactly(alice_grant.id, bob_grant.id)
    end
  end

  describe "PUT /connectors/credentials/:id/share" do
    it "owner can share a credential with another principal" do
      as(alice)
      put "/connectors/credentials/#{alice_grant.id}/share",
          params: { principal_type: "Owner", principal_id: bob.id, role: "editor" }
      expect(response).to have_http_status(:ok)
      expect(Connectors::CredentialShare.count).to eq(1)
      expect(Connectors::CredentialShare.first).to have_attributes(
        grant_id: alice_grant.id, principal_type: "Owner",
        principal_id: bob.id, role: "editor"
      )
    end

    it "is idempotent — second share to the same principal updates the role" do
      as(alice)
      put "/connectors/credentials/#{alice_grant.id}/share",
          params: { principal_type: "Owner", principal_id: bob.id, role: "viewer" }
      put "/connectors/credentials/#{alice_grant.id}/share",
          params: { principal_type: "Owner", principal_id: bob.id, role: "editor" }
      expect(Connectors::CredentialShare.count).to eq(1)
      expect(Connectors::CredentialShare.first.role).to eq("editor")
    end

    it "non-owner viewer cannot share" do
      Connectors::CredentialShare.create!(grant: alice_grant, principal_type: "Owner",
                                            principal_id: bob.id, role: "viewer")
      as(bob)
      put "/connectors/credentials/#{alice_grant.id}/share",
          params: { principal_type: "Owner", principal_id: carol.id, role: "viewer" }
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "role gates on PATCH/DELETE" do
    it "viewer can read but not update" do
      Connectors::CredentialShare.create!(grant: alice_grant, principal_type: "Owner",
                                            principal_id: bob.id, role: "viewer")
      as(bob)

      get "/connectors/credentials/#{alice_grant.id}"
      expect(response).to have_http_status(:ok)

      patch "/connectors/credentials/#{alice_grant.id}", params: { name: "Renamed by viewer" }
      expect(response).to have_http_status(:unauthorized)
      expect(alice_grant.reload.display_name).to eq("Alice's API")
    end

    it "editor can update but not delete" do
      Connectors::CredentialShare.create!(grant: alice_grant, principal_type: "Owner",
                                            principal_id: bob.id, role: "editor")
      as(bob)

      patch "/connectors/credentials/#{alice_grant.id}", params: { name: "Renamed by editor" }
      expect(response).to have_http_status(:ok)
      expect(alice_grant.reload.display_name).to eq("Renamed by editor")

      delete "/connectors/credentials/#{alice_grant.id}"
      expect(response).to have_http_status(:unauthorized)
      expect { alice_grant.reload }.not_to raise_error
    end

    it "owner can do everything" do
      as(alice)
      delete "/connectors/credentials/#{alice_grant.id}"
      expect(response).to have_http_status(:no_content)
      expect { alice_grant.reload }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  describe "DELETE /connectors/credentials/:id/share unshares" do
    it "owner can revoke an existing share" do
      Connectors::CredentialShare.create!(grant: alice_grant, principal_type: "Owner",
                                            principal_id: bob.id, role: "viewer")
      as(alice)
      delete "/connectors/credentials/#{alice_grant.id}/share",
             params: { principal_type: "Owner", principal_id: bob.id }
      expect(response).to have_http_status(:no_content)
      expect(Connectors::CredentialShare.count).to eq(0)
    end
  end

  describe "PUT /connectors/credentials/:id/transfer moves ownership" do
    it "reassigns the owner of the grant" do
      as(alice)
      put "/connectors/credentials/#{alice_grant.id}/transfer",
          params: { owner_id: bob.id }
      expect(response).to have_http_status(:ok)
      expect(alice_grant.reload.owner_id).to eq(bob.id)
    end

    it "non-owner cannot transfer" do
      Connectors::CredentialShare.create!(grant: alice_grant, principal_type: "Owner",
                                            principal_id: bob.id, role: "editor")
      as(bob)
      put "/connectors/credentials/#{alice_grant.id}/transfer",
          params: { owner_id: carol.id }
      expect(response).to have_http_status(:unauthorized)
      expect(alice_grant.reload.owner_id).to eq(alice.id)
    end
  end

  describe "Shares cascade on credential deletion" do
    it "destroying a grant nukes its share rows" do
      Connectors::CredentialShare.create!(grant: alice_grant, principal_type: "Owner",
                                            principal_id: bob.id, role: "viewer")
      as(alice)
      delete "/connectors/credentials/#{alice_grant.id}"
      expect(Connectors::CredentialShare.count).to eq(0)
    end
  end
end
