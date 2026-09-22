require "rails_helper"

# Phase 11 — polish. Small, defer-friendly items: server-generated default
# names, `__skipManagedCreation` enforcement, OAuth2 advanced JWE/JWKS
# fields, and typeOption round-trip for `expirable` / `redactJsonLeaves` /
# `resolvableField`. Webhook setup verification rides on the multi-group
# routing that landed in Phases 6 + 7.
RSpec.describe "Phase 11 — polish" do
  let(:owner) { Owner.create!(name: "p11 owner") }

  let!(:resend_clone) do
    Class.new(Connectors::Connector) do
      connector key: :p11_resend, auth: :api_key, base_url: "https://api.r11.test",
                display_name: "Resend"
      credentials { field :api_key, required: true, secret: true }
    end
  end

  let!(:locked_class) do
    Class.new(Connectors::Connector) do
      connector key: :p11_locked, auth: :api_key, base_url: "https://api.l.test"
      credentials { field :api_key, required: true, secret: true }
      skip_managed_creation!
    end
  end

  after do
    %i[p11_resend p11_locked].each { |k| Connectors::Registry.instance_variable_get(:@store)&.delete(k) }
  end

  describe "GET /connectors/credentials/new?type=X — server-generated default name", type: :request do
    before do
      Connectors.configure do |c|
        c.owner_class_name       = "Owner"
        c.current_owner_resolver = ->(_) { owner }
        c.host_base_url          = "https://app.test"
      end
    end

    it "returns the first slot when no credentials exist for the type" do
      get "/connectors/credentials/new", params: { type: "p11_resend" }
      expect(response).to                       have_http_status(:ok)
      expect(response.parsed_body["name"]).to   eq("Resend account 1")
    end

    it "increments past the highest existing default-shaped name" do
      Connectors::Grant.create!(owner: owner, connector_key: "p11_resend",
                                 credentials: { "api_key" => "k1" }, display_name: "Resend account 1")
      Connectors::Grant.create!(owner: owner, connector_key: "p11_resend",
                                 credentials: { "api_key" => "k2" }, display_name: "Resend account 2")

      get "/connectors/credentials/new", params: { type: "p11_resend" }
      expect(response.parsed_body["name"]).to eq("Resend account 3")
    end

    it "fills the lowest available slot when names are non-contiguous" do
      Connectors::Grant.create!(owner: owner, connector_key: "p11_resend",
                                 credentials: { "api_key" => "k1" }, display_name: "Resend account 2")
      get "/connectors/credentials/new", params: { type: "p11_resend" }
      expect(response.parsed_body["name"]).to eq("Resend account 1")
    end
  end

  describe "__skipManagedCreation flag" do
    it "surfaces on GET /connectors/types/:name", type: :request do
      Connectors.configure do |c|
        c.host_base_url = "https://app.test"
      end
      get "/connectors/types/p11_locked"
      expect(response.parsed_body["__skip_managed_creation"]).to be true

      get "/connectors/types/p11_resend"
      expect(response.parsed_body["__skip_managed_creation"]).to be false
    end

    it "rejects POST /connectors/credentials with is_managed: true for locked types", type: :request do
      Connectors.configure do |c|
        c.owner_class_name       = "Owner"
        c.current_owner_resolver = ->(_) { owner }
        c.host_base_url          = "https://app.test"
      end

      post "/connectors/credentials",
           params: { type: "p11_locked", external_ref: "kv/locked", is_managed: true }
      expect(response).to                 have_http_status(:unauthorized)
      expect(response.body).to            include("managed credentials are disabled")
      expect(Connectors::Grant.count).to  eq(0)
    end

    it "still allows non-managed POSTs for locked types", type: :request do
      Connectors.configure do |c|
        c.owner_class_name       = "Owner"
        c.current_owner_resolver = ->(_) { owner }
        c.host_base_url          = "https://app.test"
      end

      post "/connectors/credentials",
           params: { type: "p11_locked", data: { api_key: "k" } }
      expect(response).to                 have_http_status(:created)
      expect(Connectors::Grant.count).to  eq(1)
    end
  end

  describe "OAuth2 advanced JWE/JWKS base schema fields" do
    let(:oauth2_schema) { Connectors::CredentialTypeRegistry.fetch(:oauth2) }

    it "ships jwe_enabled + jwks_uri in the resolved OAUTH2 form" do
      names = oauth2_schema.resolved_fields.map { |f| f.name.to_s }
      expect(names).to include("jwe_enabled", "jwks_uri")
    end

    it "jwks_uri is conditionally shown when jwe_enabled is true (n8n parity)" do
      jwks = oauth2_schema.resolved_fields.find { |f| f.name == :jwks_uri }
      expect(jwks.display_options).to eq(show: { jwe_enabled: [ true ] })
    end

    it "round-trips through the types serializer", type: :request do
      Connectors.configure do |c|
        c.host_base_url = "https://app.test"
      end
      slack_clone = Class.new(Connectors::Connector) do
        connector key: :p11_oauth, auth: :oauth2, base_url: "https://api.o.test"
        credentials do
          extends :oauth2
          field :authorization_url, type: "hidden", default: "https://auth.o.test/authorize"
          field :access_token_url,  type: "hidden", default: "https://auth.o.test/token"
        end
        oauth2 authorize_url: "https://auth.o.test/authorize",
               token_url:     "https://auth.o.test/token"
      end

      get "/connectors/types/p11_oauth"
      props = response.parsed_body["properties"].map { |p| p["name"] }
      expect(props).to include("jwe_enabled", "jwks_uri")
      Connectors::Registry.instance_variable_get(:@store)&.delete(:p11_oauth)
    end
  end

  describe "typeOption round-trip for expirable / redactJsonLeaves / resolvableField" do
    it "preserves expirable on token fields (CrowdStrike-shape connector)", type: :request do
      Connectors.configure do |c|
        c.host_base_url = "https://app.test"
      end
      expirable_class = Class.new(Connectors::Connector) do
        connector key: :p11_expirable, auth: :oauth2, base_url: "https://api.e.test"
        credentials do
          field :session_token,
                type:         "string",
                display_name: "Session Token",
                secret:       true,
                type_options: { expirable: true }
        end
        oauth2 authorize_url: "https://auth.e.test/a", token_url: "https://auth.e.test/t"
      end

      get "/connectors/types/p11_expirable"
      session_field = response.parsed_body["properties"].find { |p| p["name"] == "session_token" }
      expect(session_field["typeOptions"]).to include("expirable" => true, "password" => true)
      Connectors::Registry.instance_variable_get(:@store)&.delete(:p11_expirable)
    end

    it "preserves redactJsonLeaves on json fields (HttpCustomAuth)" do
      schema = Connectors::CredentialTypeRegistry.fetch(:http_custom_auth)
      json_field = schema.own_fields.find { |f| f.name == :json }
      expect(json_field.to_property[:typeOptions]).to include("redactJsonLeaves" => true)
    end

    it "supports resolvableField on string fields (HttpBasicAuth user/password)", type: :request do
      Connectors.configure do |c|
        c.host_base_url = "https://app.test"
      end
      resolvable_class = Class.new(Connectors::Connector) do
        connector key: :p11_resolvable, auth: :api_key, base_url: "https://api.x.test"
        credentials do
          field :user, type_options: { resolvable_field: true }
          field :password, type_options: { resolvable_field: true }, secret: true
        end
      end

      get "/connectors/types/p11_resolvable"
      user_field = response.parsed_body["properties"].find { |p| p["name"] == "user" }
      expect(user_field["typeOptions"]).to include("resolvable_field" => true)
      Connectors::Registry.instance_variable_get(:@store)&.delete(:p11_resolvable)
    end
  end

  describe "Webhook setup verification (n8n's `webhookMethods.setup`)" do
    # Already exercised by Phase 6 (named group DSL) + Phase 7 (named route +
    # `ctx.webhook_name`). This spec locks in the *Slack URL-verification*
    # use-case end-to-end so the polish phase explicitly closes that loop.
    let!(:slack_clone) do
      Class.new(Connectors::Connector) do
        connector key: :p11_slack, auth: :api_key, base_url: "https://api.s.test"
        credentials { field :token, required: true, secret: true }

        class << self
          attr_accessor :captured_ctx
        end

        def handle_webhook(ctx)
          self.class.captured_ctx = ctx
        end

        # Subscribe-leg (Slack admin posts ?challenge=… here once).
        webhook_methods(:setup) do
          create { |grant, hook_url, static_data|
            static_data["verified_at"] = Time.now.to_i
            true
          }
          delete { |grant, static_data| static_data.delete("verified_at"); true }
        end

        # Event delivery (the long-lived default group).
        webhook_methods(:default) do
          create { |grant, hook_url, static_data|
            static_data["subscribed_at"] = Time.now.to_i
            true
          }
          delete { |grant, static_data| true }
        end
      end
    end

    let(:grant) do
      Connectors::Grant.create!(owner: owner, connector_key: "p11_slack",
                                 credentials: { "token" => "xoxb-test" })
    end

    after { Connectors::Registry.instance_variable_get(:@store)&.delete(:p11_slack) }

    it "subscribe + unsubscribe lifecycle works for each named group independently" do
      Connectors::WebhookLifecycle.subscribe(grant, hook_url: "https://app.test/setup",   webhook_name: :setup)
      Connectors::WebhookLifecycle.subscribe(grant, hook_url: "https://app.test/default", webhook_name: :default)

      grant.reload
      expect(grant.static_data_hash["setup"]).to     include("verified_at")
      expect(grant.static_data_hash["default"]).to   include("subscribed_at")
    end

    it "inbound events on /webhook/setup vs /webhook/default surface the right ctx.webhook_name",
       type: :request do
      Connectors.configure do |c|
        c.owner_class_name       = "Owner"
        c.current_owner_resolver = ->(_) { owner }
        c.host_base_url          = "https://app.test"
      end

      perform_enqueued_jobs do
        post "/connectors/p11_slack/#{grant.id}/webhook/setup",
             params: { "challenge" => "abc" }.to_json,
             headers: { "Content-Type" => "application/json" }
      end
      expect(slack_clone.captured_ctx.webhook_name).to eq(:setup)

      slack_clone.captured_ctx = nil
      perform_enqueued_jobs do
        post "/connectors/p11_slack/#{grant.id}/webhook/default",
             params: { "type" => "message" }.to_json,
             headers: { "Content-Type" => "application/json" }
      end
      expect(slack_clone.captured_ctx.webhook_name).to eq(:default)
    end
  end
end
