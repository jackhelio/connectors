class CreateConnectorsCredentialShares < ActiveRecord::Migration[8.1]
  # One credential share per (grant, principal) pair. The host defines
  # principal types, such as User, Team or Project, through its resolver.
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
