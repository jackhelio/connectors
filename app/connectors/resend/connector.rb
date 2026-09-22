module Resend
  # Resend (https://resend.com) — transactional email API.
  # https://resend.com/docs/api-reference/emails/send-email
  #
  # Auth: bearer API key (`re_xxx...`). Single credential field; no OAuth.
  # The host creates a Grant out-of-band (admin paste, env-driven seed,
  # whatever your host wires up).
  class Connector < Connectors::Connector
    connector key:               :resend,
              auth:              :api_key,
              base_url:          "https://api.resend.com",
              display_name:      "Resend",
              icon:              "https://cdn.resend.com/brand/resend-icon-blacka.svg",
              icon_color:        "#000000",
              documentation_url: "https://resend.com/docs/api-reference/emails/send-email",
              llm_docs:          "https://resend.com/docs/llms-full.txt",
              instructions:      <<~MD
                **Generate an API key:**

                1. Sign in at [resend.com/api-keys](https://resend.com/api-keys).
                2. Click **Create API Key** and give it a name.
                3. Choose **Full Access** so the "Test connection" button works (Sending Access keys can only `POST /emails`, so they fail every read endpoint).
                4. Copy the key — it starts with `re_` — and paste it below.

                Keys can be revoked any time from the same dashboard.
              MD

    credentials do
      field :api_key,
            type:         "string",
            display_name: "API Key",
            required:     true,
            secret:       true,
            placeholder:  "re_...",
            description:  "Generate at https://resend.com/api-keys."
    end

    # Phase 1 — declarative auth injection (mirrors n8n's HttpBearerAuth at
    # packages/nodes-base/credentials/HttpBearerAuth.credentials.ts:38-45).
    # The `={{...}}` template is resolved per-request from the Grant's
    # credentials hash by `Middleware::AuthenticateGeneric`.
    authenticate type: :generic, properties: {
      headers: { "Authorization" => "=Bearer {{$credentials.api_key}}" }
    }

    # Resend's documented rate limit is 2 requests per second.
    # https://resend.com/docs/api-reference/introduction#rate-limit
    rate_limit 2, per: 1.second

    # ─── actions ─────────────────────────────────────────────────────────
    # Declarative action manifest. Discoverable via /connectors/types/resend
    # → `actions`, invokable via POST /connectors/credentials/:id/actions/send_email.
    # The execute block runs in connector-instance context so we can delegate
    # straight to the existing `send_email` method below (also kept callable
    # directly so spec tests + the workflow executor can use either entry
    # point).
    action :send_email,
           display_name: "Send Email",
           description:  "Send a transactional email through Resend." do
      field :from,
            type:         "string",
            display_name: "From",
            required:     true,
            placeholder:  "Updates <updates@yourdomain.com>",
            description:  "Sender — must be a verified domain in Resend."

      field :to,
            type:         "string",
            display_name: "To",
            required:     true,
            type_options: { multiple_values: true },
            description:  "One or more recipient email addresses."

      field :subject,
            type:         "string",
            display_name: "Subject",
            required:     true

      field :html,
            type:         "string",
            display_name: "HTML Body",
            type_options: { editor: "html" },
            description:  "HTML content. Either html or text is required."

      field :text,
            type:         "string",
            display_name: "Plain Text Body",
            type_options: { rows: 4 },
            description:  "Plain text content. Either html or text is required."

      field :cc,
            type:         "string",
            display_name: "CC",
            type_options: { multiple_values: true }

      field :bcc,
            type:         "string",
            display_name: "BCC",
            type_options: { multiple_values: true }

      field :reply_to,
            type:         "string",
            display_name: "Reply To",
            type_options: { multiple_values: true }

      field :scheduled_at,
            type:         "string",
            display_name: "Scheduled At",
            placeholder:  "in 1 hour",
            description:  "ISO 8601 timestamp OR Resend's natural-language form (e.g. 'in 1 hour')."

      field :tags,
            type:         "json",
            display_name: "Tags",
            description:  "Array of `{name, value}` tag objects."

      field :attachments,
            type:         "json",
            display_name: "Attachments",
            description:  "Array of `{filename, content, path?, content_type?}` objects."

      field :headers,
            type:         "json",
            display_name: "Custom Headers",
            description:  "Hash of header name → value."

      output do
        field :id, type: "string", description: "Resend message id."
      end

      execute do |input|
        send_email(**input.symbolize_keys)
      end
    end

    # "Test connection" hits Resend's `GET /domains` — a cheap, idempotent
    # read that succeeds for any **Full Access** API key.
    #
    # CAVEAT, per Resend's docs (https://resend.com/docs/dashboard/api-keys):
    #   - "Full Access"    keys can create/delete/get/update any resource
    #   - "Sending Access" keys can ONLY POST /emails (send) — no reads
    #
    # Sending-Access keys will return 401 on EVERY GET endpoint Resend
    # exposes, including this one. So this test reliably verifies Full
    # Access keys; Sending-Access keys will always show as "failed" here
    # even when the key works fine for sending. The only way to truly
    # test a Sending-Access key is to actually send an email — which
    # we don't do because it's destructive.
    test_request method: :get, url: "domains"

    # Send a transactional email. Returns Resend's `{ "id" => "..." }` payload
    # so downstream nodes can reference the message id.
    #
    #   from:     "Updates <updates@yourdomain.com>"
    #   to:       "user@example.com" | [ "a@example.com", "b@example.com" ]
    #   reply_to: same — single string OR array
    #
    # `html` and `text` are both optional but at least one must be present —
    # Resend rejects emails with no body. Logical 200-with-error responses
    # are promoted to Connectors::ApiError so the executor records the
    # failure on the Step.
    def send_email(from:, to:, subject:, html: nil, text: nil,
                   cc: nil, bcc: nil, reply_to: nil, tags: nil,
                   scheduled_at: nil, attachments: nil, headers: nil)
      raise Connectors::ApiError.new("send_email requires html or text") if html.nil? && text.nil?

      body = {
        "from"    => from,
        "to"      => Array(to),
        "subject" => subject
      }
      body["html"]         = html              if html
      body["text"]         = text              if text
      body["cc"]           = Array(cc)         if cc
      body["bcc"]          = Array(bcc)        if bcc
      body["reply_to"]     = Array(reply_to)   if reply_to    # Resend expects string[]
      body["tags"]         = tags              if tags
      body["scheduled_at"] = scheduled_at      if scheduled_at
      body["attachments"]  = attachments       if attachments
      body["headers"]      = headers           if headers

      response = client.post("emails", body)
      payload  = response.body

      if response.status >= 400 || resend_error?(payload)
        raise Connectors::ApiError.new(
          "Resend send_email failed: #{resend_error_message(payload) || payload.inspect}",
          status: response.status,
          body:   payload
        )
      end

      payload
    end

    private

    # Resend returns errors in two distinct shapes depending on the failure
    # mode (per Resend's own docs at resend.com/docs/api-reference/errors):
    #
    #   1. Top-level:  `{ "name": "missing_required_field", "message": "...",
    #                     "statusCode": 422 }`
    #   2. Nested:     `{ "error": { "message": "..." } }`
    #
    # A 200-but-failed response carries shape (1). A non-2xx may carry
    # either. Both have to be recognized or we'd silently treat broken
    # sends as successful.
    def resend_error?(payload)
      return false unless payload.is_a?(Hash)
      payload.key?("error") || payload.key?("name") || payload.key?("statusCode")
    end

    def resend_error_message(payload)
      return nil unless payload.is_a?(Hash)
      payload.dig("error", "message") || payload["message"]
    end
  end
end
