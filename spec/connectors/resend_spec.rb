require "rails_helper"

RSpec.describe Resend::Connector do
  let(:owner) { Owner.create!(name: "resend owner") }
  let(:grant) do
    Connectors::Grant.create!(
      owner:         owner,
      connector_key: "resend",
      credentials:   { "api_key" => "re_test_key" }
    )
  end
  let(:connector) { grant.connector }

  describe "#send_email" do
    let(:success_body) { { id: "abc-123" }.to_json }

    it "POSTs to /emails with the API key in the Authorization header" do
      stub = stub_request(:post, "https://api.resend.com/emails")
              .with(
                headers: { "Authorization" => "Bearer re_test_key", "Content-Type" => "application/json" },
                body:    hash_including(
                  "from"    => "Updates <updates@example.com>",
                  "to"      => [ "alice@example.com" ],
                  "subject" => "Hi",
                  "html"    => "<p>Hello</p>"
                )
              )
              .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: success_body)

      result = connector.send_email(
        from:    "Updates <updates@example.com>",
        to:      "alice@example.com",
        subject: "Hi",
        html:    "<p>Hello</p>"
      )

      expect(stub).to have_been_requested
      expect(result).to eq("id" => "abc-123")
    end

    it "accepts an array of recipients" do
      stub = stub_request(:post, "https://api.resend.com/emails")
              .with(body: hash_including("to" => [ "a@example.com", "b@example.com" ]))
              .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: success_body)

      connector.send_email(from: "x@example.com", to: [ "a@example.com", "b@example.com" ],
                            subject: "Hi", html: "<p>Hello</p>")
      expect(stub).to have_been_requested
    end

    it "includes optional cc / bcc / reply_to / tags when supplied" do
      # `reply_to` is `string[]` per Resend's docs — the connector wraps a
      # scalar caller-input via Array() so the wire payload matches the spec.
      stub = stub_request(:post, "https://api.resend.com/emails")
              .with(body: hash_including(
                "cc"        => [ "cc@example.com" ],
                "bcc"       => [ "bcc@example.com" ],
                "reply_to"  => [ "reply@example.com" ],
                "tags"      => [ { "name" => "kind", "value" => "demo" } ]
              ))
              .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: success_body)

      connector.send_email(
        from: "x@example.com", to: "a@example.com", subject: "Hi", html: "<p>Hello</p>",
        cc: "cc@example.com", bcc: "bcc@example.com",
        reply_to: "reply@example.com",
        tags: [ { "name" => "kind", "value" => "demo" } ]
      )
      expect(stub).to have_been_requested
    end

    it "raises ApiError when both html and text are absent" do
      expect {
        connector.send_email(from: "x@example.com", to: "a@example.com", subject: "Hi")
      }.to raise_error(Connectors::ApiError, /html or text/)
    end

    it "promotes Resend's 4xx errors into Connectors::ApiError" do
      # The engine's ErrorNormalization middleware intercepts non-2xx
      # responses and raises ApiError before our `send_email` body inspects
      # the payload — we just need to confirm SOME ApiError surfaces with
      # the failing status code.
      stub_request(:post, "https://api.resend.com/emails").to_return(
        status: 422,
        headers: { "Content-Type" => "application/json" },
        body:   { name: "validation_error", message: "Invalid `to` field", statusCode: 422 }.to_json
      )

      expect {
        connector.send_email(from: "x@example.com", to: "bogus", subject: "Hi", html: "<p>Hello</p>")
      }.to raise_error(Connectors::ApiError, /422/)
    end
  end

  describe "registry + /connectors/types" do
    it "is registered under the :resend key" do
      expect(Connectors::Registry.fetch(:resend)).to eq(described_class)
    end

    it "exposes its credential schema with one required api_key (typeOptions.password=true)" do
      schema = described_class.credential_schema
      field  = schema.fields.find { |f| f.name == :api_key }
      expect(field.required?).to be true
      expect(field.password?).to be true
      expect(field.to_property).to include(
        name:        "api_key",
        type:        "string",
        required:    true,
        typeOptions: { "password" => true }
      )
    end
  end
end
