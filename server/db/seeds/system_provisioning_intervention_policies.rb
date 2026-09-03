# frozen_string_literal: true

# Seeds intervention policies for the M2 adaptive evolution slice of the
# AI-driven provisioning conversation. Six new project.* action_categories
# express the balanced-autonomy intent: low-blast adjustments (replica
# scale, cost trim) auto-apply via notify_and_proceed; high-blast changes
# (cross-region relocate, schema, security) require explicit approval.
#
# Pattern reference: extensions/system/server/db/seeds/fleet_autonomy_agent.rb.
# Since HIER-P2DECL their OWNER is the Capacity Manager
# (PolicyDeclarations::CAPACITY_MANAGER_POLICIES, `owner: "capacity-manager"`
# on the three project_* bindings and on System::AdaptationGate), and since
# HIER-P2B this seed writes them onto that agent directly.
#
# WHY THE RE-POINT WAS NOT OPTIONAL. PolicyReconciler::FORMER_OWNERS re-homes
# a row off Fleet Autonomy only when the OWNER IS MISSING THAT CATEGORY —
# `reconcile!` answers `present` and skips `rehomable_row` for a category the
# owner already has. `db/seeds/system_capacity_manager_agent.rb` runs at
# position 9 of SYSTEM_SEED_FILES and writes every declared row; this file
# runs at 19. So while it resolved Fleet Autonomy, a FRESH install ended up
# with six active agent-scope `project.*` rows on an agent that declares none
# of them — including an `auto_approve` row for `project.scale_horizontal` —
# and nothing would ever re-home or collect them. An ESTABLISHED install is
# unaffected: db:seed is first-boot only, and there the owner starts empty so
# the reconciler re-homes as before. Pinned by
# spec/services/system/fleet/routed_lane_policy_coherence_spec.rb ("leaves no
# Fleet Autonomy duplicate for a category the Capacity Manager owns").
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

# Locate the OWNING agent — its presence is a soft prerequisite. Without it
# the policies still apply (scope = global), so we only warn. The name is a
# LITERAL on purpose: it is the shape
# spec/controllers/api/v1/system/autonomy_agent_pivot_spec.rb parses to build
# its seeded-agent oracle, and a name that derivation cannot read is dropped
# from it silently.
owner_agent = ::Ai::Agent.resolve_for(admin_account.id, name: "Capacity Manager", agent_type: "monitor")
if owner_agent.nil?
  puts "  ⚠️  Capacity Manager agent not seeded — provisioning policies will land at global scope"
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

scope = owner_agent ? "agent" : "global"
ai_agent_id = owner_agent&.id

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
