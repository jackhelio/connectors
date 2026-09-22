# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_09_22_120000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "connectors_credential_shares", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "grant_id", null: false
    t.uuid "principal_id", null: false
    t.string "principal_type", null: false
    t.string "role", default: "viewer", null: false
    t.datetime "updated_at", null: false
    t.index [ "grant_id", "principal_type", "principal_id" ], name: "idx_connectors_credential_shares_uniq", unique: true
    t.index [ "grant_id" ], name: "index_connectors_credential_shares_on_grant_id"
    t.index [ "principal_type", "principal_id" ], name: "idx_connectors_credential_shares_lookup"
  end

  create_table "connectors_grants", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "connector_key", null: false
    t.datetime "created_at", null: false
    t.text "credentials"
    t.string "display_name"
    t.datetime "expires_at"
    t.string "external_account_id"
    t.string "external_ref"
    t.boolean "is_managed", default: false, null: false
    t.datetime "last_used_at"
    t.uuid "owner_id", null: false
    t.string "owner_type", null: false
    t.jsonb "static_data", default: {}, null: false
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index [ "connector_key", "external_account_id" ], name: "index_connectors_grants_on_external_account", where: "(external_account_id IS NOT NULL)"
    t.index [ "connector_key" ], name: "index_connectors_grants_on_connector_key"
    t.index [ "expires_at" ], name: "index_connectors_grants_on_expires_at"
    t.index [ "external_ref" ], name: "index_connectors_grants_on_external_ref", where: "(external_ref IS NOT NULL)"
    t.index [ "owner_type", "owner_id", "connector_key" ], name: "index_connectors_grants_on_owner_and_connector"
    t.index [ "owner_type", "owner_id" ], name: "index_connectors_grants_on_owner"
    t.index [ "status" ], name: "index_connectors_grants_on_status"
  end

  create_table "connectors_poll_states", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.jsonb "data", default: {}, null: false
    t.uuid "grant_id", null: false
    t.string "instance_key", null: false
    t.datetime "updated_at", null: false
    t.index [ "grant_id", "instance_key" ], name: "index_connectors_poll_states_on_grant_id_and_instance_key", unique: true
    t.index [ "grant_id" ], name: "index_connectors_poll_states_on_grant_id"
  end

  create_table "connectors_webhook_events", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "connector_key", null: false
    t.datetime "created_at", null: false
    t.text "error_message"
    t.string "external_event_id"
    t.uuid "grant_id", null: false
    t.jsonb "headers", default: {}, null: false
    t.jsonb "payload"
    t.datetime "processed_at"
    t.jsonb "query", default: {}, null: false
    t.text "raw_body"
    t.datetime "received_at", null: false
    t.text "signature"
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.string "webhook_name", default: "default", null: false
    t.index [ "connector_key", "external_event_id" ], name: "idx_connectors_webhook_events_idempotency", unique: true, where: "(external_event_id IS NOT NULL)"
    t.index [ "connector_key" ], name: "index_connectors_webhook_events_on_connector_key"
    t.index [ "grant_id" ], name: "index_connectors_webhook_events_on_grant_id"
    t.index [ "status" ], name: "index_connectors_webhook_events_on_status"
    t.index [ "webhook_name" ], name: "index_connectors_webhook_events_on_webhook_name"
  end

  create_table "owners", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name"
    t.datetime "updated_at", null: false
  end

  add_foreign_key "connectors_credential_shares", "connectors_grants", column: "grant_id"
  add_foreign_key "connectors_poll_states", "connectors_grants", column: "grant_id"
  add_foreign_key "connectors_webhook_events", "connectors_grants", column: "grant_id"
end
