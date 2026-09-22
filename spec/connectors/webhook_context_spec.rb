require "rails_helper"

# Webhook handlers receive body, headers, query and the named group.
RSpec.describe "WebhookContext" do
  let(:owner) { Owner.create!(name: "p7 owner") }

  # Stripe-style connector that needs the `Stripe-Signature` header inside
  # its handler — captured on the WebhookContext.
  let!(:connector_class) do
    Class.new(Connectors::Connector) do
      connector key: :p7_stripe, auth: :api_key, base_url: "https://api.stripe.test"
      credentials { field :api_key, required: true, secret: true }

      class << self
        attr_accessor :captured_ctx
      end

      def handle_webhook(ctx)
        self.class.captured_ctx = ctx
      end
    end
  end

  let(:grant) do
    Connectors::Grant.create!(owner: owner, connector_key: "p7_stripe",
                               credentials: { "api_key" => "sk-test" })
  end

  after do
    Connectors::Registry.instance_variable_get(:@store)&.delete(:p7_stripe)
    connector_class.captured_ctx = nil
  end

  describe "WebhookContext accessors" do
    let(:event) do
      Connectors::WebhookEvent.create!(
        grant:        grant,
        connector_key: "p7_stripe",
        payload:      { "type" => "charge.succeeded", "id" => "evt_1" },
        raw_body:     '{"type":"charge.succeeded","id":"evt_1"}',
        headers:      { "stripe-signature" => "v1=abc", "content-type" => "application/json" },
        query:        { "src" => "test" },
        webhook_name: "default",
        signature:    "v1=abc",
        received_at:  Time.current
      )
    end

    let(:ctx) { Connectors::WebhookContext.new(event) }

    it "exposes body, headers, query and webhook group" do
      expect(ctx.body).to         eq("type" => "charge.succeeded", "id" => "evt_1")
      expect(ctx.payload_hash).to eq("type" => "charge.succeeded", "id" => "evt_1")  # legacy alias
      expect(ctx.payload).to      eq("type" => "charge.succeeded", "id" => "evt_1")  # legacy alias
      expect(ctx.raw_body).to     eq('{"type":"charge.succeeded","id":"evt_1"}')
      expect(ctx.headers).to      include("stripe-signature" => "v1=abc")
      expect(ctx.query).to        eq("src" => "test")
      expect(ctx.webhook_name).to eq(:default)
      expect(ctx.signature).to    eq("v1=abc")
      expect(ctx.grant).to        eq(grant)
      expect(ctx.event).to        eq(event)
    end
  end

  describe "DeliverWebhookJob hands the connector a WebhookContext", type: :job do
    let(:event) do
      Connectors::WebhookEvent.create!(
        grant:        grant,
        connector_key: "p7_stripe",
        payload:      { "type" => "ping" },
        raw_body:     '{"type":"ping"}',
        headers:      { "stripe-signature" => "v1=sig" },
        query:        {},
        webhook_name: "default",
        received_at:  Time.current
      )
    end

    it "exposes headers and raw body to the handler" do
      Connectors::DeliverWebhookJob.perform_now(event.id)
      ctx = connector_class.captured_ctx
      expect(ctx).to be_a(Connectors::WebhookContext)
      expect(ctx.headers["stripe-signature"]).to eq("v1=sig")
      expect(ctx.raw_body).to eq('{"type":"ping"}')
      expect(ctx.payload_hash["type"]).to eq("ping")
      expect(ctx.webhook_name).to eq(:default)
      expect(event.reload.processed?).to be true
    end
  end

  describe "POST /:connector_key/:grant_id/webhook captures headers, query, raw body", type: :request do
    it "persists every piece of the request onto the WebhookEvent" do
      perform_enqueued_jobs do
        post "/connectors/p7_stripe/#{grant.id}/webhook?src=test",
             params:  { "type" => "ping", "data" => { "id" => "ch_1" } }.to_json,
             headers: {
               "Content-Type"     => "application/json",
               "Stripe-Signature" => "v1=fake-sig",
               "X-Forwarded-For"  => "203.0.113.1"
             }
      end

      expect(response).to have_http_status(:accepted)

      event = Connectors::WebhookEvent.order(:id).last
      expect(event.payload_hash).to       eq("type" => "ping", "data" => { "id" => "ch_1" })
      expect(event.raw_body).to           include('"type":"ping"')
      expect(event.headers["stripe-signature"]).to eq("v1=fake-sig")
      expect(event.headers["x-forwarded-for"]).to  eq("203.0.113.1")
      expect(event.query).to              eq("src" => "test")
      expect(event.webhook_name).to       eq("default")
    end
  end

  describe "POST /:connector_key/:grant_id/webhook/:webhook_name routes named groups", type: :request do
    it "stores the named group on the event so multi-webhook handlers can branch" do
      perform_enqueued_jobs do
        post "/connectors/p7_stripe/#{grant.id}/webhook/setup",
             params:  { "challenge" => "abc" }.to_json,
             headers: { "Content-Type" => "application/json" }
      end

      event = Connectors::WebhookEvent.order(:id).last
      expect(event.webhook_name).to eq("setup")
      expect(connector_class.captured_ctx.webhook_name).to eq(:setup)
    end
  end
end
