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

      # Per-grant scratch storage. Each webhook group uses its own nested hash
      # for independent subscription state.
      t.jsonb    :static_data,         null: false, default: {}

      # Managed credentials use an opaque external_ref resolved by the host.
      # Stored credential values are encrypted by the Grant model.
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
