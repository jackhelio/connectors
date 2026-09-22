class CreateConnectorsGrants < ActiveRecord::Migration[8.1]
  def change
    # Everything is uuid — engine-owned primary keys AND polymorphic owner
    # columns. The host (and any other owner type — Team, Workspace, …) is
    # expected to have uuid PKs too. `gen_random_uuid()` is a PG13+ built-in,
    # no extension required.
    create_table :connectors_grants, id: :uuid do |t|
      t.references :owner, polymorphic: true, type: :uuid, null: false
      t.string   :connector_key,       null: false
      t.string   :display_name
      t.text     :credentials                       # encrypted at rest via ActiveRecord::Encryption
      t.integer  :status,              null: false, default: 0
      t.datetime :expires_at
      t.datetime :last_used_at
      t.string   :external_account_id               # provider-side user/account id, if applicable

      # Per-grant scratch storage for webhook subscriptions + polling cursors
      # (n8n parity: `getWorkflowStaticData('node')` at interfaces.ts:1257-1274).
      # Each `webhook_methods` group writes into its own nested hash keyed
      # by the group name, so multi-webhook providers can persist
      # independent state per subscription type.
      t.jsonb    :static_data,         null: false, default: {}

      # External secrets manager integration. A grant either stores its
      # credentials inline (DB-encrypted) OR carries a lightweight
      # `external_ref` that the host's vault adapter resolves on demand.
      # n8n parity: `__overwrittenProperties` on the credential type
      # (interfaces.ts:382), populated by frontend.service.ts:681-705
      # when the external-secrets EE module is active.
      t.string   :external_ref
      t.boolean  :is_managed,          null: false, default: false

      t.timestamps
    end

    add_index :connectors_grants,
              [ :owner_type, :owner_id, :connector_key ],
              name: "index_connectors_grants_on_owner_and_connector"

    add_index :connectors_grants, :connector_key
    add_index :connectors_grants, :expires_at
    add_index :connectors_grants, :status
    add_index :connectors_grants,
              [ :connector_key, :external_account_id ],
              where: "external_account_id IS NOT NULL",
              name: "index_connectors_grants_on_external_account"
    add_index :connectors_grants, :external_ref, where: "external_ref IS NOT NULL"
  end
end
