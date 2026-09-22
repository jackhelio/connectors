require "rails_helper"

RSpec.describe Connectors::Connector do
  before { Connectors::Registry.clear! }
  after  { Connectors::Registry.clear! }

  let(:connector_class) do
    Class.new(described_class) do
      def self.name; "SpecConnector"; end
      connector key: :spec, auth: :api_key, base_url: "https://example.test"
      credentials do
        field :api_key, required: true, secret: true
      end
      api_key_in :header, name: "X-Spec-Token"
      rate_limit 5, per: 60
    end
  end

  it "registers itself on the registry under the declared key" do
    connector_class
    expect(Connectors::Registry.fetch(:spec)).to eq(connector_class)
  end

  it "exposes the declared metadata" do
    expect(connector_class.connector_key).to eq(:spec)
    expect(connector_class.base_url).to     eq("https://example.test")
    expect(connector_class.auth_scheme).to  eq(Connectors::Auth::Scheme::ApiKey)
    expect(connector_class.api_key_options).to eq(location: :header, name: "X-Spec-Token", prefix: nil)
    expect(connector_class.rate_limit_config).to eq(limit: 5, per: 60)
    expect(connector_class.credential_schema.required_fields.map(&:name)).to eq([ :api_key ])
  end

  it "raises NotImplementedError if #refresh! is called on the base implementation" do
    instance = connector_class.new(double(id: 1))
    expect { instance.refresh! }.to raise_error(NotImplementedError, /SpecConnector/)
  end
end
