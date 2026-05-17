# frozen_string_literal: true

# Adds `account_id` directly to system_node_instances. NodeInstance
# previously inherited its tenant scope only through the parent Node,
# which made every cross-cutting query JOIN system_nodes and forced
# callers to remember NodeInstance is the outlier in the platform's
# account-scoped resource hierarchy.
#
# Aligning NodeInstance with the rest of the platform:
#   - sibling tables (system_provider_volumes, system_acme_certificates,
#     system_storage_migrations, system_federation_peers, ...) all
#     carry account_id directly
#   - controllers/services can use a single-table .where(account_id: ...)
#   - multi-tenant defense-in-depth strengthens (the FK exists on every
#     row; cross-tenant exposure requires a deliberate code-level bug)
#
# The model adds a before_validation callback that inherits account_id
# from the parent Node, so callers can omit it when creating.
#
# Plan reference: P8.3 follow-up.
class AddAccountIdToSystemNodeInstances < ActiveRecord::Migration[8.1]
  def up
    add_reference :system_node_instances, :account,
                  type: :uuid, null: true, foreign_key: { to_table: :accounts }

    # Backfill from the parent node. One UPDATE statement; UUIDs are
    # immutable so a missed row would mean an orphaned instance which
    # would be a bug regardless.
    execute(<<~SQL)
      UPDATE system_node_instances ni
      SET    account_id = n.account_id
      FROM   system_nodes n
      WHERE  ni.node_id = n.id
        AND  ni.account_id IS NULL
    SQL

    # Any instances still null at this point are detached from a node —
    # that's a pre-existing data integrity issue, not this migration's
    # concern. Surface it loudly so an operator can investigate before
    # we tighten the constraint.
    orphans = execute("SELECT COUNT(*) FROM system_node_instances WHERE account_id IS NULL").first
    raise "#{orphans['count']} orphaned NodeInstance rows (no parent node); resolve before tightening NOT NULL" if orphans["count"].to_i.positive?

    change_column_null :system_node_instances, :account_id, false
  end

  def down
    remove_reference :system_node_instances, :account, foreign_key: true
  end
end
