# frozen_string_literal: true

# Seeds global-scope intervention policies for operator-initiated mutations
# (i.e., System::Task creations + direct controller calls where there's no
# AI agent attribution). Used when AutonomyGate evaluates an action with
# `requested_by: <user>` and `agent: nil`.
#
# Manual ops follow the same gate logic as agent-initiated ones; this seed
# defines the per-account default safety floor for hand-clicked actions
# operators take in the UI. Operators can override per-action in the System
# Settings → Manual Operations tab.

puts "\n  Seeding system manual operation policies..."

admin_account = Account.first
unless admin_account
  puts "  ⚠️  No account found — skipping manual operation policies"
  return
end

def upsert_manual_policies!(account, policies)
  changed = 0
  policies.each do |action_category, policy_type|
    policy = Ai::InterventionPolicy.find_or_initialize_by(
      account: account, action_category: action_category,
      scope: "global", ai_agent_id: nil, user_id: nil
    )
    policy.assign_attributes(
      policy: policy_type, priority: 5, is_active: true,
      conditions: {}, preferred_channels: %w[notification]
    )
    if policy.new_record? || policy.changed?
      policy.save!
      changed += 1
    end
  end
  changed
end

# Declared set now lives in System::Governance::PolicyDeclarations so the
# reconciler can read it WITHOUT executing this seed. That matters: this file
# overwrites tuned verbs and destroy_all's unlisted rows below, which is safe
# only on first boot. See System::Governance::PolicyReconciler.
manual_policies = System::Governance::PolicyDeclarations::MANUAL_OPERATION_POLICIES

count = upsert_manual_policies!(admin_account, manual_policies)
puts "  ✅ Manual operation policies: #{count} created/updated (#{manual_policies.size} total)"

stale = Ai::InterventionPolicy
  .where(account: admin_account, scope: "global", ai_agent_id: nil, user_id: nil)
  .where("action_category LIKE 'system.task.%'")
  .where.not(action_category: manual_policies.keys)
if stale.any?
  stale_count = stale.count
  stale.destroy_all
  puts "  🧹 Cleaned #{stale_count} stale manual operation policies"
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
