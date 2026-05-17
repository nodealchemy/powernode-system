# frozen_string_literal: true

# Persistent record of an in-flight storage migration — moving a
# stateful component's data from one ProviderVolume to another while
# preserving the (deployment, role) binding. Distinct from
# System::Migration (which moves records across federated peers); a
# storage migration is single-platform, single-instance, swap-volume
# semantics.
#
# Plan reference: E7.1 (migration execution orchestration).
class CreateSystemStorageMigrations < ActiveRecord::Migration[8.1]
  def change
    create_table :system_storage_migrations, id: :uuid do |t|
      t.references :account, null: false, type: :uuid,
                              foreign_key: { to_table: :accounts }
      t.references :node_instance, null: false, type: :uuid,
                                    foreign_key: { to_table: :system_node_instances }
      t.references :source_volume, null: false, type: :uuid,
                                    foreign_key: { to_table: :system_provider_volumes }
      t.references :target_volume, null: false, type: :uuid,
                                    foreign_key: { to_table: :system_provider_volumes }
      t.references :initiated_by_user, type: :uuid,
                                        foreign_key: { to_table: :users }, null: true

      t.string :role,            null: false, limit: 64
      t.string :status,          null: false, limit: 32, default: "planned"
      t.string :source_subpath,  null: true,  limit: 512
      t.string :target_subpath,  null: true,  limit: 512
      t.string :snapshot_subpath, null: true, limit: 512
      t.string :error_message,   null: true

      t.jsonb :plan,      null: false, default: {}
      t.jsonb :audit_log, null: false, default: []
      t.jsonb :metadata,  null: false, default: {}

      # Bytes copied / verified — populated by the agent during sync.
      t.bigint :bytes_total,    null: true
      t.bigint :bytes_copied,   null: true
      t.bigint :bytes_verified, null: true

      t.datetime :approved_at,  null: true
      t.datetime :started_at,   null: true
      t.datetime :completed_at, null: true
      t.datetime :failed_at,    null: true
      t.datetime :cancelled_at, null: true

      t.timestamps
    end

    add_index :system_storage_migrations, :status
    add_index :system_storage_migrations, %i[account_id status]
    add_check_constraint :system_storage_migrations, "source_volume_id <> target_volume_id",
                          name: "storage_migration_source_ne_target"
  end
end
