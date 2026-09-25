# frozen_string_literal: true

# fc-47 deleted GET /system/platform/health (the Compute › Platform Health
# sub-tab's endpoint), the only thing that checked system.platform.health.read,
# and removed that permission's definition from the engine. Role grants of it
# already in role_permissions name a permission that no longer exists. They
# grant nothing, but they surface as undefined permissions in role listings and
# audits, so this removes them.
#
# Idempotent: a re-run matches no rows. Irreversible: the permission no longer
# exists, so there is nothing meaningful to restore.
class DeleteOrphanedPlatformHealthReadGrants < ActiveRecord::Migration[8.0]
  ORPHANED_PERMISSION = "system.platform.health.read"

  def up
    deleted = exec_delete(
      "DELETE FROM role_permissions WHERE permission_name = #{connection.quote(ORPHANED_PERMISSION)}", "SQL", []
    )
    say "Deleted #{deleted} orphaned role_permissions grant(s) for the removed #{ORPHANED_PERMISSION}"
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
