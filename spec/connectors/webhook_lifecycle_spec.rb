require "rails_helper"

# Webhook subscription callbacks and persisted lifecycle state.
RSpec.describe "webhook_methods DSL + lifecycle" do
  let(:owner) { Owner.create!(name: "p6 owner") }

  # Postmark-shaped connector: GET /webhooks → list; POST /webhooks → create
  # with returned ID; DELETE /webhooks/:id → remove. Persists `webhook_id`
  # in static_data so delete can target the right remote object later.
  let!(:postmark_class) do
    Class.new(Connectors::Connector) do
      connector key: :p6_postmark, auth: :api_key, base_url: "https://api.postmark.test"
      credentials { field :token, required: true, secret: true }
      authenticate type: :generic, properties: {
        headers: { "X-Postmark-Server-Token" => "={{$credentials.token}}" }
      }

      webhook_methods do
        check_exists do |grant, hook_url, static_data|
          body = grant.connector.client.get("webhooks").body
          found = body["Webhooks"].find { |h| h["Url"] == hook_url }
          static_data["webhook_id"] = found["ID"] if found
          !found.nil?
        end

        create do |grant, hook_url, static_data|
          resp = grant.connector.client.post("webhooks", { url: hook_url }.to_json).body
          if resp["ID"]
            static_data["webhook_id"] = resp["ID"]
            true
          else
            false
          end
        end

        delete do |grant, static_data|
          id = static_data["webhook_id"]
          next true if id.nil?
          grant.connector.client.delete("webhooks/#{id}")
          static_data.delete("webhook_id")
          true
        end
      end
    end
  end

  let(:grant) do
    Connectors::Grant.create!(
      owner:         owner,
      connector_key: "p6_postmark",
      credentials:   { "token" => "postmark-test-token" }
    )
  end

  after { Connectors::Registry.instance_variable_get(:@store)&.delete(:p6_postmark) }

  describe "DSL readback" do
    it "registers the default group with all three callbacks" do
      group = postmark_class.webhook_group(:default)
      expect(group.name).to eq(:default)
      expect(group.check_exists).to be_a(Proc)
      expect(group.create).to       be_a(Proc)
      expect(group.delete).to       be_a(Proc)
    end

    it "supports multiple named groups for multi-webhook providers" do
      multi = Class.new(Connectors::Connector) do
        connector key: :p6_multi, auth: :api_key, base_url: "https://api.m.test"
        credentials { field :token, required: true, secret: true }
        webhook_methods(:default) { create { |*| true }; delete { |*| true } }
        webhook_methods(:setup)   { create { |*| true }; delete { |*| true } }
      end
      expect(multi.webhook_group_names.sort).to eq(%i[default setup])
      Connectors::Registry.instance_variable_get(:@store)&.delete(:p6_multi)
    end
  end

  describe "Grant#update_static_data!" do
    it "yields the per-group sub-hash and persists the mutation atomically" do
      grant.update_static_data!(:default) { |sub| sub["last_seen_id"] = "abc-1" }
      expect(grant.reload.static_data_hash).to eq("default" => { "last_seen_id" => "abc-1" })

      # Second group lives alongside the first.
      grant.update_static_data!(:setup) { |sub| sub["verification_token"] = "xyz" }
      expect(grant.reload.static_data_hash).to eq(
        "default" => { "last_seen_id" => "abc-1" },
        "setup"   => { "verification_token" => "xyz" }
      )
    end
  end

  describe "Connectors::WebhookLifecycle.subscribe" do
    let(:hook_url) { "https://app.test/connectors/p6_postmark/#{grant.id}/webhook" }

    it "calls create when the provider has no matching webhook, persisting the returned ID" do
      stub_request(:get, "https://api.postmark.test/webhooks")
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { "Webhooks" => [] }.to_json)
      create_stub = stub_request(:post, "https://api.postmark.test/webhooks")
        .with(body: { "url" => hook_url }.to_json)
        .to_return(status: 201, headers: { "Content-Type" => "application/json" },
                   body: { "ID" => 42, "Url" => hook_url }.to_json)

      result = Connectors::WebhookLifecycle.subscribe(grant, hook_url: hook_url)

      expect(create_stub).to have_been_requested.once
      expect(result[:status]).to eq("created")
      expect(result[:static_data]["webhook_id"]).to eq(42)
      expect(grant.reload.static_data_hash.dig("default", "webhook_id")).to eq(42)
    end

    it "skips create when checkExists finds a matching webhook, but still records the ID" do
      stub_request(:get, "https://api.postmark.test/webhooks")
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { "Webhooks" => [ { "ID" => 99, "Url" => hook_url } ] }.to_json)
      create_stub = stub_request(:post, "https://api.postmark.test/webhooks")

      result = Connectors::WebhookLifecycle.subscribe(grant, hook_url: hook_url)

      expect(create_stub).not_to have_been_requested
      expect(result[:status]).to                    eq("exists")
      expect(result[:static_data]["webhook_id"]).to eq(99)
      expect(grant.reload.static_data_hash.dig("default", "webhook_id")).to eq(99)
    end

    it "raises Connectors::Error when create returns false (provider refused)" do
      stub_request(:get, "https://api.postmark.test/webhooks").to_return(status: 200, body: '{"Webhooks":[]}',
                                                                          headers: { "Content-Type" => "application/json" })
      stub_request(:post, "https://api.postmark.test/webhooks")
        .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })

      expect {
        Connectors::WebhookLifecycle.subscribe(grant, hook_url: hook_url)
      }.to raise_error(Connectors::Error, /create returned false/)
    end

    it "raises when the connector has no webhook_methods for the named group" do
      bare = Class.new(Connectors::Connector) do
        connector key: :p6_bare, auth: :api_key, base_url: "https://x.test"
        credentials { field :token, required: true, secret: true }
      end
      g = Connectors::Grant.create!(owner: owner, connector_key: "p6_bare", credentials: { "token" => "t" })

      expect {
        Connectors::WebhookLifecycle.subscribe(g, hook_url: "https://app.test/x")
      }.to raise_error(Connectors::Error, /no webhook_methods declared/)
      Connectors::Registry.instance_variable_get(:@store)&.delete(:p6_bare)
    end
  end

  describe "Connectors::WebhookLifecycle.unsubscribe" do
    it "calls delete and strips webhook_id from static_data" do
      grant.update_static_data!(:default) { |sub| sub["webhook_id"] = 42 }

      delete_stub = stub_request(:delete, "https://api.postmark.test/webhooks/42")
        .to_return(status: 200, body: "")

      result = Connectors::WebhookLifecycle.unsubscribe(grant)

      expect(delete_stub).to have_been_requested.once
      expect(result[:status]).to eq("deleted")
      expect(grant.reload.static_data_hash.dig("default", "webhook_id")).to be_nil
    end

    it "still runs the block even when no webhook_id is set (idempotent unsubscribe)" do
      result = Connectors::WebhookLifecycle.unsubscribe(grant)
      expect(result[:status]).to eq("deleted")
    end
  end

  describe "POST/DELETE /connectors/grants/:id/webhook_subscribe", type: :request do
    before do
      Connectors.configure do |c|
        c.owner_class_name       = "Owner"
        c.current_owner_resolver = ->(_) { owner }
        c.host_base_url          = "https://app.test"
      end
    end

    it "defaults hook_url to the per-grant inbound URL when none supplied" do
      stub_request(:get, "https://api.postmark.test/webhooks").to_return(status: 200,
        body: '{"Webhooks":[]}', headers: { "Content-Type" => "application/json" })
      create_stub = stub_request(:post, "https://api.postmark.test/webhooks")
        .with(body: { "url" => "https://app.test/connectors/p6_postmark/#{grant.id}/webhook" }.to_json)
        .to_return(status: 201, body: '{"ID":7}', headers: { "Content-Type" => "application/json" })

      post "/connectors/grants/#{grant.id}/webhook_subscribe"
      expect(response).to have_http_status(:ok)
      expect(create_stub).to have_been_requested.once
      body = response.parsed_body
      expect(body["status"]).to        eq("created")
      expect(body["webhook_name"]).to  eq("default")
      expect(body["hook_url"]).to      eq("https://app.test/connectors/p6_postmark/#{grant.id}/webhook")
    end

    it "DELETE invokes unsubscribe and returns deleted" do
      grant.update_static_data!(:default) { |sub| sub["webhook_id"] = 11 }
      stub_request(:delete, "https://api.postmark.test/webhooks/11").to_return(status: 200, body: "")

      delete "/connectors/grants/#{grant.id}/webhook_subscribe"
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["status"]).to eq("deleted")
    end
  end
end
