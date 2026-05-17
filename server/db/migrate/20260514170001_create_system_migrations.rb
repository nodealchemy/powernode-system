# frozen_string_literal: true

# P5.1 — system_migrations: cross-peer record transfer operations.
# Each row represents one Migration plan + execution. Two operations
# with opposite UUID semantics (Locked Decision #14):
#
#   - duplicate: create new record(s) at destination with FRESH UUIDv7s;
#                source UUID preserved in payload.metadata.duplicated_from
#                lineage. The two records are independent from creation.
#   - migrate:   move record(s) to destination, UUID preserved; source
#                deletes after destination acks. Only one peer holds the
#                UUID at any instant.
#
# Plan reference: Decentralized Federation §F + P5.1 + LD #14.
class CreateSystemMigrations < ActiveRecord::Migration[8.0]
  def change
    create_table :system_migrations, id: :uuid do |t|
      t.references :account,
        type: :uuid, null: false,
        foreign_key: { to_table: :accounts, on_delete: :cascade }

      # When set, the migration targets a remote federation peer. nil
      # means an intra-account migration (e.g., between Orgs on the
      # same platform — deferred to P9 D7 but the column is here for
      # forward compat).
      t.references :destination_peer,
        type: :uuid, null: true,
        foreign_key: { to_table: :sdwan_federation_peers, on_delete: :restrict }

      # For migrations originating from a remote peer (we are the destination):
      t.uuid :source_account_id

      t.string :operation, null: false, limit: 16

      # The root record being migrated. Walking begins here.
      t.string :root_resource_kind, null: false, limit: 64
      t.uuid   :root_resource_id,   null: false

      t.string  :status, null: false, default: "planned", limit: 16
      t.boolean :dry_run, null: false, default: false

      t.jsonb :plan_summary,  null: false, default: {}
      t.jsonb :conflict_log,  null: false, default: []
      t.jsonb :audit_log,     null: false, default: []
      t.jsonb :metadata,      null: false, default: {}

      t.references :initiated_by_user,
        type: :uuid, null: true,
        foreign_key: { to_table: :users, on_delete: :nullify }

      t.datetime :started_at
      t.datetime :completed_at
      t.datetime :failed_at
      t.datetime :cancelled_at
      t.string   :error_message, limit: 2048

      t.timestamps
    end

    add_index :system_migrations, %i[account_id status]
    add_index :system_migrations, :operation
    add_index :system_migrations, %i[root_resource_kind root_resource_id]

    add_check_constraint :system_migrations,
      "operation IN ('duplicate', 'migrate')",
      name: "migrations_operation_enum"

    add_check_constraint :system_migrations,
      "status IN ('planned', 'validating', 'transferring', 'conflict', 'applying', 'completed', 'failed', 'cancelled')",
      name: "migrations_status_enum"
  end
end
