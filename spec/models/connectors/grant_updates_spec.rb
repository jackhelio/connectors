require "rails_helper"

RSpec.describe Connectors::Grant, "atomic updates" do
  let(:owner) { Owner.create!(name: "Update owner") }
  let(:grant) { described_class.create!(owner: owner, connector_key: "slack", credentials: { "access_token" => "old" }) }

  it "merges credential patches from independently loaded instances without losing newer fields" do
    stale = described_class.find(grant.id)
    grant.update_credentials!(refresh_token: "rotated")
    stale.update_credentials!(access_token: "new")
    expect(grant.reload.credentials_hash).to include("refresh_token" => "rotated", "access_token" => "new")
  end

  it "invalidates resolved credentials on reload" do
    expect(grant.credentials_hash["access_token"]).to eq("old")
    described_class.find(grant.id).update_credentials!(access_token: "new")
    expect(grant.reload.credentials_hash["access_token"]).to eq("new")
  end

  it "synchronizes expiry metadata, including explicit removal" do
    expiry = 1.hour.from_now.to_i
    grant.update_credentials!(expires_at: expiry)
    expect(grant.reload.expires_at.to_i).to eq(expiry)
    grant.update_credentials!(expires_at: nil)
    expect(grant.reload.expires_at).to be_nil
  end

  it "preserves other static-data groups when a stale instance updates its group" do
    stale = described_class.find(grant.id)
    grant.update_static_data!("webhook") { |data| data["id"] = "hook" }
    stale.update_static_data!("polling") { |data| data["cursor"] = "cursor" }
    expect(grant.reload.static_data_hash).to eq("webhook" => { "id" => "hook" }, "polling" => { "cursor" => "cursor" })
  end
end
