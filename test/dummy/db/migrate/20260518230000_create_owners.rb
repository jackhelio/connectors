class CreateOwners < ActiveRecord::Migration[8.1]
  def change
    create_table :owners, id: :uuid do |t|
      t.string :name
      t.timestamps
    end
  end
end
