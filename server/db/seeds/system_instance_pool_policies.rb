# frozen_string_literal: true

# Seeds intervention policies for instance pool operations (slice 7 — warm
# pools that pre-provision instances for fast acquisition). These were 100%
# ungated before 2026-05-10 — pool create/delete/drain operations would
# auto-execute regardless of operator intent.
#
# Scoped to the Fleet Autonomy agent AND seeded as global for the GATED SUBSET
# ONLY, so manual ops are covered exactly where a gate site reads the row — see
# the note at the manual-scope call below (IMP-5a2b801f3386).
#
# OWNER SINCE HIER-P2DECL: the Capacity Manager (PolicyDeclarations::
# CAPACITY_MANAGER_POLICIES carries all eight at the agent shape). This
# first-boot seed still writes them onto Fleet Autonomy — wave 2 re-points it
# with the agent seed — and PolicyReconciler re-homes them onto the Capacity
# Manager (PolicyReconciler::FORMER_OWNERS) the first boot after that agent
# exists, so the rows end up where the gate reads them either way.

puts "\n  Seeding instance pool policies..."

admin_account = Account.first
unless admin_account
  puts "  ⚠️  No account found — skipping instance pool policies"
  return
end

def upsert_pool_policies_for_scope!(account, policies, scope:, agent: nil)
  changed = 0
  policies.each do |action_category, policy_type|
    policy = Ai::InterventionPolicy.find_or_initialize_by(
      account: account, action_category: action_category,
      scope: scope, ai_agent_id: agent&.id, user_id: nil
    )
    policy.assign_attributes(
      policy: policy_type,
      priority: agent ? 10 : 5,
      is_active: true,
      conditions: agent ? { "trust_tier_minimum" => "monitored" } : {},
      preferred_channels: %w[notification]
    )
    if policy.new_record? || policy.changed?
      policy.save!
      changed += 1
    end
  end
  changed
end

# Declared set now lives in System::Governance::PolicyDeclarations so the reconciler can
# assert it against a RUNNING database without executing this seed.
pool_policies = System::Governance::PolicyDeclarations::INSTANCE_POOL_POLICIES

# Manual scope (operators clicking Settings buttons in the UI).
#
# IMP-5a2b801f3386 — the GATED SUBSET, not all eight. A manual-scope row for a
# category no gate site passes renders in the Autonomy modal as a control an
# operator can edit and nothing reads; `system.instance_pool_drain` showed an
# approval requirement no code path enforced. The rationale, and which four
# verbs qualify, is on INSTANCE_POOL_OPERATOR_GATED_KEYS.
#
# This seed never reaches an install that has already booted, so the rows a
# FIRST boot wrote for the other four before that trim are collected once —
# only where the verb still equals what was seeded — by
# db/migrate/20260903033000_collect_inert_instance_pool_operator_policies.rb
# (IMP-57a4b1ef94b3).
operator_policies = System::Governance::PolicyDeclarations::INSTANCE_POOL_OPERATOR_POLICIES

count = upsert_pool_policies_for_scope!(admin_account, operator_policies, scope: "global")
puts "  ✅ Instance pool policies (manual): #{count} created/updated " \
     "(#{operator_policies.size} of #{pool_policies.size} gated)"

# Agent scope (Fleet Autonomy creating pools as part of capacity expansion)
fleet_agent = ::Ai::Agent.resolve_for(admin_account.id, name: "Fleet Autonomy", agent_type: "monitor")
if fleet_agent
  count = upsert_pool_policies_for_scope!(admin_account, pool_policies, scope: "agent", agent: fleet_agent)
  puts "  ✅ Instance pool policies (Fleet Autonomy): #{count} created/updated"
else
  puts "  ⚠️  Fleet Autonomy agent not found — agent-scoped pool policies skipped"
end
