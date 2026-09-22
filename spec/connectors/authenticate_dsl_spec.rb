require "rails_helper"

# Declarative authentication, credential template resolution and middleware.
RSpec.describe "Declarative `authenticate` DSL" do
  describe Connectors::AuthInjection, ".resolve" do
    let(:credentials) { { "api_key" => "secret-key", "tenant" => "acme" } }

    it "substitutes $credentials.<field> in =-prefixed templates" do
      input = {
        headers: { "Authorization" => "=Bearer {{$credentials.api_key}}" },
        qs:      { "tenant"        => "={{$credentials.tenant}}" }
      }
      result = described_class.resolve(input, credentials)
      expect(result[:headers]).to eq("Authorization" => "Bearer secret-key")
      expect(result[:qs]).to      eq("tenant" => "acme")
    end

    it "passes plain (non-=-prefixed) strings through verbatim" do
      input  = { headers: { "X-Static" => "literal-value" } }
      result = described_class.resolve(input, credentials)
      expect(result[:headers]).to eq("X-Static" => "literal-value")
    end

    it "supports bracket access ($credentials[\"field\"])" do
      result = described_class.resolve({ headers: { "X-Tenant" => "=tenant-{{$credentials[\"tenant\"]}}" } }, credentials)
      expect(result[:headers]).to eq("X-Tenant" => "tenant-acme")
    end

    it "resolves missing fields to empty string" do
      result = described_class.resolve({ headers: { "X-Missing" => "=val-{{$credentials.absent}}" } }, credentials)
      expect(result[:headers]).to eq("X-Missing" => "val-")
    end

    it "preserves unknown expressions verbatim (no silent header erasure)" do
      result = described_class.resolve({ headers: { "X-Weird" => "={{garbage()}}" } }, credentials)
      expect(result[:headers]["X-Weird"]).to include("{{garbage()}}")
    end

    it "leaves non-string leaves (numbers, booleans) untouched" do
      result = described_class.resolve({ qs: { "ttl" => 30, "verbose" => true } }, credentials)
      expect(result[:qs]).to eq("ttl" => 30, "verbose" => true)
    end
  end

  describe "Resend rewired to declarative `authenticate`" do
    let(:owner) { Owner.create!(name: "test owner") }
    let(:grant) do
      Connectors::Grant.create!(
        owner:         owner,
        connector_key: "resend",
        credentials:   { "api_key" => "re_phase1" }
      )
    end

    it "injects `Authorization: Bearer <api_key>` on outgoing requests" do
      stub = stub_request(:get, "https://api.resend.com/domains")
              .with(headers: { "Authorization" => "Bearer re_phase1" })
              .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                         body: { data: [] }.to_json)

      grant.connector.client.get("domains")
      expect(stub).to have_been_requested
    end

    it "still passes the existing `test_request` path through the declarative middleware" do
      stub_request(:get, "https://api.resend.com/domains")
        .with(headers: { "Authorization" => "Bearer re_phase1" })
        .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: { data: [] }.to_json)

      result = Connectors::CredentialTester.run(grant)
      expect(result[:status]).to eq("OK")
    end

    it "send_email still works against the declarative auth chain" do
      stub_request(:post, "https://api.resend.com/emails")
        .with(headers: { "Authorization" => "Bearer re_phase1" })
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { id: "abc-123" }.to_json)

      result = grant.connector.send_email(
        from: "x@example.com", to: "y@example.com", subject: "Hi", html: "<p>Hello</p>"
      )
      expect(result).to eq("id" => "abc-123")
    end
  end

  describe "GET /connectors/types — surfaces the authenticate block" do
    it "exposes Resend's authenticate config so the frontend sees the injection contract", type: :request do
      get "/connectors/types/resend"
      expect(response).to have_http_status(:ok)
      authenticate = response.parsed_body["authenticate"]
      expect(authenticate).to include(
        "type"       => "generic",
        "properties" => hash_including(
          "headers" => hash_including("Authorization" => "=Bearer {{$credentials.api_key}}")
        )
      )
    end
  end

  describe "Legacy `api_key_in` fallback still works for connectors that haven't migrated" do
    # The dummy `EchoConnector` still uses imperative `api_key_in :header,
    # name: "X-Echo-Token"`. Confirm it works alongside the new path.
    let(:owner) { Owner.create!(name: "legacy owner") }
    let(:grant) do
      Connectors::Grant.create!(owner: owner, connector_key: "echo",
                                 credentials: { "api_key" => "ek-legacy" })
    end

    it "still attaches the API key via the imperative Auth::Scheme middleware" do
      stub = stub_request(:get, "https://httpbin.org/get")
              .with(headers: { "X-Echo-Token" => "ek-legacy" })
              .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: "{}")

      grant.connector.ping
      expect(stub).to have_been_requested
    end
  end

  describe "Basic auth shortcut (`auth: { username:, password: }`)" do
    # An anonymous connector exercises the Basic authentication shortcut.
    let(:owner) { Owner.create!(name: "basic owner") }
    let(:test_connector_class) do
      Class.new(Connectors::Connector) do
        connector key: :phase1_basic_test, auth: :api_key, base_url: "https://api.example.test"
        credentials do
          field :username, type: "string", required: true
          field :password, type: "string", required: true, secret: true
        end
        authenticate type: :generic, properties: {
          auth: { username: "={{$credentials.username}}", password: "={{$credentials.password}}" }
        }
      end
    end

    let(:grant) do
      test_connector_class
      Connectors::Grant.create!(owner: owner, connector_key: "phase1_basic_test",
                                 credentials: { "username" => "alice", "password" => "wonderland" })
    end

    after do
      Connectors::Registry.instance_variable_get(:@store)&.delete(:phase1_basic_test)
    end

    it "encodes username/password as the standard HTTP Basic header" do
      stub = stub_request(:get, "https://api.example.test/secret")
              .with(headers: { "Authorization" => "Basic #{Base64.strict_encode64('alice:wonderland')}" })
              .to_return(status: 200, body: "{}")

      grant.connector.client.get("secret")
      expect(stub).to have_been_requested
    end
  end
end
