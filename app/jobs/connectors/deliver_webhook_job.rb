module Connectors
  class DeliverWebhookJob < ApplicationJob
    queue_as :default

    discard_on ActiveJob::DeserializationError

    def perform(event_id)
      event = WebhookEvent.find(event_id)
      return if event.processed? || event.ignored?

      # Phase 7: always hand the connector a `WebhookContext` (n8n parity
      # with `IWebhookFunctions`). The context still exposes `.event` /
      # `.payload_hash` so handlers written against the old `event` arg
      # keep working without changes — the new accessors are additive.
      event.grant.connector.handle_webhook(Connectors::WebhookContext.new(event))
      event.update!(status: :processed, processed_at: Time.current, error_message: nil)

      Connectors.configuration.on_webhook&.call(event)
    rescue => e
      event&.update_columns(
        status:        WebhookEvent.statuses[:failed],
        error_message: "#{e.class}: #{e.message}".byteslice(0, 1000)
      )
      raise
    end
  end
end
