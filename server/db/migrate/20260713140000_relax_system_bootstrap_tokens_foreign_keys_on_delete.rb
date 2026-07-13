# frozen_string_literal: true

# Fixes improvement 019f5cc9 — System::Providers::Proxmox::EnrollmentSeed
# (both #build's fw-cfg path and the Option 3 #render_cicustom path) issues a
# System::BootstrapToken scoped to the just-created NodeInstance BEFORE the
# actual VM-create call reaches the provider. When that provider call fails,
# System::InstancePoolService#provision_warming_member! tears down the
# now-orphaned Node via `node.destroy` (System::Node has_many :node_instances,
# dependent: :destroy, which cascades to the NodeInstance row, then deletes
# the Node row itself) — but BOTH FKs the baseline migration put on
# system_bootstrap_tokens were added with NO on_delete option (Postgres
# default: NO ACTION):
#
#   1. node_instance_id — blocks the cascaded NodeInstance destroy first.
#   2. node_id          — once (1) is fixed, blocks deleting the Node row
#      itself, since the token row still references it. Verified empirically
#      (a spec driving the exact node.destroy! path this fix targets still
#      raised ActiveRecord::InvalidForeignKey with only (1) relaxed). This
#      also affects the plain operator-initiated Nodes#destroy action for
#      ANY node that ever had a bootstrap token issued — not just this
#      pool-provisioning path.
#
# Both currently mask the intended
# `System::InstancePoolService::PoolError, "cloud provision failed: ..."`
# (or, in the controller path, a clean "Failed to delete node" response)
# behind an unrelated integrity-constraint crash.
#
# node_instance_id -> NULLIFY: a BootstrapToken row IS the audit record that
# a token was issued (node_id, purpose, token_hash, expires_at) —
# node_instance_id is already nullable (`belongs_to :node_instance,
# optional: true` on the model; the column itself has no NOT NULL
# constraint either), so nulling the dangling reference on delete preserves
# that audit trail instead of discarding the row outright when its target
# instance is torn down.
#
# node_id -> CASCADE (nullify is not viable here: node_id is NOT NULL at
# both the DB and model level — `t.uuid "node_id", null: false` and
# `belongs_to :node` with no `optional: true`). Once the parent Node itself
# is gone, a token issued in its name has nowhere useful left to be looked
# up from, so cascading its deletion is the only sound choice.
#
# Consistency note: System::NodeInstance::CASCADE_DEPENDENTS already
# documents System::BootstrapToken as an `optional: true` ("nullify —
# audit / lifecycle history retained") dependent, distinct from `optional:
# false` ones like Sdwan::HostBridge that intentionally still block a plain
# .destroy until an operator explicitly calls #cascade_destroy_dependents!
# (force=true). That app-level helper is opt-in / operator-driven
# (NodeInstancesController#destroy); this migration makes the DB match the
# ALREADY-DOCUMENTED "optional = safe to auto-clear" intent for this one
# FK, so ANY caller doing a plain destroy — not just the controller's
# force path — gets the behavior the comment already promised. It does not
# touch the `optional: false` entries, which must keep blocking a plain
# destroy by design.
class RelaxSystemBootstrapTokensForeignKeysOnDelete < ActiveRecord::Migration[8.1]
  def change
    remove_foreign_key :system_bootstrap_tokens, :system_node_instances, column: :node_instance_id
    add_foreign_key :system_bootstrap_tokens, :system_node_instances, column: :node_instance_id, on_delete: :nullify

    remove_foreign_key :system_bootstrap_tokens, :system_nodes, column: :node_id
    add_foreign_key :system_bootstrap_tokens, :system_nodes, column: :node_id, on_delete: :cascade
  end
end
