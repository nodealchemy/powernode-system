# frozen_string_literal: true

# Seeds the operator-path intervention policy for the NodeInstance cordon-only
# mode (IMP-0467eee9fc57). One category, `system.instance_cordon`, gates BOTH
# Ai::Tools::SystemFleetTool verbs — system_cordon_instance and
# system_uncordon_instance — so one operator-tuned row governs taking a node
# out of scheduling and putting it back.
#
# WHY A ROW AT ALL, when the declared verb equals the unmatched default. A
# DECLARED category with no row resolves `require_approval` either way, so the
# gate behaves correctly without this seed — but the Autonomy modal's
# node_lifecycle section is ROW-driven (System::AutonomyActions
# #autonomy_actions_by_domain builds its sections and per-action rows from
# resolved policies), so with no writer the operator has nothing to see and
# nothing to tune. The declaration is the gate; this seed is the control.
#
# GLOBAL (operator) scope, like the volume-snapshot and instance-pool operator
# sets: the MCP verbs are called by a user or an agent and
# Ai::InterventionPolicyService resolves both against scope-"global" rows. No
# AGENT-scope row — no sensor lane routes a cordon, so it would be a control
# nothing reads.
#
# THE OTHER WRITER is System::Governance::PolicyReconciler, which creates
# declared rows an ALREADY-BOOTED install is missing (db:seed is first-boot
# only). Both are pinned in
# spec/db/seeds/system_instance_cordon_operator_policies_spec.rb.

puts "\n  Seeding instance cordon policies..."

admin_account = Account.first
unless admin_account
  puts "  ⚠️  No account found — skipping instance cordon policies"
  return
end

cordon_policies = System::Governance::PolicyDeclarations::INSTANCE_CORDON_OPERATOR_POLICIES

changed = 0
cordon_policies.each do |action_category, policy_type|
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

puts "  ✅ Instance cordon policies (operator): #{changed} created/updated " \
     "(#{cordon_policies.size} declared)"
