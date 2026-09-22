require "rails_helper"

RSpec.describe "Connector type polish (Wave E)", type: :request do
  describe "GET /connectors/types — icon + docs URL + display_name" do
    it "exposes Resend's icon, color, display_name, and documentation_url" do
      get "/connectors/types/resend"
      body = response.parsed_body

      expect(body).to include(
        "name"              => "resend",
        "display_name"      => "Resend",
        "icon"              => "https://cdn.resend.com/brand/resend-icon-blacka.svg",
        "icon_color"        => "#000000",
        "documentation_url" => "https://resend.com/docs/api-reference/emails/send-email"
      )
    end

    it "exposes Slack's brand metadata" do
      get "/connectors/types/slack"
      expect(response.parsed_body).to include(
        "display_name" => "Slack",
        "icon_color"   => "#4A154B"
      )
    end
  end

  describe "DisplayCondition `_cnd` predicates pass through display_options unchanged" do
    let(:schema_class) do
      Class.new(Connectors::Connector) do
        connector key: :wave_e_demo, auth: :api_key, base_url: "https://example.test"
        credentials do
          field :mode, type: "options", default: "simple",
                       options: [
                         { name: "Simple",   value: "simple" },
                         { name: "Advanced", value: "advanced" }
                       ]
          # n8n's `_cnd` predicates (interfaces.ts:1730-1742) — frontend
          # interprets these to decide field visibility.
          field :advanced_url, type: "string",
                                display_options: {
                                  show: { mode: [ "advanced" ] }
                                }
          field :pattern, type: "string",
                          display_options: {
                            show: { advanced_url: [ { _cnd: { regex: "^https://" } } ] }
                          }
        end
      end
    end

    before { schema_class }   # force registration

    after do
      Connectors::Registry.instance_variable_get(:@store)&.delete(:wave_e_demo)
    end

    it "serializes _cnd predicates intact (no reformatting / loss)" do
      get "/connectors/types/wave_e_demo"
      pattern_field = response.parsed_body["properties"].find { |p| p["name"] == "pattern" }
      expect(pattern_field["displayOptions"]).to eq(
        "show" => { "advanced_url" => [ { "_cnd" => { "regex" => "^https://" } } ] }
      )
    end

    it "passes plain value-array display_options through too" do
      get "/connectors/types/wave_e_demo"
      adv_field = response.parsed_body["properties"].find { |p| p["name"] == "advanced_url" }
      expect(adv_field["displayOptions"]).to eq("show" => { "mode" => [ "advanced" ] })
    end
  end
end
