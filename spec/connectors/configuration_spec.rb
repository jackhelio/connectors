require "rails_helper"

RSpec.describe Connectors::Configuration do
  it "is yielded by Connectors.configure" do
    Connectors.configure do |c|
      c.owner_class_name = "Owner"
      c.host_base_url    = "https://example.test"
    end

    expect(Connectors.configuration.owner_class_name).to eq("Owner")
    expect(Connectors.configuration.host_base_url).to    eq("https://example.test")
  end

  it "normalizes oauth_credentials keys to symbols" do
    Connectors.configure do |c|
      c.oauth_credentials = {
        "slack"  => { client_id: "abc" },
        :linear  => { client_id: "xyz" }
      }
    end

    expect(Connectors.configuration.oauth_credentials_for(:slack)).to  include(client_id: "abc")
    expect(Connectors.configuration.oauth_credentials_for(:linear)).to include(client_id: "xyz")
  end

  it "raises when asked for credentials of an unconfigured connector" do
    expect { Connectors.configuration.oauth_credentials_for(:missing) }
      .to raise_error(Connectors::Error, /missing/)
  end

  it "resolves the owner via the configured resolver" do
    Connectors.configure { |c| c.current_owner_resolver = ->(ctrl) { ctrl.fake_owner } }
    controller = double(fake_owner: "the-owner")
    expect(Connectors.configuration.resolve_owner(controller)).to eq("the-owner")
  end

  it "raises when current_owner_resolver is not set" do
    expect { Connectors.configuration.resolve_owner(double) }
      .to raise_error(Connectors::Error, /current_owner_resolver/)
  end
end
