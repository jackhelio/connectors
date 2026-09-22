module Connectors
  # Request context passed to Connector#handle_webhook. Exposes parsed and
  # raw body, headers, query and webhook group. Delegates payload aliases
  # and exposes the persisted WebhookEvent for existing handlers.
  class WebhookContext
    attr_reader :event

    def initialize(event)
      @event = event
    end

    # Parsed body, with an empty hash fallback.
    def body
      @event.payload_hash
    end
    alias payload      body
    alias payload_hash body

    # Raw request body captured on the persisted event, when available.
    def raw_body
      @event.raw_body
    end

    # Request headers with lowercase keys.
    def headers
      @event.headers || {}
    end

    # Query string parameters.
    def query
      @event.query || {}
    end

    # Named webhook group, defaulting to :default.
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
