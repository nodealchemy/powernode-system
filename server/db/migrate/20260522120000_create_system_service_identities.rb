# frozen_string_literal: true

# Fleet-wide Unix user/group identity tables.
#
# Replaces the per-node "useradd picks whatever UID" model with a
# platform-allocated, globally-unique numeric UID/GID for every Unix
# identity declared by an installed module. Authority shift: the on-node
# agent renders /etc/passwd, /etc/group, /etc/shadow, /etc/gshadow
# authoritatively from these tables — apt-created identities that aren't
# declared by a module are no longer preserved.
#
# Allocation range is 70000..99999 (30k slots). The check constraints
# below are belt-and-suspenders — the allocator enforces the range but
# the DB rejects out-of-band writes too.
#
# Plan reference: ~/.claude/plans/in-the-system-extension-swift-clarke.md
class CreateSystemServiceIdentities < ActiveRecord::Migration[8.1]
  STATES_LIVE  = %w[pending active draining].freeze
  STATES_ALL   = %w[pending active draining removed].freeze
  UID_GID_MIN  = 70_000
  UID_GID_MAX  = 99_999

  def up
    create_table :system_service_groups, id: :uuid do |t|
      t.string   :groupname,   null: false, limit: 32
      t.integer  :gid,         null: false
      t.string   :state,       null: false, limit: 32, default: "active"
      t.datetime :applied_at
      t.datetime :draining_at
      t.datetime :removed_at
      t.jsonb    :metadata,    null: false, default: {}
      t.timestamps
    end
    add_index :system_service_groups, :gid, unique: true
    add_index :system_service_groups, :groupname, unique: true,
              where:  "state IN ('pending','active','draining')",
              name:   "index_system_service_groups_on_groupname_live"
    add_check_constraint :system_service_groups,
                         "gid BETWEEN #{UID_GID_MIN} AND #{UID_GID_MAX}",
                         name: "system_service_groups_gid_in_range"
    add_check_constraint :system_service_groups,
                         "state IN (#{STATES_ALL.map { |s| "'#{s}'" }.join(',')})",
                         name: "system_service_groups_state_enum"

    create_table :system_service_users, id: :uuid do |t|
      t.string  :username, null: false, limit: 32
      t.integer :uid,      null: false
      t.references :primary_group, null: false, type: :uuid,
                                   foreign_key: { to_table: :system_service_groups }
      t.string :shell,  null: false, limit: 128, default: "/usr/sbin/nologin"
      t.string :home,   null: false, limit: 256, default: "/var/empty"
      t.string :gecos,  null: false, limit: 256, default: ""
      t.string :state,  null: false, limit: 32,  default: "active"
      t.datetime :applied_at
      t.datetime :draining_at
      t.datetime :removed_at
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end
    add_index :system_service_users, :uid, unique: true
    add_index :system_service_users, :username, unique: true,
              where:  "state IN ('pending','active','draining')",
              name:   "index_system_service_users_on_username_live"
    add_check_constraint :system_service_users,
                         "uid BETWEEN #{UID_GID_MIN} AND #{UID_GID_MAX}",
                         name: "system_service_users_uid_in_range"
    add_check_constraint :system_service_users,
                         "state IN (#{STATES_ALL.map { |s| "'#{s}'" }.join(',')})",
                         name: "system_service_users_state_enum"

    create_table :system_service_user_group_memberships, id: :uuid do |t|
      t.references :service_user, null: false, type: :uuid, index: false,
                                  foreign_key: { to_table: :system_service_users, on_delete: :cascade }
      t.references :service_group, null: false, type: :uuid, index: false,
                                   foreign_key: { to_table: :system_service_groups, on_delete: :cascade }
      t.timestamps
    end
    add_index :system_service_user_group_memberships,
              %i[service_user_id service_group_id], unique: true,
              name: "index_service_user_group_memberships_unique"
    add_index :system_service_user_group_memberships, :service_group_id,
              name: "index_service_user_group_memberships_group_lookup"

    create_table :system_module_user_declarations, id: :uuid do |t|
      t.references :node_module, null: false, type: :uuid, index: true,
                                 foreign_key: { to_table: :system_node_modules, on_delete: :cascade }
      t.references :service_user, type: :uuid, index: true,
                                  foreign_key: { to_table: :system_service_users, on_delete: :cascade }
      t.references :service_group, type: :uuid, index: true,
                                   foreign_key: { to_table: :system_service_groups, on_delete: :cascade }
      t.timestamps
    end
    add_index :system_module_user_declarations,
              %i[node_module_id service_user_id], unique: true,
              where: "service_user_id IS NOT NULL",
              name:  "index_module_user_declarations_unique_user"
    add_index :system_module_user_declarations,
              %i[node_module_id service_group_id], unique: true,
              where: "service_group_id IS NOT NULL",
              name:  "index_module_user_declarations_unique_group"
    add_check_constraint :system_module_user_declarations,
                         "(service_user_id IS NOT NULL AND service_group_id IS NULL) OR " \
                         "(service_user_id IS NULL AND service_group_id IS NOT NULL)",
                         name: "system_module_user_declarations_exactly_one_target"

    create_table :system_sudoers_grants, id: :uuid do |t|
      t.references :node_module, null: false, type: :uuid, index: false,
                                 foreign_key: { to_table: :system_node_modules, on_delete: :cascade }
      t.references :service_user, null: false, type: :uuid, index: true,
                                  foreign_key: { to_table: :system_service_users, on_delete: :cascade }
      t.string :grant_id,    null: false, limit: 64
      t.string :runas_user,  null: false, default: "root", limit: 32
      t.string :runas_group, limit: 32
      t.jsonb  :commands,    null: false, default: []
      t.jsonb  :flags,       null: false, default: []
      t.string :state,       null: false, limit: 32, default: "active"
      t.timestamps
    end
    add_index :system_sudoers_grants, %i[node_module_id grant_id], unique: true,
              name: "index_system_sudoers_grants_unique_per_module"
    add_check_constraint :system_sudoers_grants,
                         "state IN ('active','removed')",
                         name: "system_sudoers_grants_state_enum"

    # Replace module_services.run_as_user (string) with service_user_id (FK).
    # The column is added nullable for the data step, then tightened.
    add_reference :system_module_services, :service_user,
                  type: :uuid, foreign_key: { to_table: :system_service_users },
                  null: true, index: true

    backfill_module_service_identities!

    change_column_null :system_module_services, :service_user_id, false
    remove_column :system_module_services, :run_as_user
  end

  def down
    add_column :system_module_services, :run_as_user, :string, limit: 64
    remove_reference :system_module_services, :service_user,
                     foreign_key: { to_table: :system_service_users }
    drop_table :system_sudoers_grants
    drop_table :system_module_user_declarations
    drop_table :system_service_user_group_memberships
    drop_table :system_service_users
    drop_table :system_service_groups
  end

  private

  # Walks existing system_module_services rows, allocates a ServiceUser
  # (+ auto-created primary ServiceGroup) for each distinct run_as_user
  # value, and points module_services at the new FK. Existing rows with
  # blank run_as_user fail the not-null constraint added immediately
  # afterwards — those rows MUST be cleaned up in the manifest before
  # this migration can succeed (an unowned service is a manifest bug).
  def backfill_module_service_identities!
    say_with_time "Backfilling system_module_services.service_user_id" do
      ::System::ModuleService.reset_column_information

      ::System::ModuleService.where.not(run_as_user: [ nil, "" ]).find_each do |svc|
        username = svc.run_as_user.strip
        user = ::System::Identity::UserAllocator.allocate!(
          username: username,
          shell:    "/usr/sbin/nologin",
          home:     "/var/lib/#{username}",
          gecos:    ""
        )
        svc.update_columns(service_user_id: user.id)
        ::System::ModuleUserDeclaration.find_or_create_by!(
          node_module_id:  svc.node_module_id,
          service_user_id: user.id
        )
      end

      unowned = ::System::ModuleService.where(service_user_id: nil).count
      raise ActiveRecord::IrreversibleMigration,
            "#{unowned} system_module_services rows have no run_as_user — " \
            "fix the owning manifests to declare a `services[*].user:` before re-running" if unowned.positive?
    end
  end
end
