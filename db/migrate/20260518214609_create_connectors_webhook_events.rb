class CreateConnectorsWebhookEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :connectors_webhook_events, id: :uuid do |t|
      t.references :grant, type: :uuid, null: false, foreign_key: { to_table: :connectors_grants }
      t.string   :connector_key,     null: false
      t.string   :external_event_id
      t.jsonb    :payload
      t.text     :signature
      t.integer  :status,            null: false, default: 0
      t.text     :error_message
      t.datetime :received_at,       null: false
      t.datetime :processed_at

      # Full inbound request shape so `IWebhookFunctions`-style handlers
      # have headers (Stripe-Signature etc.), query string, raw body (for
      # replay / signature debugging), and the named webhook group the
      # request hit (`webhookMethods.default` vs `.setup`).
      t.jsonb    :headers,      null: false, default: {}
      t.jsonb    :query,        null: false, default: {}
      t.text     :raw_body
      t.string   :webhook_name, null: false, default: "default"

      t.timestamps
    end

    add_index :connectors_webhook_events, :connector_key
    add_index :connectors_webhook_events, :status
    add_index :connectors_webhook_events, :webhook_name
    add_index :connectors_webhook_events,
              [ :connector_key, :external_event_id ],
              unique: true,
              where:  "external_event_id IS NOT NULL",
              name:   "idx_connectors_webhook_events_idempotency"
  end
end
