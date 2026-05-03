# frozen_string_literal: true

# Seeds the Fleet Autonomy AI agent, intervention policies (per-action
# default behavior), and the fleet approval chain.
#
# Reference: Golden Eclipse plan M7 — fleet_autonomy_agent seed.
# Mirrors trading_overseer_autonomy.rb shape so trading + fleet decisions
# share the same approval queue UI without code paths diverging.

puts "\n  Seeding Fleet Autonomy agent + policies..."

admin_account = Account.first
unless admin_account
  puts "  ⚠️  No account found — skipping fleet autonomy seed"
  return
end

# ── Helpers ──────────────────────────────────────────────────────────────

def ensure_trust_score!(account, agent)
  return if Ai::AgentTrustScore.exists?(agent_id: agent.id)

  Ai::AgentTrustScore.create!(
    account: account, agent: agent, tier: "monitored",
    reliability: 0.7, cost_efficiency: 0.7, safety: 0.85,
    quality: 0.7, speed: 0.7, overall_score: 0.74
  )
end

def upsert_fleet_policies!(account, agent, policies)
  return 0 unless agent

  changed = 0
  policies.each do |action_category, policy_type|
    policy = Ai::InterventionPolicy.find_or_initialize_by(
      account: account,
      action_category: action_category,
      scope: "agent",
      ai_agent_id: agent.id
    )
    policy.assign_attributes(
      policy: policy_type,
      priority: 10,
      is_active: true,
      conditions: { "trust_tier_minimum" => "monitored" },
      preferred_channels: %w[notification]
    )
    if policy.new_record? || policy.changed?
      policy.save!
      changed += 1
    end
  end
  changed
end

# ── Fleet Autonomy agent ─────────────────────────────────────────────────
#
# Ai::Agent requires a creator (User) + provider (Ai::Provider) at create
# time. Pick the admin user + first available provider as defaults; an
# operator can swap the provider later in the agents UI.

creator  = admin_account.users.find_by(email: "admin@powernode.org") || admin_account.users.first
provider = ::Ai::Provider.first
unless creator && provider
  puts "  ⚠️  Need at least one user + Ai::Provider before seeding the Fleet Autonomy agent — skipping"
  return
end

fleet_agent = admin_account.ai_agents.find_or_initialize_by(
  name: "Fleet Autonomy",
  agent_type: "monitor"
)
fleet_agent.assign_attributes(
  description: "Self-improving fleet reconciler — runs sensors, gates actions, extracts learnings",
  status: "active",
  autonomy_config: { "interval_seconds" => 60, "extension" => "system" }
)
# Only set creator/provider on new records — preserves operator overrides on existing rows.
if fleet_agent.new_record?
  fleet_agent.creator  = creator
  fleet_agent.provider = provider
end
fleet_agent.save!
ensure_trust_score!(admin_account, fleet_agent)
puts "  ✅ Fleet Autonomy agent: #{fleet_agent.previously_new_record? ? 'created' : 'updated'}"

# ── Default action policies (mirrors plan M7 vocabulary) ────────────────

fleet_policies = {
  # Routine + reversible (auto)
  "system.cert_rotate"             => "auto_approve",

  # Read/notify
  "system.module_assign"           => "notify_and_proceed",
  "system.instance_reboot"         => "notify_and_proceed",

  # Sensitive — require_approval
  "system.instance_reprovision"    => "require_approval",
  "system.instance_terminate"      => "require_approval",
  "system.cert_revoke"             => "require_approval",
  "system.module_promote_to_live"  => "require_approval",
  "system.fleet_rolling_upgrade"   => "require_approval",
  "system.cve_remediate"           => "require_approval",
  "system.region_expansion"        => "require_approval",
  "system.capacity_resize"         => "require_approval"
}

count = upsert_fleet_policies!(admin_account, fleet_agent, fleet_policies)
puts "  ✅ Fleet Autonomy policies: #{count} created/updated (#{fleet_policies.size} total)"

# Clean stale policies for actions removed from this agent
stale = Ai::InterventionPolicy
  .where(account: admin_account, ai_agent_id: fleet_agent.id, scope: "agent")
  .where.not(action_category: fleet_policies.keys)
if stale.any?
  stale_count = stale.count
  stale.destroy_all
  puts "  🧹 Cleaned #{stale_count} stale Fleet Autonomy policies"
end

# ── Fleet Approval Chain ────────────────────────────────────────────────
# Single-step chain for fleet require_approval actions. The trading approval
# queue UI surfaces fleet requests via source_type="system_fleet" without UI
# changes.

fleet_chain = Ai::ApprovalChain.find_or_initialize_by(
  account: admin_account,
  name: "Fleet Autonomy Actions"
)
fleet_chain.assign_attributes(
  trigger_type: "autonomy_action",
  status: "active",
  is_sequential: true,
  timeout_action: "reject",
  timeout_hours: 4,
  steps: [{
    "name" => "Fleet Operator Approval",
    "approvers" => ["*"],
    "required_approvals" => 1
  }]
)
if fleet_chain.new_record? || fleet_chain.changed?
  fleet_chain.save!
  puts "  ✅ Fleet Approval Chain: created/updated"
else
  puts "  ✅ Fleet Approval Chain: already up to date"
end
