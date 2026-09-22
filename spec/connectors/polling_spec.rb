require "rails_helper"

# Polling callbacks return new items and persist their cursor state.
RSpec.describe "polling DSL + cursor" do
  let(:owner) { Owner.create!(name: "p8 owner") }

  # Gmail-shaped polling: GET /messages?since=<last_id> returns items in
  # newest-first order; we stash the first item's ID as the new high-water
  # mark so the next tick filters strictly newer messages.
  let!(:connector_class) do
    Class.new(Connectors::Connector) do
      connector key: :p8_gmail, auth: :api_key, base_url: "https://api.gmail.test"
      credentials { field :token, required: true, secret: true }
      authenticate type: :generic, properties: {
        headers: { "Authorization" => "=Bearer {{$credentials.token}}" }
      }

      polling do |grant, static_data|
        since = static_data["last_id"]
        items = grant.connector.client.get("messages", { since: since }.compact).body["items"]
        static_data["last_id"] = items.first["id"] if items.is_a?(Array) && items.any?
        items
      end
    end
  end

  let(:grant) do
    Connectors::Grant.create!(owner: owner, connector_key: "p8_gmail",
                               credentials: { "token" => "tok" })
  end

  after { Connectors::Registry.instance_variable_get(:@store)&.delete(:p8_gmail) }

  describe "DSL readback" do
    it "stores the polling block and exposes the polling? predicate" do
      expect(connector_class.polling?).to be true
      expect(connector_class.polling_block).to be_a(Proc)
    end

    it "polling? returns false when no block is declared" do
      bare = Class.new(Connectors::Connector) do
        connector key: :p8_bare, auth: :api_key, base_url: "https://x.test"
        credentials { field :api_key, required: true, secret: true }
      end
      expect(bare.polling?).to be false
      Connectors::Registry.instance_variable_get(:@store)&.delete(:p8_bare)
    end
  end

  describe "Connectors::PollRunner.run" do
    it "fires the block, returns the items, and advances the cursor on the grant" do
      stub_request(:get, "https://api.gmail.test/messages")
        .with(headers: { "Authorization" => "Bearer tok" })
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { "items" => [ { "id" => "msg-3" }, { "id" => "msg-2" }, { "id" => "msg-1" } ] }.to_json)

      result = Connectors::PollRunner.run(grant)
      expect(result[:items].size).to eq(3)
      expect(result[:items].first["id"]).to eq("msg-3")
      expect(result[:static_data]).to eq("last_id" => "msg-3")
      expect(grant.reload.static_data_hash.dig("polling", "last_id")).to eq("msg-3")
    end

    it "passes the cursor on the second call and advances on new items" do
      grant.update_static_data!("polling") { |sub| sub["last_id"] = "msg-3" }

      stub_request(:get, "https://api.gmail.test/messages")
        .with(query: { since: "msg-3" }, headers: { "Authorization" => "Bearer tok" })
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { "items" => [ { "id" => "msg-5" }, { "id" => "msg-4" } ] }.to_json)

      result = Connectors::PollRunner.run(grant)
      expect(result[:items].map { |i| i["id"] }).to eq(%w[msg-5 msg-4])
      expect(grant.reload.static_data_hash.dig("polling", "last_id")).to eq("msg-5")
    end

    it "leaves the cursor untouched when the provider returns no new items" do
      grant.update_static_data!("polling") { |sub| sub["last_id"] = "msg-5" }

      stub_request(:get, "https://api.gmail.test/messages")
        .with(query: { since: "msg-5" })
        .to_return(status: 200, body: '{"items":[]}', headers: { "Content-Type" => "application/json" })

      result = Connectors::PollRunner.run(grant)
      expect(result[:items]).to eq([])
      expect(grant.reload.static_data_hash.dig("polling", "last_id")).to eq("msg-5")
    end

    it "raises when the connector has no polling block declared" do
      bare = Class.new(Connectors::Connector) do
        connector key: :p8_static, auth: :api_key, base_url: "https://x.test"
        credentials { field :api_key, required: true, secret: true }
      end
      g = Connectors::Grant.create!(owner: owner, connector_key: "p8_static",
                                     credentials: { "api_key" => "k" })
      expect {
        Connectors::PollRunner.run(g)
      }.to raise_error(Connectors::Error, /no polling block declared/)
      Connectors::Registry.instance_variable_get(:@store)&.delete(:p8_static)
    end

    it "isolates polling cursor from webhook static_data (different group keys)" do
      grant.update_static_data!("default") { |sub| sub["webhook_id"] = 42 }

      stub_request(:get, "https://api.gmail.test/messages")
        .to_return(status: 200, body: '{"items":[{"id":"m1"}]}',
                   headers: { "Content-Type" => "application/json" })

      Connectors::PollRunner.run(grant)

      grant.reload
      expect(grant.static_data_hash).to eq(
        "default" => { "webhook_id" => 42 },
        "polling" => { "last_id" => "m1" }
      )
    end
  end

  describe "POST /connectors/grants/:id/poll", type: :request do
    before do
      Connectors.configure do |c|
        c.owner_class_name       = "Owner"
        c.current_owner_resolver = ->(_) { owner }
        c.host_base_url          = "https://app.test"
      end
    end

    it "returns the items + new cursor as JSON" do
      stub_request(:get, "https://api.gmail.test/messages")
        .to_return(status: 200, body: '{"items":[{"id":"msg-9"}]}',
                   headers: { "Content-Type" => "application/json" })

      post "/connectors/grants/#{grant.id}/poll"
      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["items"].first["id"]).to eq("msg-9")
      expect(body["static_data"]).to       eq("last_id" => "msg-9")
    end
  end
end
