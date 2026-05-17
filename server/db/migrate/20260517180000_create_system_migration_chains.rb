# frozen_string_literal: true

# P9.5 — Multi-hop migration chains.
#
# Adds `system_migration_chains` (the chain envelope) + back-pointers
# on `system_migrations` (each hop links to its chain + records its
# position). Single-hop migrations don't use this — they keep
# chain_id=NULL and behave as before. A chain with N hops creates
# one chain row + N Migration rows, executed in sequence.
#
# Per Locked Decision #14 (single home per UUID): at any instant the
# UUID lives on exactly one peer in the chain. If hop K fails after
# hop K-1 succeeded, the chain "stops" at K-1's destination; the
# operator decides whether to retry, abandon, or treat K-1 as the
# final home.
#
# Plan reference: Decentralized Federation P9 backlog + Locked
# Decision #14 (cross-peer UUID uniqueness).
class CreateSystemMigrationChains < ActiveRecord::Migration[8.1]
  def change
    create_table :system_migration_chains, id: :uuid do |t|
      t.references :account, null: false, type: :uuid, foreign_key: { to_table: :accounts }
      t.references :initiated_by_user, type: :uuid,
                                       foreign_key: { to_table: :users }, null: true

      # Ordered list of peer ids the chain hops through, including
      # the local platform as the first entry (NULL = self).
      # ["self", peer_id_b, peer_id_c] means "A → B → C".
      t.jsonb :hop_peer_ids, null: false, default: []

      # Root resource snapshot — kept here so the chain remembers
      # what's being moved even after intermediate hops complete.
      t.string :root_resource_kind, null: false, limit: 64
      t.string :root_resource_id,   null: false, limit: 64

      t.string :operation, null: false, limit: 16  # migrate | duplicate
      t.string :status,    null: false, default: "planned", limit: 32
      t.integer :current_hop_index, null: false, default: 0
      t.integer :total_hops,        null: false, default: 1

      t.jsonb :audit_log, null: false, default: []
      t.jsonb :metadata,  null: false, default: {}

      t.datetime :started_at,   null: true
      t.datetime :completed_at, null: true
      t.datetime :failed_at,    null: true
      t.string   :error_message, null: true

      t.timestamps
    end

    add_index :system_migration_chains, :status,
              name: "idx_migration_chains_status"
    add_index :system_migration_chains, %i[account_id status],
              name: "idx_migration_chains_account_status"
    add_check_constraint :system_migration_chains,
                         "total_hops >= 1",
                         name: "migration_chain_total_hops_positive"
    add_check_constraint :system_migration_chains,
                         "current_hop_index >= 0 AND current_hop_index <= total_hops",
                         name: "migration_chain_hop_index_in_range"

    add_reference :system_migrations, :migration_chain,
                  type: :uuid, null: true,
                  foreign_key: { to_table: :system_migration_chains },
                  index: { name: "idx_migrations_chain" }
    add_column :system_migrations, :chain_position, :integer, null: true
  end
end
