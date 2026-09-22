require "rails_helper"

RSpec.describe Gmail::MimeBuilder do
  def decode(b64)
    Base64.urlsafe_decode64(b64)
  end

  it "raises when neither html nor text is supplied" do
    expect {
      described_class.build(to: "a@x.com", subject: "Hi")
    }.to raise_error(ArgumentError, /html or text/)
  end

  it "raises when no recipient is supplied" do
    expect {
      described_class.build(to: [], subject: "Hi", text: "hello")
    }.to raise_error(ArgumentError, /at least one recipient/)
  end

  describe "single-part message" do
    it "builds a text/plain body when only `text:` is supplied" do
      raw = decode(described_class.build(to: "a@x.com", subject: "Hi", text: "hello"))
      expect(raw).to include("To: a@x.com")
      expect(raw).to include("Subject: Hi")
      expect(raw).to include("Content-Type: text/plain; charset=UTF-8")
      expect(raw).to include(Base64.encode64("hello").chomp)
    end

    it "builds a text/html body when only `html:` is supplied" do
      raw = decode(described_class.build(to: "a@x.com", subject: "Hi", html: "<p>hi</p>"))
      expect(raw).to include("Content-Type: text/html; charset=UTF-8")
      expect(raw).to include(Base64.encode64("<p>hi</p>").chomp)
    end
  end

  describe "multipart/alternative" do
    it "wraps html + text under a single multipart/alternative boundary" do
      raw = decode(described_class.build(
        to: "a@x.com", subject: "Hi", text: "plain", html: "<p>rich</p>"
      ))

      expect(raw).to match(/Content-Type: multipart\/alternative; boundary="alt_\h+"/)
      boundary = raw[/boundary="(alt_\h+)"/, 1]
      expect(raw.scan("--#{boundary}").length).to eq(3)        # open, open, close
      expect(raw).to include("Content-Type: text/plain")
      expect(raw).to include("Content-Type: text/html")
    end
  end

  describe "multipart/mixed (attachments)" do
    let(:attachment) do
      {
        filename:     "hello.txt",
        content:      Base64.strict_encode64("hello world"),
        content_type: "text/plain"
      }
    end

    it "uses multipart/mixed for body + attachments" do
      raw = decode(described_class.build(
        to: "a@x.com", subject: "Hi", text: "body",
        attachments: [ attachment ]
      ))
      expect(raw).to match(/Content-Type: multipart\/mixed; boundary="mix_\h+"/)
      expect(raw).to include("Content-Disposition: attachment; filename=\"hello.txt\"")
      expect(raw).to include(Base64.strict_encode64("hello world"))
    end

    it "nests multipart/alternative inside multipart/mixed when both html+text+attachments are present" do
      raw = decode(described_class.build(
        to: "a@x.com", subject: "Hi",
        text: "plain", html: "<p>rich</p>",
        attachments: [ attachment ]
      ))
      expect(raw).to include("multipart/mixed")
      expect(raw).to include("multipart/alternative")
    end

    it "raises when an attachment has no content" do
      expect {
        described_class.build(
          to: "a@x.com", subject: "Hi", text: "body",
          attachments: [ { filename: "x.txt" } ]
        )
      }.to raise_error(ArgumentError, /missing `content`/)
    end
  end

  describe "headers" do
    it "includes CC, BCC, Reply-To when supplied" do
      raw = decode(described_class.build(
        to: "a@x.com", subject: "Hi", text: "body",
        cc: [ "c1@x.com", "c2@x.com" ],
        bcc: "secret@x.com",
        reply_to: "reply@x.com"
      ))
      expect(raw).to include("Cc: c1@x.com, c2@x.com")
      expect(raw).to include("Bcc: secret@x.com")
      expect(raw).to include("Reply-To: reply@x.com")
    end

    it "RFC 2047-encodes non-ASCII subjects" do
      raw = decode(described_class.build(to: "a@x.com", subject: "héllo", text: "body"))
      expect(raw).to include("Subject: =?UTF-8?B?#{Base64.strict_encode64('héllo')}?=")
    end

    it "passes through custom headers" do
      raw = decode(described_class.build(
        to: "a@x.com", subject: "Hi", text: "body",
        headers: { "X-Tag" => "release" }
      ))
      expect(raw).to include("X-Tag: release")
    end

    it "sets In-Reply-To and References when supplied (threaded reply)" do
      raw = decode(described_class.build(
        to: "a@x.com", subject: "Re: Hi", text: "reply",
        in_reply_to: "<parent@example.com>",
        references:  "<root@example.com> <parent@example.com>"
      ))
      expect(raw).to include("In-Reply-To: <parent@example.com>")
      expect(raw).to include("References: <root@example.com> <parent@example.com>")
    end
  end

  it "returns base64url-encoded output (no padding) ready for Gmail's `raw` field" do
    encoded = described_class.build(to: "a@x.com", subject: "Hi", text: "body")
    # base64url uses `-_` instead of `+/` and drops `=` padding
    expect(encoded).not_to include("=")
    expect(encoded).not_to include("+")
    expect(encoded).not_to include("/")
    expect { Base64.urlsafe_decode64(encoded) }.not_to raise_error
  end

  describe "RFC 2047 phrase encoding in address headers" do
    it "ASCII display names pass through unchanged" do
      raw = decode(described_class.build(
        to: "Alice <alice@example.com>", subject: "Hi", text: "body",
        from: "Updates <updates@example.com>"
      ))
      expect(raw).to include("From: Updates <updates@example.com>")
      expect(raw).to include("To: Alice <alice@example.com>")
    end

    it "encodes the phrase (display name) when it contains non-ASCII chars" do
      raw = decode(described_class.build(
        to: "Héllo <h@example.com>", subject: "Hi", text: "body",
        from: "Café <c@example.com>"
      ))
      expect(raw).to include("From: =?UTF-8?B?#{Base64.strict_encode64('Café')}?= <c@example.com>")
      expect(raw).to include("To: =?UTF-8?B?#{Base64.strict_encode64('Héllo')}?= <h@example.com>")
    end

    it "leaves bare addr-spec values alone (no phrase to encode)" do
      raw = decode(described_class.build(to: "h@example.com", subject: "Hi", text: "body"))
      expect(raw).to include("To: h@example.com")
    end
  end

  describe "RFC 2231 attachment filenames" do
    let(:b64_content) { Base64.strict_encode64("hello world") }

    it "uses simple quoted `name=` / `filename=` for ASCII filenames" do
      raw = decode(described_class.build(
        to: "a@x.com", subject: "Hi", text: "body",
        attachments: [ { filename: "report.pdf", content: b64_content, content_type: "application/pdf" } ]
      ))
      expect(raw).to include('name="report.pdf"')
      expect(raw).to include('filename="report.pdf"')
    end

    it "uses RFC 2231 continuation for non-ASCII filenames (filename*=UTF-8''…)" do
      raw = decode(described_class.build(
        to: "a@x.com", subject: "Hi", text: "body",
        attachments: [ { filename: "rapport-été.pdf", content: b64_content, content_type: "application/pdf" } ]
      ))
      expect(raw).to include("name*=UTF-8''rapport-%C3%A9t%C3%A9.pdf")
      expect(raw).to include("filename*=UTF-8''rapport-%C3%A9t%C3%A9.pdf")
      expect(raw).not_to include('filename="rapport-été.pdf"')
    end

    it "emits Content-ID when supplied (inline images via `cid:` references)" do
      raw = decode(described_class.build(
        to: "a@x.com", subject: "Hi", html: "<img src='cid:logo'>",
        attachments: [ { filename: "logo.png", content: b64_content,
                         content_type: "image/png", content_id: "logo", disposition: "inline" } ]
      ))
      expect(raw).to include("Content-ID: <logo>")
      expect(raw).to include("Content-Disposition: inline; filename=\"logo.png\"")
    end
  end

  describe "Subject — long non-ASCII string chunks across multiple encoded-words" do
    it "splits into multiple `=?UTF-8?B?…?=` words rather than one giant one" do
      long_subject = "héllo " * 25     # ~150 chars of mixed UTF-8
      raw = decode(described_class.build(to: "a@x.com", subject: long_subject, text: "body"))
      # Should produce more than one encoded-word
      expect(raw.scan(/=\?UTF-8\?B\?[^?]+\?=/).length).to be > 1
    end
  end

  describe ".build_draft (drafts permit empty bodies)" do
    it "produces valid MIME with no recipients and no body" do
      encoded = described_class.build_draft
      raw = Base64.urlsafe_decode64(encoded)
      expect(raw).to include("Content-Type: text/plain")
      expect(raw).to include("Subject: ")
    end

    it "permits a To list with no body" do
      raw = Base64.urlsafe_decode64(described_class.build_draft(to: "a@x.com", subject: "draft"))
      expect(raw).to include("To: a@x.com")
      expect(raw).to include("Subject: draft")
    end
  end
end
