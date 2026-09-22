class CreateConnectorsPollStates < ActiveRecord::Migration[8.1]
  def change
    create_table :connectors_poll_states, id: :uuid do |t|
      t.references :grant, type: :uuid, null: false, foreign_key: { to_table: :connectors_grants }
      t.string :instance_key, null: false
      t.jsonb :data, null: false, default: {}
      t.timestamps
    end

    add_index :connectors_poll_states, [ :grant_id, :instance_key ], unique: true
  end
end
