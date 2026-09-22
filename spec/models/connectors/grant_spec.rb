require "rails_helper"

RSpec.describe Connectors::Grant, type: :model do
  before { Connectors::Registry.clear! }
  after  { Connectors::Registry.clear! }

  let!(:connector_class) do
    klass = Class.new(Connectors::Connector) do
      def self.name; "SpecGrantConnector"; end
      connector key: :spec_grant, auth: :api_key, base_url: "https://example.test"
    end
    klass
  end

  let(:owner) { Owner.create!(name: "test owner") }

  describe "schema" do
    it "has the expected columns" do
      expect(described_class.column_names).to include(
        "owner_type", "owner_id", "connector_key", "display_name",
        "credentials", "status", "expires_at", "last_used_at", "external_account_id"
      )
    end

    it "defines the status enum" do
      expect(described_class.statuses).to eq("active" => 0, "expired" => 1, "revoked" => 2, "errored" => 3)
    end
  end

  describe "credentials round-trip" do
    it "serializes a hash on write and reads it back on next load" do
      grant = described_class.create!(
        owner:         owner,
        connector_key: "spec_grant",
        credentials:   { "access_token" => "T" }
      )
      reloaded = described_class.find(grant.id)
      expect(reloaded.credentials).to eq("access_token" => "T")
    end

    it "stores the credentials column encrypted at rest (not plaintext)" do
      grant = described_class.create!(
        owner:         owner,
        connector_key: "spec_grant",
        credentials:   { "secret" => "plaintext_value" }
      )
      raw = described_class.connection.select_value(
        described_class.sanitize_sql_array(
          [ "SELECT credentials FROM connectors_grants WHERE id = ?", grant.id ]
        )
      )
      expect(raw).not_to include("plaintext_value")
    end
  end

  describe "#update_credentials!" do
    it "merges into the existing hash" do
      grant = described_class.create!(
        owner:         owner,
        connector_key: "spec_grant",
        credentials:   { "access_token" => "T1", "refresh_token" => "R" }
      )
      grant.update_credentials!(access_token: "T2")
      expect(grant.reload.credentials).to eq("access_token" => "T2", "refresh_token" => "R")
    end
  end

  describe "#connector" do
    it "returns a connector instance via the registry" do
      grant = described_class.new(connector_key: "spec_grant")
      expect(grant.connector).to be_a(connector_class)
      expect(grant.connector.grant).to eq(grant)
    end
  end
end
