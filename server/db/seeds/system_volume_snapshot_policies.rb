# frozen_string_literal: true

# Seeds the operator-path intervention policy for volume-snapshot operations
# (IMP-e025722ef14e — APO-5 remainder). Today that is one category:
# `system.volume_snapshot_delete`, which destroys a restore point and is gated
# by Ai::Tools::SystemFleetTool's `system_delete_volume_snapshot`.
#
# WHY A ROW AT ALL, when the declared verb equals the unmatched default. A
# DECLARED category with no row resolves `require_approval` either way, so the
# gate behaves correctly without this seed — but the Autonomy modal's storage
# section is ROW-driven (System::AutonomyActions#autonomy_actions_by_domain
# builds its sections and per-action rows from resolved policies), so with no
# writer the operator has nothing to see and nothing to tune. The declaration
# is the gate; this seed is the control.
#
# GLOBAL (operator) scope, like the instance-pool operator set: the MCP verb is
# called by a user or an agent and Ai::InterventionPolicyService resolves both
# against scope-"global" rows. There is deliberately no AGENT-scope row — that
# audience is read by FleetAutonomyService#permitted_actions, i.e. by a
# sensor-routed lane, and no snapshot lane exists yet; the row would be a
# control nothing reads.
#
# THE OTHER WRITER is System::Governance::PolicyReconciler, which creates
# declared rows an ALREADY-BOOTED install is missing (db:seed is first-boot
# only). Both are pinned in
# spec/db/seeds/system_volume_snapshot_operator_policies_spec.rb.

puts "\n  Seeding volume snapshot policies..."

admin_account = Account.first
unless admin_account
  puts "  ⚠️  No account found — skipping volume snapshot policies"
  return
end

# Declared set lives in System::Governance::PolicyDeclarations so the
# reconciler can assert it against a RUNNING database without executing this
# seed.
snapshot_policies = System::Governance::PolicyDeclarations::VOLUME_SNAPSHOT_OPERATOR_POLICIES

changed = 0
snapshot_policies.each do |action_category, policy_type|
  policy = Ai::InterventionPolicy.find_or_initialize_by(
    account: admin_account, action_category: action_category,
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

puts "  ✅ Volume snapshot policies (operator): #{changed} created/updated " \
     "(#{snapshot_policies.size} declared)"
