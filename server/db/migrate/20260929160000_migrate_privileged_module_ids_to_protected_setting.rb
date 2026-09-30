# frozen_string_literal: true

# IMP-06cf44531256 — move the privileged-module grant into its protected
# setting, with an audit row, and remove the two places it used to live.
#
# The node API's privileged_module_ids (the list the agent's privileged gate
# honours) was read from accounts.settings["privileged_module_ids"], falling
# back to an unregistered SiteSetting of the same name. Nothing registered
# either, so the only way to grant a module unconfined operation was a direct
# SQL write (done once, 2026-09-23, with no audit trail). It is now the
# PROTECTED setting System::PrivilegedModuleAllowlist::SETTING_KEY, written only
# through the human-only site_setting_set_protected.
#
# The move itself lives in System::PrivilegedAllowlistLegacyMigration so it can
# be RE-RUN: this migration is stamped in schema_migrations whether or not the
# move succeeded, and it must never raise at boot (a raising data migration
# crash-loops rails there, and rails serves the node API the agents poll). If the
# move fails or leaves an unresolved entry, the legacy grant is untouched and
# the node API keeps a critical fleet event alive
# (system.privileged_allowlist_migration_pending) until an operator re-runs
# `rake system:privileged_allowlist:migrate_legacy`.
#
# Data-only, idempotent, not reversible.
class MigratePrivilegedModuleIdsToProtectedSetting < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    result = ::System::PrivilegedAllowlistLegacyMigration.call
    return if result.ok? && !result.legacy_remaining

    say "#{self.class.name}: legacy grant NOT fully moved (#{result.error || 'unresolved entries'}); " \
        "re-run: rake system:privileged_allowlist:migrate_legacy", true
  rescue StandardError => e
    say "#{self.class.name}: NOT migrated (#{e.class}); the legacy grant is untouched; " \
        "re-run: rake system:privileged_allowlist:migrate_legacy", true
    Rails.logger.error("[#{self.class.name}] not migrated, legacy grant left in place: #{e.class}: #{e.message}")
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "a grant cannot be moved back into an unaudited legacy location; " \
          "write #{::System::PrivilegedModuleAllowlist::SETTING_KEY} through site_setting_set_protected instead"
  end
end
