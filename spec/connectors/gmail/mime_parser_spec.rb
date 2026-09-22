require "rails_helper"

RSpec.describe Gmail::MimeParser do
  def b64url(s) = Base64.urlsafe_encode64(s, padding: false)

  it "flattens a text-only payload into envelope fields" do
    payload = {
      "mimeType" => "text/plain",
      "headers" => [
        { "name" => "From",    "value" => "alice@example.com" },
        { "name" => "To",      "value" => "bob@example.com" },
        { "name" => "Subject", "value" => "hi" }
      ],
      "body" => { "data" => b64url("plain body") }
    }
    parsed = described_class.parse(payload)
    expect(parsed).to include(
      "subject"     => "hi",
      "from"        => "alice@example.com",
      "to"          => [ "bob@example.com" ],
      "text"        => "plain body",
      "attachments" => []
    )
    expect(parsed).not_to have_key("html")
  end

  it "splits comma-separated To/Cc/Bcc into arrays" do
    payload = {
      "mimeType" => "text/plain",
      "headers" => [
        { "name" => "To",  "value" => "a@x.com, b@x.com" },
        { "name" => "Cc",  "value" => "c@x.com" },
        { "name" => "Bcc", "value" => "d@x.com, e@x.com" }
      ],
      "body" => { "data" => b64url("x") }
    }
    parsed = described_class.parse(payload)
    expect(parsed["to"]).to eq([ "a@x.com", "b@x.com" ])
    expect(parsed["cc"]).to eq([ "c@x.com" ])
    expect(parsed["bcc"]).to eq([ "d@x.com", "e@x.com" ])
  end

  it "extracts text + html from multipart/alternative" do
    payload = {
      "mimeType" => "multipart/alternative",
      "headers"  => [ { "name" => "Subject", "value" => "alt" } ],
      "parts" => [
        { "mimeType" => "text/plain", "body" => { "data" => b64url("plain") } },
        { "mimeType" => "text/html",  "body" => { "data" => b64url("<p>html</p>") } }
      ]
    }
    parsed = described_class.parse(payload)
    expect(parsed["text"]).to eq("plain")
    expect(parsed["html"]).to eq("<p>html</p>")
  end

  it "walks nested multipart/mixed wrapping multipart/alternative + attachments" do
    payload = {
      "mimeType" => "multipart/mixed",
      "headers" => [ { "name" => "Subject", "value" => "mixed" } ],
      "parts" => [
        {
          "mimeType" => "multipart/alternative",
          "parts" => [
            { "mimeType" => "text/plain", "body" => { "data" => b64url("plain") } },
            { "mimeType" => "text/html",  "body" => { "data" => b64url("<p>rich</p>") } }
          ]
        },
        {
          "mimeType" => "application/pdf",
          "filename" => "spec.pdf",
          "body" => { "attachmentId" => "att-1", "size" => 1234 }
        }
      ]
    }
    parsed = described_class.parse(payload)
    expect(parsed["text"]).to eq("plain")
    expect(parsed["html"]).to eq("<p>rich</p>")
    expect(parsed["attachments"]).to eq([
      { "filename" => "spec.pdf", "content_type" => "application/pdf", "size" => 1234, "attachment_id" => "att-1" }
    ])
  end

  it "captures inline attachment body data when present (small images, etc.)" do
    payload = {
      "mimeType" => "multipart/mixed",
      "headers" => [],
      "parts" => [
        { "mimeType" => "text/plain", "body" => { "data" => b64url("x") } },
        {
          "mimeType" => "image/png",
          "filename" => "tiny.png",
          "body" => { "data" => b64url("PNGBYTES"), "size" => 8 }
        }
      ]
    }
    parsed = described_class.parse(payload)
    inline = parsed["attachments"].first
    expect(inline["filename"]).to eq("tiny.png")
    expect(inline["content"]).to be_present
    expect(inline).not_to have_key("attachment_id")
  end

  it "tolerates payloads with no parts and no body" do
    parsed = described_class.parse({ "mimeType" => "text/plain", "headers" => [] })
    expect(parsed["text"]).to be_nil
    expect(parsed["attachments"]).to eq([])
  end

  it "preserves the full headers hash (lowercased keys) for downstream nodes" do
    payload = {
      "mimeType" => "text/plain",
      "headers" => [
        { "name" => "Message-ID", "value" => "<abc@x>" },
        { "name" => "Reply-To",   "value" => "r@x" },
        { "name" => "X-Custom",   "value" => "v" }
      ],
      "body" => { "data" => b64url("x") }
    }
    parsed = described_class.parse(payload)
    expect(parsed["headers"]).to include(
      "message-id" => "<abc@x>",
      "reply-to"   => "r@x",
      "x-custom"   => "v"
    )
    expect(parsed["reply_to"]).to eq([ "r@x" ])
  end
end
