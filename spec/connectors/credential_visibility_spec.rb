require "rails_helper"

# Phase 5 — credential visibility flags. Three orthogonal switches on
# `ICredentialType` (n8n source: packages/workflow/src/interfaces.ts:379-381):
#   - genericAuth:     boolean              — eligible for the HTTP-Request node picker
#   - supportedNodes:  string[]             — explicit allowlist; empty = unrestricted
#   - httpRequestNode: { name, docsUrl, ... } — picker label/docs/baseUrl hint
RSpec.describe "Phase 5 — credential visibility flags" do
  let(:owner) { Owner.create!(name: "p5 owner") }

  # Connector A — restricted to two specific node types
  let!(:restricted) do
    Class.new(Connectors::Connector) do
      connector key: :p5_restricted, auth: :api_key, base_url: "https://api.r.test"
      credentials { field :api_key, required: true, secret: true }
      authenticate type: :generic, properties: { headers: { "X-Key" => "={{$credentials.api_key}}" } }
      supported_nodes :p5_restricted_send, :p5_restricted_get
    end
  end

  # Connector B — generic-auth opt-in + http_request_node metadata
  let!(:generic) do
    Class.new(Connectors::Connector) do
      connector key: :p5_generic, auth: :api_key, base_url: "https://api.g.test"
      credentials { field :token, required: true, secret: true }
      authenticate type: :generic, properties: { headers: { "Authorization" => "=Bearer {{$credentials.token}}" } }
      generic_auth!
      http_request_node name: "Generic Test API",
                        docs_url: "https://example.test/docs",
                        api_base_url: "https://api.g.test"
    end
  end

  # Connector C — unrestricted, no flags (the default case)
  let!(:plain) do
    Class.new(Connectors::Connector) do
      connector key: :p5_plain, auth: :api_key, base_url: "https://api.p.test"
      credentials { field :api_key, required: true, secret: true }
    end
  end

  after do
    %i[p5_restricted p5_generic p5_plain].each do |key|
      Connectors::Registry.instance_variable_get(:@store)&.delete(key)
    end
  end

  describe "DSL readback" do
    it "stores supported_nodes as symbols and returns [] for unrestricted connectors" do
      expect(restricted.supported_nodes).to eq(%i[p5_restricted_send p5_restricted_get])
      expect(plain.supported_nodes).to eq([])
    end

    it "stores http_request_node with the n8n key shape (camelCase)" do
      expect(generic.http_request_node).to eq(
        "name"       => "Generic Test API",
        "docsUrl"    => "https://example.test/docs",
        "apiBaseUrl" => "https://api.g.test",
        "hidden"     => false
      )
      expect(plain.http_request_node).to be_nil
    end

    it "requires one of apiBaseUrl or apiBaseUrlPlaceholder (matches the n8n union)" do
      expect {
        Class.new(Connectors::Connector) do
          connector key: :p5_invalid, auth: :api_key, base_url: "https://x.test"
          credentials { field :api_key, required: true }
          http_request_node name: "X", docs_url: "https://x.test/docs"
        end
      }.to raise_error(ArgumentError, /api_base_url or api_base_url_placeholder/)
    end

    it "generic_auth! works at the connector level even when no extends is declared" do
      expect(generic.generic_auth?).to be true
      expect(plain.generic_auth?).to   be false
    end

    it "inherits generic_auth? from extended schemas (Phase 2 base types)" do
      bearer = Class.new(Connectors::Connector) do
        connector key: :p5_bearer, auth: :api_key, base_url: "https://b.test"
        credentials { extends :http_bearer_auth }
      end
      expect(bearer.generic_auth?).to be true
      Connectors::Registry.instance_variable_get(:@store)&.delete(:p5_bearer)
    end
  end

  describe "Connector#supports_node?" do
    it "returns true for any node type when supported_nodes is unset" do
      expect(plain.supports_node?(:anything)).to be true
    end

    it "returns true only for whitelisted node types when supported_nodes is set" do
      expect(restricted.supports_node?(:p5_restricted_send)).to  be true
      expect(restricted.supports_node?(:p5_restricted_get)).to   be true
      expect(restricted.supports_node?(:p5_other)).to            be false
    end

    it "lets the generic HTTP-Request node use any generic_auth credential" do
      expect(generic.supports_node?(:http_request)).to be true
    end

    it "still blocks the HTTP-Request node from credentials that aren't generic_auth" do
      expect(restricted.supports_node?(:http_request)).to be false
    end
  end

  describe "Connectors::PermissionCheck" do
    let(:restricted_grant) do
      Connectors::Grant.create!(owner: owner, connector_key: "p5_restricted",
                                 credentials: { "api_key" => "k1" })
    end

    it "permits! returns true for an allowlisted node" do
      expect(Connectors::PermissionCheck.permit!(restricted_grant, node_type: :p5_restricted_send)).to be true
    end

    it "permits! raises CredentialNotPermitted with the restriction reason" do
      expect {
        Connectors::PermissionCheck.permit!(restricted_grant, node_type: :forbidden_node)
      }.to raise_error(Connectors::CredentialNotPermitted, /supported_nodes/)
    end

    it "permits? is the non-raising variant" do
      expect(Connectors::PermissionCheck.permits?(restricted_grant, node_type: :p5_restricted_send)).to be true
      expect(Connectors::PermissionCheck.permits?(restricted_grant, node_type: :foo)).to be false
    end
  end

  describe "GET /connectors/types/:name surface", type: :request do
    before do
      Connectors.configure do |c|
        c.owner_class_name       = "Owner"
        c.current_owner_resolver = ->(_) { owner }
        c.host_base_url          = "https://app.test"
      end
    end

    it "emits generic_auth + supported_nodes + http_request_node for restricted connector" do
      get "/connectors/types/p5_restricted"
      body = response.parsed_body
      expect(response).to have_http_status(:ok)
      expect(body["generic_auth"]).to        be false
      expect(body["supported_nodes"]).to     eq(%w[p5_restricted_send p5_restricted_get])
      expect(body["http_request_node"]).to   be_nil
    end

    it "emits the populated http_request_node block for the generic connector" do
      get "/connectors/types/p5_generic"
      body = response.parsed_body
      expect(body["generic_auth"]).to       be true
      expect(body["supported_nodes"]).to    eq([])
      expect(body["http_request_node"]).to  eq(
        "name"       => "Generic Test API",
        "docsUrl"    => "https://example.test/docs",
        "apiBaseUrl" => "https://api.g.test",
        "hidden"     => false
      )
    end

    it "emits sane defaults for the plain unrestricted connector" do
      get "/connectors/types/p5_plain"
      body = response.parsed_body
      expect(body["generic_auth"]).to       be false
      expect(body["supported_nodes"]).to    eq([])
      expect(body["http_request_node"]).to  be_nil
    end
  end
end
