module Connectors
  # Rich context object passed to `Connector#handle_webhook`. Mirrors n8n's
  # `IWebhookFunctions` (packages/workflow/src/interfaces.ts:1327-1350): the
  # handler gets the parsed body AND headers AND query AND a stable
  # `webhook_name` for multi-webhook providers, without having to thread
  # `event.request_object.foo` through everywhere.
  #
  # Forwards a small set of methods to the underlying `WebhookEvent` so
  # legacy handlers written against `event.payload_hash` keep working — see
  # `Connector#handle_webhook` arity detection in `DeliverWebhookJob`.
  class WebhookContext
    attr_reader :event

    def initialize(event)
      @event = event
    end

    # Parsed body (n8n: `getBodyData()`). Always a Hash — falls back to {}.
    def body
      @event.payload_hash
    end
    alias payload      body
    alias payload_hash body

    # Raw (untouched) request body string. nil when the controller couldn't
    # capture it (form-encoded payloads where Rails consumed the stream).
    # n8n: `getRequestObject().rawBody`.
    def raw_body
      @event.raw_body
    end

    # All request headers (n8n: `getHeaderData()`). Lowercased keys — same
    # normalization n8n applies via `req.headers`.
    def headers
      @event.headers || {}
    end

    # Query string parameters (n8n: `getQueryData()`).
    def query
      @event.query || {}
    end

    # Webhook group name that the request hit — `:default` / `:setup` / etc.
    # n8n: `getWebhookName()`.
    def webhook_name
      (@event.webhook_name || "default").to_sym
    end

    # Provider-side signature header, if present. Convenience accessor —
    # the controller already extracted this off the raw request for the
    # idempotency / signature-verification path.
    def signature
      @event.signature
    end

    # The underlying Grant — same as `event.grant`. Lets handlers post back
    # to the provider via `ctx.grant.connector.client`.
    def grant
      @event.grant
    end
  end
end
