# frozen_string_literal: true

# IMP-19843220ac68 — retire `system_nodes.lifecycle_class`, step 1 of 2.
#
# The column was written by exactly two application paths —
# `InstancePoolService#provision_warming_member!` (copying
# `pool.lifecycle_class` onto each member) and `PlatformDeploymentOrchestrator`
# (writing the literal default "persistent") — and read by nothing: no
# serializer, no REST or MCP parameter, no GitOps kind, no symbol in the Go
# agent, no frontend reference. It recorded no operator intent, because no
# surface ever permitted one to be expressed.
#
# WHY THE DEFAULT MOVES IN THE SAME CHANGE THAT STOPS THE WRITES. The column was
# NOT NULL DEFAULT 'persistent'. Dropping only the writes would have left every
# pool member — `ephemeral` or `spot` by construction, since
# `System::InstancePool` is CHECK-constrained to those two — silently falling
# back to `persistent`, which is not merely unread but WRONG. Making the column
# nullable with a NULL default makes "unset" representable, so the retired
# column stops asserting anything.
#
# EXISTING ROWS ARE LEFT ALONE on purpose. Backfilling them to NULL would
# destroy the only record of which historical Nodes came from an ephemeral or
# spot pool, and nothing reads the column, so there is no correctness pressure
# to do it. New rows simply stop acquiring a value.
#
# NOT IN THIS MIGRATION, deliberately: the column itself, its
# `chk_system_nodes_lifecycle_class` CHECK constraint and its index all remain.
# Dropping them here would open a window in which the still-running previous
# release writes a column this migration has removed. Step 2 drops all three
# after one deploy window.
#
# FORWARD-COMPATIBLE, NOT ROLLBACK-COMPATIBLE — state it plainly, because
# "the previous release keeps working" is only half true and the untrue half is
# the dangerous one. The previous release can run against this schema: its own
# creates still supply a value, its reads are unaffected, and the CHECK is
# three-valued so NULL never violates it. But rows THIS release creates carry
# NULL, and the previous release's model validates
# `inclusion: { in: LIFECYCLE_CLASSES }, allow_nil: false` — so a module
# rollback of the extension (which does NOT revert an applied migration) makes
# any subsequent `node.update!` on such a row raise ActiveRecord::RecordInvalid
# with the misleading message "Lifecycle class is not included in the list".
# There are six live `node.update!` call sites under server/app, including the
# one behind `system_update_node`. A rollback that leaves this migration
# applied must therefore run the compensating backfill FIRST — the same
# pool-resolving statement `down` runs below — or roll the migration back too.
class RetireLifecycleClassDefaultOnSystemNodes < ActiveRecord::Migration[8.1]
  def up
    change_column_default :system_nodes, :lifecycle_class, from: "persistent", to: nil
    change_column_null :system_nodes, :lifecycle_class, true
  end

  # Reversible. NOT NULL cannot be restored over the NULLs written since `up`,
  # so they are backfilled — but NOT with a flat 'persistent', which is the
  # exact silent fallback this change exists to prevent. A pool member's class
  # is still resolvable per row: the member constructor stamps the pool id into
  # `config["instance_pool_id"]`, and a pool is CHECK-constrained to
  # ephemeral|spot, both of which the node CHECK accepts. Rows with no pool —
  # the orchestrator's auto-created Nodes and anything hand-made — take
  # 'persistent', the default this restores, which for them IS the value the
  # removed writer would have supplied.
  def down
    execute(<<~SQL.squish)
      UPDATE system_nodes n
         SET lifecycle_class = COALESCE(
               (SELECT p.lifecycle_class
                  FROM system_instance_pools p
                 WHERE p.id::text = n.config->>'instance_pool_id'),
               'persistent')
       WHERE n.lifecycle_class IS NULL
    SQL
    change_column_null :system_nodes, :lifecycle_class, false
    change_column_default :system_nodes, :lifecycle_class, from: nil, to: "persistent"
  end
end
