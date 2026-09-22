require "rails_helper"

# Phase 10 — external secrets manager integration. n8n parity with the EE
# external-secrets module (`external-secrets.controller.ee.ts`): a grant
# carries an `external_ref` string + `is_managed` flag, and the host's
# `secrets_resolver` block returns the actual values at access time. The
# `__overwritten_properties` array (n8n: `interfaces.ts:382`) tells the
# editor which fields are vault-sourced and should be locked / hidden.
RSpec.describe "Phase 10 — external secrets manager" do
  let(:owner) { Owner.create!(name: "p10 owner") }

  let!(:connector_class) do
    Class.new(Connectors::Connector) do
      connector key: :p10_provider, auth: :api_key, base_url: "https://api.p10.test"
      credentials do
        field :api_key,       required: true, secret: true
        field :workspace_id,  type: "string"
      end
      authenticate type: :generic, properties: {
        headers: { "Authorization" => "=Bearer {{$credentials.api_key}}" }
      }
    end
  end

  after { Connectors::Registry.instance_variable_get(:@store)&.delete(:p10_provider) }

  describe "Configuration hooks" do
    it "managed_fields_for returns [] when no resolver is configured" do
      expect(Connectors.configuration.managed_fields_for(:p10_provider)).to eq([])
    end

    it "managed_fields_for delegates to the host callable, stringifying the result" do
      Connectors.configuration.secrets_managed_fields_for = ->(key) {
        { p10_provider: %i[api_key] }.fetch(key.to_sym, [])
      }
      expect(Connectors.configuration.managed_fields_for(:p10_provider)).to eq(%w[api_key])
    end

    it "resolve_secrets is a noop when no resolver is wired" do
      g = Connectors::Grant.create!(owner: owner, connector_key: "p10_provider",
                                     credentials: { "api_key" => "dev-key" }, is_managed: false)
      expect(Connectors.configuration.resolve_secrets(g)).to eq({})
    end
  end

  describe "Grant#credentials_hash with is_managed = true" do
    let(:grant) do
      Connectors::Grant.create!(owner: owner, connector_key: "p10_provider",
                                 credentials: { "api_key" => "fallback", "workspace_id" => "ws-1" },
                                 external_ref: "kv/p10/team-acme",
                                 is_managed: true)
    end

    it "merges values from the host's resolver, vault-supplied keys winning" do
      Connectors.configuration.secrets_resolver = ->(g) {
        expect(g.external_ref).to eq("kv/p10/team-acme")
        { "api_key" => "from-vault" }
      }

      hash = grant.credentials_hash
      expect(hash["api_key"]).to eq("from-vault")    # vault wins
      expect(hash["workspace_id"]).to eq("ws-1")          # DB value retained
    end

    it "stored_credentials_hash bypasses the resolver (for serializer + audit paths)" do
      Connectors.configuration.secrets_resolver = ->(_) { { "api_key" => "from-vault" } }
      expect(grant.stored_credentials_hash["api_key"]).to eq("fallback")
    end

    it "caches the resolver result per instance — single lookup per request" do
      calls = 0
      Connectors.configuration.secrets_resolver = ->(_) { calls += 1; { "api_key" => "vault-#{calls}" } }

      grant.credentials_hash
      grant.credentials_hash
      grant.credentials_hash
      expect(calls).to eq(1)
    end

    it "is_managed = false leaves the DB-only hash untouched" do
      Connectors.configuration.secrets_resolver = ->(_) { { "api_key" => "WRONG" } }
      grant.update!(is_managed: false)
      expect(grant.credentials_hash["api_key"]).to eq("fallback")
    end
  end

  describe "Outbound HTTP request injects the vault-resolved value" do
    let(:grant) do
      Connectors::Grant.create!(owner: owner, connector_key: "p10_provider",
                                 credentials: { "api_key" => "stale-db-value" },
                                 external_ref: "kv/p10/prod",
                                 is_managed: true)
    end

    it "AuthenticateGeneric middleware uses the vault-resolved value, not the DB value" do
      Connectors.configuration.secrets_resolver = ->(_) { { "api_key" => "vault-live" } }

      stub = stub_request(:get, "https://api.p10.test/me")
              .with(headers: { "Authorization" => "Bearer vault-live" })
              .to_return(status: 200, body: '{"ok":true}', headers: { "Content-Type" => "application/json" })

      grant.connector.client.get("me")
      expect(stub).to have_been_requested.once
    end
  end

  describe "GET /connectors/types/:name surfaces __overwritten_properties", type: :request do
    before do
      Connectors.configure do |c|
        c.owner_class_name       = "Owner"
        c.current_owner_resolver = ->(_) { owner }
        c.host_base_url          = "https://app.test"
        c.secrets_managed_fields_for = ->(key) { key.to_sym == :p10_provider ? %w[api_key] : [] }
      end
    end

    it "emits the field list when a host has declared managed fields for this connector" do
      get "/connectors/types/p10_provider"
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["__overwritten_properties"]).to eq(%w[api_key])
    end
  end

  describe "POST /connectors/credentials accepts external_ref + is_managed", type: :request do
    before do
      Connectors.configure do |c|
        c.owner_class_name       = "Owner"
        c.current_owner_resolver = ->(_) { owner }
        c.host_base_url          = "https://app.test"
        c.secrets_managed_fields_for = ->(_) { %w[api_key] }
      end
    end

    it "persists both flags and surfaces them on the response" do
      post "/connectors/credentials",
           params: { type: "p10_provider", name: "Prod Vault",
                      data: { workspace_id: "ws-prod" },
                      external_ref: "kv/p10/prod", is_managed: true }

      expect(response).to have_http_status(:created)
      body = response.parsed_body
      expect(body["is_managed"]).to    be true
      expect(body["external_ref"]).to  eq("kv/p10/prod")
      expect(body["__overwritten_properties"]).to eq(%w[api_key])

      grant = Connectors::Grant.find(body["id"])
      expect(grant.is_managed).to    be true
      expect(grant.external_ref).to  eq("kv/p10/prod")
    end

    it "GET serialization returns [] for __overwritten_properties when not managed" do
      g = Connectors::Grant.create!(owner: owner, connector_key: "p10_provider",
                                     credentials: { "api_key" => "k" }, is_managed: false)
      get "/connectors/credentials/#{g.id}"
      expect(response.parsed_body["__overwritten_properties"]).to eq([])
    end
  end
end
