# frozen_string_literal: true

# Seeds intervention policies for the M2 adaptive evolution slice of the
# AI-driven provisioning conversation. Six new project.* action_categories
# express the balanced-autonomy intent: low-blast adjustments (replica
# scale, cost trim) auto-apply via notify_and_proceed; high-blast changes
# (cross-region relocate, schema, security) require explicit approval.
#
# Pattern reference: extensions/system/server/db/seeds/fleet_autonomy_agent.rb.
# These are scoped to the Fleet Autonomy agent here; since HIER-P2DECL their
# OWNER is the Capacity Manager (PolicyDeclarations::CAPACITY_MANAGER_POLICIES,
# `owner: "capacity-manager"` on the three project_* bindings and on
# System::AdaptationGate). Wave 2 re-points this seed with the agent seed;
# until then PolicyReconciler re-homes the rows (PolicyReconciler::FORMER_OWNERS)
# the first boot after the Capacity Manager exists, and the tick gates them
# under Fleet Autonomy as the fallback owner while it does not.
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
fleet_agent = ::Ai::Agent.resolve_for(admin_account.id, name: "Fleet Autonomy", agent_type: "monitor")
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
# Declared set now lives in System::Governance::PolicyDeclarations so the reconciler can
# assert it against a RUNNING database without executing this seed.
PROVISIONING_POLICIES = System::Governance::PolicyDeclarations::PROVISIONING_POLICIES

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

  # Per-category conditions are DECLARED, not branched here: a set-level
  # condition cannot express scale_horizontal's extra auto_apply_window, and a
  # reconciler that rebuilt these rows from the set default alone would flatten
  # it silently.
  conditions = System::Governance::PolicyDeclarations::PROVISIONING_CONDITION_OVERRIDES
               .fetch(action_category, System::Governance::PolicyDeclarations::DEFAULT_TRUST_CONDITIONS)

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
