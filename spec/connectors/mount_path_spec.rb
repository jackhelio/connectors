require "rails_helper"

# `Connectors::Engine.mount_path` discovers where the host actually mounted
# the engine, so URL builders (OAuth callback, default webhook URL,
# `redirect_uri` on the types endpoint) don't hardcode `/connectors`.
RSpec.describe Connectors::Engine do
  describe ".mount_path" do
    it "returns the path the engine is mounted at in the test dummy app" do
      # The dummy's `config/routes.rb` mounts the engine at /connectors —
      # if that ever changes, update this expectation in lockstep.
      expect(described_class.mount_path).to eq("/connectors")
    end

    it "is cached after first call" do
      first  = described_class.mount_path
      second = described_class.mount_path
      expect(first).to equal(second)   # same object — cached
    end

    it "is reset-able for tests that remount" do
      original = described_class.mount_path
      described_class.reset_mount_path!
      expect(described_class.instance_variable_get(:@mount_path)).to be_nil
      expect(described_class.mount_path).to eq(original)
    end

    # Real-world host pattern (`flow-api`): the engine is mounted INSIDE
    # `namespace :api { scope "v1" }`, which produces a route whose `app`
    # chain is `Constraints → Connectors::Engine → LazyRouteSet`. An
    # earlier walk-to-terminal version of `lookup_mount_path` unwrapped
    # past the engine class and missed the match, silently falling back
    # to `/connectors` and emitting a bogus OAuth redirect_uri.
    it "discovers the mount path when the engine sits inside namespace+scope" do
      fake_routes = ActionDispatch::Routing::RouteSet.new
      fake_routes.draw do
        namespace :api do
          scope "v1" do
            mount Connectors::Engine => "/connectors"
          end
        end
      end

      begin
        allow(Rails.application).to receive(:routes).and_return(fake_routes)
        described_class.reset_mount_path!
        expect(described_class.mount_path).to eq("/api/v1/connectors")
      ensure
        described_class.reset_mount_path!
      end
    end
  end

  describe "URL builders use the discovered mount path" do
    let(:owner) { Owner.create!(name: "mount path owner") }

    let!(:fake_oauth_class) do
      Class.new(Connectors::Connector) do
        connector key: :mp_oauth, auth: :oauth2, base_url: "https://api.mp.test"
        credentials do
          field :access_token, type: "hidden", default: "", secret: true
        end
        oauth2 authorize_url: "https://auth.mp.test/auth",
               token_url:     "https://auth.mp.test/token"
      end
    end

    let!(:fake_webhook_class) do
      Class.new(Connectors::Connector) do
        connector key: :mp_webhook, auth: :api_key, base_url: "https://api.mp2.test"
        credentials { field :api_key, required: true, secret: true }
        webhook_methods do
          create { |_grant, hook_url, sub| sub["url"] = hook_url; true }
          delete { |_grant, _sub| true }
        end
      end
    end

    after do
      %i[mp_oauth mp_webhook].each { |k| Connectors::Registry.instance_variable_get(:@store)&.delete(k) }
    end

    it "OAuth authorize URL uses the mount path", type: :request do
      Connectors.configure do |c|
        c.owner_class_name       = "Owner"
        c.current_owner_resolver = ->(_) { owner }
        c.host_base_url          = "https://app.test"
        c.oauth_credentials      = { mp_oauth: { client_id: "id", client_secret: "secret" } }
      end

      get "/connectors/mp_oauth/authorize"
      expect(response).to have_http_status(:redirect)
      params = URI.decode_www_form(URI.parse(response.location).query).to_h
      expect(params["redirect_uri"]).to eq("https://app.test#{Connectors::Engine.mount_path}/mp_oauth/callback")
    end

    it "Default webhook subscribe URL uses the mount path", type: :request do
      grant = Connectors::Grant.create!(owner: owner, connector_key: "mp_webhook",
                                         credentials: { "api_key" => "k" })
      Connectors.configure do |c|
        c.owner_class_name       = "Owner"
        c.current_owner_resolver = ->(_) { owner }
        c.host_base_url          = "https://app.test"
      end

      post "/connectors/grants/#{grant.id}/webhook_subscribe"
      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["hook_url"]).to eq(
        "https://app.test#{Connectors::Engine.mount_path}/mp_webhook/#{grant.id}/webhook"
      )
    end

    it "types/:name response surfaces mount-aware authorize URLs", type: :request do
      Connectors.configure { |c| c.host_base_url = "https://app.test" }

      get "/connectors/types/mp_oauth"
      body = response.parsed_body
      expect(body.dig("connector", "redirect_uri")).to       eq("https://app.test#{Connectors::Engine.mount_path}/mp_oauth/callback")
      expect(body.dig("connector", "authorize_url")).to      eq("#{Connectors::Engine.mount_path}/mp_oauth/authorize")
      expect(body.dig("connector", "authorize_json_url")).to eq("#{Connectors::Engine.mount_path}/mp_oauth/authorize.json")
    end
  end
end
