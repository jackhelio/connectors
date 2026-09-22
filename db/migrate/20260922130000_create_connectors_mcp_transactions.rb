class CreateConnectorsMcpTransactions < ActiveRecord::Migration[8.1]
  def change
    %i[mcp_authorizations mcp_interactions].each do |name|
      create_table "connectors_#{name}", id: :uuid do |t|
        t.references :grant, type: :uuid, null: false, foreign_key: { to_table: :connectors_grants, on_delete: :cascade }
        t.string :actor_key, null: false
        t.string :fingerprint, null: false
        t.string :status, null: false, default: "pending"
        t.text :payload, null: false
        t.datetime :expires_at, null: false
        t.timestamps
      end
      add_index "connectors_#{name}", :expires_at
    end
    add_column :connectors_mcp_authorizations, :state_digest, :string, null: false
    add_index :connectors_mcp_authorizations, :state_digest, unique: true
  end
end
