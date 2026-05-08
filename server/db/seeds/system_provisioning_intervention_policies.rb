# frozen_string_literal: true

# Seeds intervention policies for the M2 adaptive evolution slice of the
# AI-driven provisioning conversation. Six new project.* action_categories
# express the balanced-autonomy intent: low-blast adjustments (replica
# scale, cost trim) auto-apply via notify_and_proceed; high-blast changes
# (cross-region relocate, schema, security) require explicit approval.
#
# Pattern reference: extensions/system/server/db/seeds/fleet_autonomy_agent.rb.
# The Fleet Autonomy agent owns these policies — they are scoped to that
# agent so DecisionEngine routing through FleetAutonomyService#gate_action!
# resolves the right policy for each project.* signal.
#
# Idempotent: re-running updates the existing rows by (action_category, scope,
# ai_agent_id) without duplicating.
#
# Invoke explicitly:
#   cd server && bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/system_provisioning_intervention_policies.rb')"

puts "\n  Seeding system_provisioning intervention policies (M2 — adaptive evolution)..."

admin_account = Account.first
unless admin_account
  puts "  ⚠️  No account found — skipping system_provisioning_intervention_policies seed"
  return
end

# Locate the Fleet Autonomy agent — its presence is a soft prerequisite.
# Without it the policies still apply (scope = global), so we only warn.
fleet_agent = admin_account.ai_agents.find_by(agent_type: "monitor", name: "Fleet Autonomy")
if fleet_agent.nil?
  puts "  ⚠️  Fleet Autonomy agent not seeded — provisioning policies will land at global scope"
end

# Action category → policy mapping. Mirrors the M2 plan.
#
#   project.adapt              — generic SLO-driven adaptation; notify_and_proceed
#   project.cost_control       — cost-driven downscale; notify_and_proceed
#   project.scale_horizontal   — replica adjust within auto-scale ceiling; auto_approve
#   project.relocate           — cross-region move; require_approval
#   project.schema_change      — storage/schema mutation; require_approval
#   project.security_change    — SDWAN / firewall change; require_approval
PROVISIONING_POLICIES = {
  "project.adapt" => "notify_and_proceed",
  "project.cost_control" => "notify_and_proceed",
  "project.scale_horizontal" => "auto_approve",
  "project.relocate" => "require_approval",
  "project.schema_change" => "require_approval",
  "project.security_change" => "require_approval"
}.freeze

scope = fleet_agent ? "agent" : "global"
ai_agent_id = fleet_agent&.id

changed = 0
PROVISIONING_POLICIES.each do |action_category, policy_type|
  policy = Ai::InterventionPolicy.find_or_initialize_by(
    account: admin_account,
    action_category: action_category,
    scope: scope,
    ai_agent_id: ai_agent_id
  )

  conditions = case action_category
  when "project.scale_horizontal"
    # auto_approve gated by the mission's watch_policies budget. The
    # AdaptationProposerService.auto_apply? guard re-checks at decision
    # time. The condition here is informational + machine-readable.
    {
      "trust_tier_minimum" => "monitored",
      "auto_apply_window" => "watch_policies.auto_scale_max_replicas"
    }
  else
    { "trust_tier_minimum" => "monitored" }
  end

  policy.assign_attributes(
    policy: policy_type,
    priority: 10,
    is_active: true,
    conditions: conditions,
    preferred_channels: %w[notification]
  )

  if policy.new_record? || policy.changed?
    policy.save!
    changed += 1
  end
end

puts "  ✅ Provisioning intervention policies: #{changed} created/updated " \
     "(#{PROVISIONING_POLICIES.size} total, scope=#{scope})"
