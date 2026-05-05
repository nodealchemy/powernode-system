# frozen_string_literal: true

# Slice 7 — pre-warmed instance pools.
#
# Creates `system_instance_pools` to model an operator-configured pool
# of pre-provisioned NodeInstances that are kept warm (provisioned +
# enrolled + module-attached + daemon-ready) so subsequent operator
# requests for ephemeral instances pop in <30s instead of the cold
# 5-10min provision path.
#
# Adds `instance_pool_id` + `pool_state` columns to system_node_instances
# so any instance can become a pool member; pool_state=NULL means the
# instance is operator-owned (legacy, non-pool path) and the pool
# reaper ignores it.
#
# pool_state values:
#   - warming  : provisioned but not yet ready (provider booting / agent enrolling)
#   - ready    : fully operational, awaiting acquisition
#   - claimed  : acquired by operator, no longer in pool rotation
#   - draining : pool downsizing or operator drain — terminate after current usage
#   - errored  : provider failure or health check failed; reaper will recycle
class CreateSystemInstancePools < ActiveRecord::Migration[8.0]
  def change
    create_table :system_instance_pools, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :account, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :node_template,
                   type: :uuid, null: false,
                   foreign_key: { to_table: :system_node_templates, on_delete: :restrict }

      t.string :name, null: false
      t.text :description

      # Pool sizing parameters (operator-configured).
      t.integer :target_size, null: false, default: 1
      t.integer :min_size, null: false, default: 0
      t.integer :max_size, null: false, default: 10

      # Lifecycle class scoped to this pool — pre-warmed pools are only
      # meaningful for ephemeral or spot instances; persistent instances
      # have no use case for warm pools (they outlive any pool's
      # rotation cadence).
      t.string :lifecycle_class, null: false, default: "ephemeral"

      # Pool status — `active` is the default operational state. `paused`
      # halts the reaper (no replenishment, but acquires still work).
      # `draining` empties the pool gracefully (no replenishment + reaper
      # terminates ready members).
      t.string :status, null: false, default: "active"

      # Reaper bookkeeping — last replenish run timestamp; surfaces
      # "pool stuck not refilling" diagnostics in operator UI.
      t.datetime :last_replenished_at

      # Provider region + instance_type pinning. Required when the
      # pool's template doesn't pin them on its own (operator wants
      # a specific region/type pool independent of the template).
      t.references :provider_region,
                   type: :uuid, null: true,
                   foreign_key: { to_table: :system_provider_regions, on_delete: :nullify }
      t.references :provider_instance_type,
                   type: :uuid, null: true,
                   foreign_key: { to_table: :system_provider_instance_types, on_delete: :nullify }

      # Tags + custom metadata for operator UI / pool selection logic
      # (e.g. tag a pool "ci-fast" and have CI pipelines acquire from
      # that pool by name).
      t.jsonb :metadata, null: false, default: {}

      t.timestamps

      t.check_constraint "target_size >= 0",
                         name: "chk_instance_pools_target_size_nonneg"
      t.check_constraint "min_size >= 0",
                         name: "chk_instance_pools_min_size_nonneg"
      t.check_constraint "max_size >= target_size",
                         name: "chk_instance_pools_max_gte_target"
      t.check_constraint "target_size >= min_size",
                         name: "chk_instance_pools_target_gte_min"
      t.check_constraint "lifecycle_class IN ('ephemeral', 'spot')",
                         name: "chk_instance_pools_lifecycle_class"
      t.check_constraint "status IN ('active', 'paused', 'draining', 'archived')",
                         name: "chk_instance_pools_status"
    end

    # Account-scoped name uniqueness — operators can have a "ci-fast"
    # pool in account A and account B without collision.
    add_index :system_instance_pools, [:account_id, :name], unique: true,
              name: "idx_instance_pools_account_name_unique"
    # Reaper picks pools to replenish via this index ordered by
    # last_replenished_at NULLS FIRST.
    add_index :system_instance_pools, [:status, :last_replenished_at],
              where: "status IN ('active', 'draining')",
              name: "idx_instance_pools_reaper_targets"

    # Pool membership on NodeInstances.
    add_reference :system_node_instances,
                  :instance_pool,
                  type: :uuid, null: true,
                  foreign_key: { to_table: :system_instance_pools, on_delete: :nullify }
    add_column :system_node_instances, :pool_state, :string, null: true
    add_column :system_node_instances, :pool_acquired_at, :datetime, null: true
    add_column :system_node_instances, :pool_warming_started_at, :datetime, null: true

    # Reaper queries: "give me the oldest ready instance in pool X for atomic acquire".
    add_index :system_node_instances, [:instance_pool_id, :pool_state, :pool_warming_started_at],
              where: "instance_pool_id IS NOT NULL",
              name: "idx_node_instances_pool_acquire"

    add_check_constraint :system_node_instances,
                         "pool_state IS NULL OR pool_state IN " \
                         "('warming', 'ready', 'claimed', 'draining', 'errored')",
                         name: "chk_node_instances_pool_state"
    add_check_constraint :system_node_instances,
                         "(instance_pool_id IS NULL AND pool_state IS NULL) OR " \
                         "(instance_pool_id IS NOT NULL AND pool_state IS NOT NULL)",
                         name: "chk_node_instances_pool_consistency"
  end
end
