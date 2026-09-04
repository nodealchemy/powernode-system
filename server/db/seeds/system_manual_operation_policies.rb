# frozen_string_literal: true

# Seeds the APPROVAL CHAIN that manual operations route to — the chain the
# require_approval verbs in the manual-operations policy set name.
#
# Manual operations are operator-initiated mutations (System::Task creations +
# direct controller calls where there is no AI agent attribution): AutonomyGate
# evaluates them with `requested_by: <user>` and `agent: nil`.
#
# THIS SEED NO LONGER WRITES A POLICY ROW (IMP-28cccf7cee28, proposal §5
# ruling 7). System::Governance::PolicyReconciler is the SINGLE WRITER of the
# declared manual-operations set — its `manual_set` reads the very same
# constant this file used to upsert (PolicyDeclarations::MANUAL_OPERATION_
# POLICIES, at MANUAL_OPERATION_SCOPE with MANUAL_OPERATION_ATTRIBUTES), so
# nothing that was written here is lost; `system_governance_policy_reconcile.rb`
# lands it at the end of `db:seed`, and rails-start.sh / `rails
# system:governance:reconcile` land it on every later boot.
#
# WHAT WAS REMOVED, AND WHY BOTH HALVES HAD TO GO:
#
#   * the upsert `assign_attributes(policy: <declared verb>, ...)` + save,
#     which RESET an operator's deliberately tuned verb back to the seeded
#     default on any re-run;
#   * the `destroy_all` of every global `system.task.*` row whose category was
#     not in the declared list. That is the more dangerous half — a second
#     writer that DELETES silently reverts a reconciled row — and it collected
#     nothing the sanctioned pass does not: registration is DERIVED from the
#     same constant (lib/powernode_system/engine.rb), so an unlisted
#     `system.task.*` category is by construction a DEREGISTERED one, which
#     `system_autonomy_orphan_cleanup.rb` collects at every shape under the
#     owned `system.` namespace — and, unlike the sweep here, refuses to run
#     when the registry looks unpopulated.
#
# The reconciler writes policies and nothing else, so the chain below stays
# with the seeds. Operators still override any manual verb per-action in
# System Settings → Manual Operations; nothing here overwrites that.

puts "\n  Seeding system manual operations approval chain..."

admin_account = Account.first
unless admin_account
  puts "  ⚠️  No account found — skipping manual operations approval chain"
  return
end

# Default chain for manual operations — single-step, anyone with the control
# permission can approve.
manual_chain = Ai::ApprovalChain.find_or_initialize_by(
  account: admin_account,
  name: "Manual Operations"
)
manual_chain.assign_attributes(
  trigger_type: "autonomy_action",
  status: "active",
  is_sequential: true,
  timeout_action: "reject",
  timeout_hours: 4,
  steps: [ {
    "name" => "Operator Approval",
    "approvers" => [ { "type" => "permission", "value" => "system.infra_tasks.control" } ],
    "required_approvals" => 1
  } ]
)
if manual_chain.new_record? || manual_chain.changed?
  manual_chain.save!
  puts "  ✅ Manual Operations Approval Chain: created/updated"
else
  puts "  ✅ Manual Operations Approval Chain: already up to date"
end
