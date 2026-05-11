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

manual_policies = {
  # System::Task commands (operator clicks Start/Stop/Terminate on a node)
  "system.task.start"                       => "auto_approve",
  "system.task.stop"                        => "auto_approve",
  "system.task.restart"                     => "auto_approve",
  "system.task.reboot"                      => "auto_approve",
  "system.task.terminate"                   => "require_approval",   # destroys instance
  "system.task.provision"                   => "notify_and_proceed", # creates infra
  "system.task.deprovision"                 => "require_approval",   # destroys infra
  "system.task.associate_public_ip"         => "auto_approve",
  "system.task.disassociate_public_ip"      => "auto_approve",
  "system.task.create_volume"               => "notify_and_proceed",
  "system.task.delete_volume"               => "require_approval",
  "system.task.attach_volume"               => "auto_approve",
  "system.task.detach_volume"               => "notify_and_proceed",
  "system.task.create_snapshot"             => "auto_approve",
  "system.task.delete_snapshot"             => "require_approval",
  "system.task.restore_snapshot"            => "require_approval",   # rolls back state
  "system.task.create_network"              => "notify_and_proceed",
  "system.task.delete_network"              => "require_approval",
  "system.task.sync"                        => "auto_approve",
  "system.task.sync_modules"                => "auto_approve",
  "system.task.apply_config"                => "notify_and_proceed",
  "system.task.build_module"                => "notify_and_proceed",
  "system.task.commit_module"               => "notify_and_proceed",
  "system.task.ssh_command"                 => "require_approval",   # arbitrary code execution
  "system.task.backup"                      => "auto_approve",
  "system.task.restore"                     => "require_approval",   # overwrites state
  "system.task.custom"                      => "require_approval",   # unknown semantics → conservative
}

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
  steps: [{
    "name" => "Operator Approval",
    "approvers" => [{ "type" => "permission", "value" => "system.infra_tasks.control" }],
    "required_approvals" => 1
  }]
)
if manual_chain.new_record? || manual_chain.changed?
  manual_chain.save!
  puts "  ✅ Manual Operations Approval Chain: created/updated"
else
  puts "  ✅ Manual Operations Approval Chain: already up to date"
end
