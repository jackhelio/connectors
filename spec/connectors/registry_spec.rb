require "rails_helper"

RSpec.describe Connectors::Registry do
  let(:dummy_connector) do
    Class.new(Connectors::Connector) do
      def self.name; "DummyRegistryConnector"; end
    end
  end

  before { described_class.clear! }
  after  { described_class.clear! }

  describe ".register / .fetch" do
    it "stores and retrieves by symbol key" do
      described_class.register(:dummy, dummy_connector)
      expect(described_class.fetch(:dummy)).to eq(dummy_connector)
    end

    it "accepts string keys interchangeably with symbols" do
      described_class.register("dummy", dummy_connector)
      expect(described_class.fetch(:dummy)).to eq(dummy_connector)
      expect(described_class.fetch("dummy")).to eq(dummy_connector)
    end
  end

  describe ".fetch with unknown key" do
    it "raises Connectors::UnknownConnector with the known keys" do
      described_class.register(:known_one, dummy_connector)
      expect { described_class.fetch(:nope) }.to raise_error(Connectors::UnknownConnector, /known_one/)
    end
  end

  describe ".registered?" do
    it "returns true for known keys, false otherwise" do
      described_class.register(:dummy, dummy_connector)
      expect(described_class.registered?(:dummy)).to be true
      expect(described_class.registered?(:nope)).to be false
    end
  end
end
