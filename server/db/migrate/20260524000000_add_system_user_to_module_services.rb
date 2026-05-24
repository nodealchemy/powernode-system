# frozen_string_literal: true

# Adds a `system_user` string column to System::ModuleService so a
# manifest's `services[].user: root` (or `nobody`/`daemon`/etc.) maps
# cleanly to a well-known kernel-managed UID without requiring a
# platform-allocated System::ServiceUser row.
#
# Background: ServiceUser allocates UIDs in 70_000..99_999 (fleet-wide
# uniqueness for module-declared identities). The standard Unix users
# root (0), daemon (1), bin (2), sys (3), nobody (65534) all live
# outside that range — they already exist on every Linux rootfs and
# don't need platform allocation. Before this change, manifests that
# referenced them tripped ManifestImportService's "not declared in
# this manifest and not allocated platform-wide" validation.
#
# Forward-compat: existing rows keep service_user_id; new rows set
# either service_user_id or system_user (model enforces exactly one).
# The /node_api/modules serializer falls back to system_user when
# service_user is nil, so the agent receives the same string-shaped
# `user` field regardless of which path populated it.
class AddSystemUserToModuleServices < ActiveRecord::Migration[8.1]
  def change
    change_table :system_module_services, bulk: true do |t|
      t.string :system_user, limit: 32
      t.index :system_user
    end
    change_column_null :system_module_services, :service_user_id, true
  end
end
