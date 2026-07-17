# frozen_string_literal: true

# imp 019f6d9a — one-time backfill for current_version_number drift.
#
# Historically NodeModule current-version promotion advanced current_version_id
# via update_columns WITHOUT the denormalized current_version_number, so some
# rows carry a stale number while the id points at a newer version — the drift
# sensor, fleet reconciler/agents, and UI then mis-report which version is
# current. NodeModule#promote_to_version! + the before_save
# :sync_current_version_number guard make future divergence impossible; this
# repairs the rows that already diverged.
#
# Data-only (no DDL). Idempotent: it only touches rows where the two disagree,
# so a re-run affects zero rows. `IS DISTINCT FROM` treats a NULL number as a
# mismatch too.
class BackfillNodeModuleCurrentVersionNumber < ActiveRecord::Migration[8.1]
  def up
    execute(<<~SQL.squish)
      UPDATE system_node_modules m
         SET current_version_number = v.version_number
        FROM system_node_module_versions v
       WHERE m.current_version_id = v.id
         AND m.current_version_number IS DISTINCT FROM v.version_number
    SQL
  end

  def down
    # No-op: correcting a denormalized value to match its source of truth is not
    # meaningfully reversible.
  end
end
