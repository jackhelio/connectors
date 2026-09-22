class CreateConnectorsCredentialShares < ActiveRecord::Migration[8.1]
  # Phase 9 — credential sharing. One row per (grant, principal) pair.
  # `principal_type` is whatever the host wires through the
  # `Connectors.configuration.principal_resolver` block — it's almost
  # always "User" but EE hosts may share to "Team" / "Project" / etc.
  #
  # n8n parity: enterprise/credentials.controller.ee.ts handles
  # `PUT /credentials/:id/share` + `/transfer`. We give the engine the
  # SAME storage shape without baking in host-app concepts.
  def change
    create_table :connectors_credential_shares, id: :uuid do |t|
      t.references :grant, type: :uuid, null: false, foreign_key: { to_table: :connectors_grants }
      t.string     :principal_type, null: false
      t.uuid       :principal_id,   null: false
      t.string     :role,           null: false, default: "viewer"

      t.timestamps
    end

    add_index :connectors_credential_shares, [ :grant_id, :principal_type, :principal_id ],
              unique: true,
              name:   "idx_connectors_credential_shares_uniq"
    add_index :connectors_credential_shares, [ :principal_type, :principal_id ],
              name: "idx_connectors_credential_shares_lookup"
  end
end
