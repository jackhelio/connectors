module Connectors
  # One record per inbound webhook from a provider. Persisted before
  # processing so handlers can crash without losing the event, and so the
  # idempotency index (connector_key, external_event_id) drops duplicates.
  class WebhookEvent < ApplicationRecord
    belongs_to :grant, class_name: "Connectors::Grant"

    enum :status, { received: 0, processed: 1, failed: 2, ignored: 3 }, default: :received

    validates :connector_key, :received_at, presence: true

    scope :for_connector, ->(key) { where(connector_key: key.to_s) }
    scope :unprocessed,   -> { where(status: %i[received failed]) }

    def payload_hash
      payload || {}
    end
  end
end
