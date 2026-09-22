require "rails_helper"

# Base HTTP credential schemas provide inherited fields and, where
# supported, declarative authentication properties.
RSpec.describe "Generic HTTP auth credential types" do
  let(:reg) { Connectors::CredentialTypeRegistry }

  describe "Registry — six types live alongside :oauth2" do
    it "registers all six HTTP authentication schemas" do
      expect(reg.all.keys).to include(
        :oauth2,
        :http_basic_auth, :http_bearer_auth, :http_header_auth,
        :http_query_auth, :http_digest_auth, :http_custom_auth
      )
    end

    it "marks all six as generic_auth" do
      %i[http_basic_auth http_bearer_auth http_header_auth http_query_auth http_digest_auth http_custom_auth]
        .each { |name| expect(reg.fetch(name).generic_auth?).to be(true), "#{name} should be generic" }
    end
  end

  describe "Credential form fields" do
    it "http_basic_auth exposes user + password (password masked)" do
      props = reg.fetch(:http_basic_auth).resolved_fields.map(&:to_property)
      expect(props.map { |p| p[:name] }).to eq(%w[user password])
      expect(props.find { |p| p[:name] == "password" }[:typeOptions]).to include("password" => true)
    end

    it "http_bearer_auth exposes token + the custom-header notice" do
      names = reg.fetch(:http_bearer_auth).resolved_fields.map { |f| f.name.to_s }
      expect(names).to include("token", "_notice_custom_auth")
      notice = reg.fetch(:http_bearer_auth).resolved_fields.find { |f| f.name == :_notice_custom_auth }
      expect(notice.type).to eq("notice")
    end

    it "http_header_auth exposes name + value + multi-header notice" do
      names = reg.fetch(:http_header_auth).resolved_fields.map { |f| f.name.to_s }
      expect(names).to include("name", "value", "_notice_multi")
    end

    it "http_query_auth exposes name + value without a notice field" do
      names = reg.fetch(:http_query_auth).resolved_fields.map { |f| f.name.to_s }
      expect(names).to eq(%w[name value])
    end

    it "http_digest_auth exposes user + password (no authenticate block — runtime unsupported)" do
      schema = reg.fetch(:http_digest_auth)
      expect(schema.resolved_fields.map { |f| f.name.to_s }).to eq(%w[user password])
      expect(schema.resolved_authenticate).to be_nil
    end

    it "http_custom_auth exposes a single json field with redactJsonLeaves" do
      schema = reg.fetch(:http_custom_auth)
      json_field = schema.resolved_fields.find { |f| f.name == :json }
      expect(json_field.type).to eq("json")
      expect(json_field.required?).to be true
      expect(json_field.to_property[:typeOptions]).to include("redactJsonLeaves" => true)
    end
  end

  describe "Inherited authenticate block — runtime injection via extends" do
    # Each test connector extends one of the runtime-supported HTTP auth
    # types and confirms an outbound request gets the correct injection.
    let(:owner) { Owner.create!(name: "test owner") }

    around do |example|
      example.run
    ensure
      %i[p2_bearer p2_basic p2_header p2_query].each do |key|
        Connectors::Registry.instance_variable_get(:@store)&.delete(key)
      end
    end

    def make_connector(key, base_url, &block)
      klass = Class.new(Connectors::Connector, &block)
      klass.connector(key: key, auth: :api_key, base_url: base_url) unless klass.connector_key
      klass
    end

    it "extends :http_bearer_auth injects Authorization: Bearer <token>" do
      Class.new(Connectors::Connector) do
        connector key: :p2_bearer, auth: :api_key, base_url: "https://api.bearer.test"
        credentials { extends :http_bearer_auth }
      end

      grant = Connectors::Grant.create!(owner: owner, connector_key: "p2_bearer",
                                         credentials: { "token" => "tk_abc" })
      stub = stub_request(:get, "https://api.bearer.test/things")
              .with(headers: { "Authorization" => "Bearer tk_abc" })
              .to_return(status: 200, body: "{}")

      grant.connector.client.get("things")
      expect(stub).to have_been_requested
    end

    it "extends :http_basic_auth encodes username:password as Basic header" do
      Class.new(Connectors::Connector) do
        connector key: :p2_basic, auth: :api_key, base_url: "https://api.basic.test"
        credentials { extends :http_basic_auth }
      end

      grant = Connectors::Grant.create!(owner: owner, connector_key: "p2_basic",
                                         credentials: { "user" => "alice", "password" => "secret" })
      encoded = Base64.strict_encode64("alice:secret")
      stub = stub_request(:get, "https://api.basic.test/me")
              .with(headers: { "Authorization" => "Basic #{encoded}" })
              .to_return(status: 200, body: "{}")

      grant.connector.client.get("me")
      expect(stub).to have_been_requested
    end

    it "extends :http_header_auth injects the user-named header with the user-supplied value" do
      Class.new(Connectors::Connector) do
        connector key: :p2_header, auth: :api_key, base_url: "https://api.hdr.test"
        credentials { extends :http_header_auth }
      end

      grant = Connectors::Grant.create!(owner: owner, connector_key: "p2_header",
                                         credentials: { "name" => "X-Custom-Auth", "value" => "magic-123" })
      stub = stub_request(:get, "https://api.hdr.test/secret")
              .with(headers: { "X-Custom-Auth" => "magic-123" })
              .to_return(status: 200, body: "{}")

      grant.connector.client.get("secret")
      expect(stub).to have_been_requested
    end

    it "extends :http_query_auth appends the user-named query param" do
      Class.new(Connectors::Connector) do
        connector key: :p2_query, auth: :api_key, base_url: "https://api.q.test"
        credentials { extends :http_query_auth }
      end

      grant = Connectors::Grant.create!(owner: owner, connector_key: "p2_query",
                                         credentials: { "name" => "apiKey", "value" => "qv-9" })
      stub = stub_request(:get, "https://api.q.test/data")
              .with(query: { "apiKey" => "qv-9" })
              .to_return(status: 200, body: "{}")

      grant.connector.client.get("data")
      expect(stub).to have_been_requested
    end
  end

  describe "Child schema can override / extend inherited fields" do
    around do |example|
      example.run
    ensure
      Connectors::Registry.instance_variable_get(:@store)&.delete(:p2_bearer_extra)
    end

    it "lets a connector add fields beyond the inherited Bearer ones" do
      Class.new(Connectors::Connector) do
        connector key: :p2_bearer_extra, auth: :api_key, base_url: "https://api.x.test"
        credentials do
          extends :http_bearer_auth
          field :webhook_secret, type: "string", secret: true, display_name: "Webhook Secret"
        end
      end

      schema = Connectors::Registry.fetch(:p2_bearer_extra).credential_schema
      names  = schema.resolved_fields.map { |f| f.name.to_s }
      expect(names).to include("token", "webhook_secret")
    end
  end

  describe "GET /connectors/types — surfaces each Http*Auth in the catalog", type: :request do
    # The catalog lists connectors. Base credential fields appear in the
    # resolved properties of connectors that extend those schemas.
    it "extends :http_bearer_auth contributes token + notice to a connector's properties" do
      Class.new(Connectors::Connector) do
        connector key: :p2_bearer_catalog, auth: :api_key, base_url: "https://x.test",
                  display_name: "Bearer-extending demo"
        credentials { extends :http_bearer_auth }
      end

      get "/connectors/types/p2_bearer_catalog"
      props = response.parsed_body["properties"].map { |p| p["name"] }
      expect(props).to include("token", "_notice_custom_auth")
      expect(response.parsed_body["generic_auth"]).to be true
      expect(response.parsed_body["authenticate"]).to include(
        "type"       => "generic",
        "properties" => hash_including("headers" => { "Authorization" => "=Bearer {{$credentials.token}}" })
      )
    ensure
      Connectors::Registry.instance_variable_get(:@store)&.delete(:p2_bearer_catalog)
    end
  end
end
