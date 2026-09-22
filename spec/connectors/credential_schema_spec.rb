require "rails_helper"

RSpec.describe Connectors::CredentialSchema do
  describe ".build" do
    it "yields a schema and registers fields with n8n-shaped properties" do
      schema = described_class.build do
        field :access_token,  type: "string", required: true, secret: true
        field :refresh_token, type: "string", secret: true
        field :expires_at,    type: "number"
      end

      names = schema.fields.map(&:name)
      expect(names).to eq([ :access_token, :refresh_token, :expires_at ])
      expect(schema.required_fields.map(&:name)).to eq([ :access_token ])

      access_prop = schema.fields.find { |f| f.name == :access_token }.to_property
      expect(access_prop).to include(
        name:        "access_token",
        type:        "string",
        required:    true,
        typeOptions: { "password" => true }
      )
    end

    it "rejects unknown field types" do
      expect {
        described_class.build { field :x, type: "magic" }
      }.to raise_error(ArgumentError, /allowed/)
    end
  end

  describe "extends" do
    before do
      described_class::Field
      Connectors::CredentialTypeRegistry.register(:oauth2, Connectors::CredentialTypeRegistry::OAUTH2)
    end

    it "inlines inherited fields and lets children override by re-declaring the same name" do
      schema = described_class.build do
        extends :oauth2
        field :authorization_url, type: "hidden", default: "https://example.com/oauth/authorize"
      end

      auth_url = schema.resolved_fields.find { |f| f.name == :authorization_url }
      expect(auth_url.type).to    eq("hidden")
      expect(auth_url.default).to eq("https://example.com/oauth/authorize")

      # Parent fields still present (client_id, client_secret, etc.)
      expect(schema.resolved_fields.map(&:name)).to include(:client_id, :client_secret, :scope)
    end
  end

  describe "#validate!" do
    let(:schema) do
      described_class.build do
        field :access_token,  required: true
        field :refresh_token, required: true
      end
    end

    it "passes when all required fields are present" do
      expect { schema.validate!("access_token" => "a", "refresh_token" => "b") }.not_to raise_error
    end

    it "raises MissingCredentialFields listing missing required fields" do
      expect { schema.validate!("access_token" => "a") }
        .to raise_error(Connectors::MissingCredentialFields, /refresh_token/)
    end

    it "treats nil and empty values as missing" do
      expect { schema.validate!("access_token" => nil, "refresh_token" => "") }
        .to raise_error(Connectors::MissingCredentialFields, /access_token.*refresh_token/)
    end
  end
end
