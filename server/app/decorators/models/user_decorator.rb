# frozen_string_literal: true

# System extension associations for the core User model.
# Loaded by the PowernodeSystem engine via config.to_prepare decorator loading.
#
# Account teardown destroys users LAST (Account#run_account_teardown). A user
# who merely CREATED a shared row must not block that, so the nullable
# created-by columns are unlinked. (Rows that carry an account_id are removed
# by the Account decorator's dependents instead.)
User.class_eval do
  has_many :system_created_node_module_versions,
           class_name: "System::NodeModuleVersion", foreign_key: "created_by_id", dependent: :nullify
  has_many :system_initiated_migration_chains,
           class_name: "System::MigrationChain", foreign_key: "initiated_by_user_id", dependent: :nullify
  has_many :system_initiated_storage_migrations,
           class_name: "System::StorageMigration", foreign_key: "initiated_by_user_id", dependent: :nullify
  has_many :system_granted_sdwan_access_grants,
           class_name: "Sdwan::AccessGrant", foreign_key: "granted_by_id", dependent: :nullify
  has_many :system_sdwan_access_grants,
           class_name: "Sdwan::AccessGrant", foreign_key: "user_id", dependent: :destroy
  has_many :system_ops_held_node_instances,
           class_name: "System::NodeInstance", foreign_key: "ops_hold_by_id", dependent: :nullify
  has_many :system_approved_sdwan_route_leaks,
           class_name: "Sdwan::RouteLeak", foreign_key: "approved_by_id", dependent: :nullify
end
