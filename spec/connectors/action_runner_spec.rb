require "rails_helper"

RSpec.describe Connectors::ActionRunner do
  before { Connectors::Registry.clear! }
  after  { Connectors::Registry.clear! }

  # Tiny connector with one fully-declared action — lets us exercise the
  # runner without touching any external HTTP.
  let(:connector_class) do
    Class.new(Connectors::Connector) do
      def self.name; "ActionSpecConnector"; end

      connector key: :action_spec, auth: :api_key, base_url: "https://example.test"
      credentials do
        field :api_key, required: true, secret: true
      end
      api_key_in :header, name: "X-Spec-Token"

      action :echo, display_name: "Echo", description: "Returns its inputs." do
        field :message, type: "string", required: true
        field :tag,     type: "string"
        output do
          field :message, type: "string"
          field :tag,     type: "string"
        end
        execute do |input|
          # `self` is the connector instance — exercise it so the runner's
          # instance_exec binding is verified.
          { "message" => input["message"], "tag" => input["tag"], "via" => self.class.connector_key }
        end
      end

      action :boom, display_name: "Boom" do
        field :why, type: "string", required: true
        execute do |input|
          raise Connectors::ApiError.new("kaboom: #{input["why"]}", status: 503)
        end
      end
    end
  end

  let(:owner) { Owner.create!(name: "actions owner") }
  let(:grant) do
    # Force the anonymous class to evaluate so its `connector key: :action_spec, ...`
    # DSL call registers in `Connectors::Registry` before the grant is used —
    # `let` is lazy, so without this nothing references `connector_class`.
    connector_class
    Connectors::Grant.create!(
      owner:         owner,
      connector_key: "action_spec",
      credentials:   { "api_key" => "k" }
    )
  end

  describe ".call" do
    it "validates required params and returns an invalid_params envelope" do
      result = described_class.call(grant, :echo, {})
      expect(result[:status]).to eq("error")
      expect(result.dig(:error, :type)).to eq("invalid_params")
      expect(result.dig(:error, :missing)).to eq([ "message" ])
    end

    it "executes the action in the connector instance's context" do
      result = described_class.call(grant, :echo, { "message" => "hi", "tag" => "t" })
      expect(result[:status]).to eq("ok")
      expect(result[:action]).to eq("echo")
      expect(result[:data]).to eq("message" => "hi", "tag" => "t", "via" => :action_spec)
    end

    it "rejects a stale grant revoked by another worker before executing its action" do
      stale = grant
      Connectors::Grant.find(stale.id).update!(status: :revoked)
      connector = stale.connector
      allow(stale).to receive(:connector).and_return(connector)
      expect(connector).not_to receive(:instance_exec)
      result = described_class.call(stale, :echo, { "message" => "hi" })
      expect(result[:status]).to eq("error")
      expect(result.dig(:error, :type)).to eq("authentication_failed")
    end

    it "drops unknown keys before invoking the block" do
      result = described_class.call(grant, :echo, { "message" => "hi", "intruder" => "x" })
      expect(result[:status]).to eq("ok")
      expect(result[:data]).not_to have_key("intruder")
    end

    it "normalizes Connectors::ApiError into an api_error envelope" do
      result = described_class.call(grant, :boom, { "why" => "test" })
      expect(result[:status]).to eq("error")
      expect(result.dig(:error, :type)).to eq("api_error")
      expect(result.dig(:error, :status)).to eq(503)
      expect(result.dig(:error, :message)).to match(/kaboom: test/)
    end

    it "propagates UnknownAction so the controller can render a 404" do
      expect {
        described_class.call(grant, :does_not_exist, {})
      }.to raise_error(Connectors::UnknownAction, /:does_not_exist/)
    end
  end
end
