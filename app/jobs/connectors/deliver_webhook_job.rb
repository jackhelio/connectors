module Connectors
  class DeliverWebhookJob < ApplicationJob
    queue_as :default

    discard_on ActiveJob::DeserializationError

    def perform(event_id)
      event = WebhookEvent.find(event_id)
      return if event.processed? || event.ignored?

      # Pass request data through WebhookContext. Its event and payload_hash
      # accessors also support handlers that consume the persisted event.
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
