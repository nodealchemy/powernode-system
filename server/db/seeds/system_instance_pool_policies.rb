# frozen_string_literal: true

# Seeds intervention policies for instance pool operations (slice 7 — warm
# pools that pre-provision instances for fast acquisition). These were 100%
# ungated before 2026-05-10 — pool create/delete/drain operations would
# auto-execute regardless of operator intent.
#
# Scoped to the Fleet Autonomy agent (the most sensible owner — pools are
# fleet capacity machinery) AND seeded as global so manual ops are covered too.

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

# Manual scope (operators clicking Settings buttons in the UI)
count = upsert_pool_policies_for_scope!(admin_account, pool_policies, scope: "global")
puts "  ✅ Instance pool policies (manual): #{count} created/updated"

# Agent scope (Fleet Autonomy creating pools as part of capacity expansion)
fleet_agent = ::Ai::Agent.resolve_for(admin_account.id, name: "Fleet Autonomy", agent_type: "monitor")
if fleet_agent
  count = upsert_pool_policies_for_scope!(admin_account, pool_policies, scope: "agent", agent: fleet_agent)
  puts "  ✅ Instance pool policies (Fleet Autonomy): #{count} created/updated"
else
  puts "  ⚠️  Fleet Autonomy agent not found — agent-scoped pool policies skipped"
end
