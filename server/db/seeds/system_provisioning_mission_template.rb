# frozen_string_literal: true

# System extension — Ai::MissionTemplate seed for the AI-driven provisioning
# conversation (M0). One system-wide template named "system_provisioning"
# with 7 phases:
#
#   capture_intent → compose_plan → review_plan (approval gate)
#                  → execute → verify → handoff (approval gate) → adapting
#
# `rejection_mappings` send the user back to compose_plan when the plan
# review is rejected, and back to verify when handoff is rejected. The
# `adapting` phase is sensor-driven and long-lived (no job class — the
# ProjectSloSensor reconciler keeps it alive while the mission is active).
#
# AI-Driven Provisioning plan — slice 4 (M0).
#
# Idempotent: re-running updates the existing template by name without
# duplicating. See system_skills_seed.rb for the same pattern.
#
# Invoke explicitly:
#   cd server && bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/system_provisioning_mission_template.rb')"

puts "\n  Seeding system_provisioning Ai::MissionTemplate..."

# ─────────────────────────────────────────────────────────────────────
# Phase definitions — keep ordering aligned with the plan's table.
# `gate_name` is stored alongside the phase hash so downstream
# orchestrator + UI code can disambiguate which gate is active without
# re-deriving from `key`. (`Ai::MissionTemplate#instantiate_phases`
# whitelists the standard keys; extras like `gate_name` round-trip
# through the JSON column intact.)
# ─────────────────────────────────────────────────────────────────────
PROVISIONING_PHASES = [
  { "order" => 0, "key" => "capture_intent",  "label" => "Capture Brief",
    "requires_approval" => false, "job_class" => "AiProvisioningCaptureIntentJob" },
  { "order" => 1, "key" => "compose_plan",    "label" => "Compose Plan",
    "requires_approval" => false, "job_class" => "AiProvisioningComposePlanJob" },
  { "order" => 2, "key" => "review_plan",     "label" => "Review & Approve",
    "requires_approval" => true,  "job_class" => nil, "gate_name" => "plan_review" },
  { "order" => 3, "key" => "execute",         "label" => "Provision Resources",
    "requires_approval" => false, "job_class" => "AiProvisioningExecuteJob" },
  { "order" => 4, "key" => "verify",          "label" => "Verify SLO Targets",
    "requires_approval" => false, "job_class" => "AiProvisioningVerifyJob" },
  # job_class nil, like review_plan: this is a pure approval gate. A gate phase
  # can never dispatch its job — OrchestratorService#dispatch_phase_job! returns
  # early while awaiting_approval?, and approval advances straight past via
  # handle_approval! -> advance!. The binding was unreachable, and the job it
  # named has been deleted.
  { "order" => 5, "key" => "handoff",         "label" => "Hand Off",
    "requires_approval" => true,  "job_class" => nil,
    "gate_name" => "handoff" },
  { "order" => 6, "key" => "adapting",        "label" => "Continuous Adaptation",
    "requires_approval" => false, "job_class" => nil }
].freeze

# Use find_or_initialize so re-runs update phase definitions cleanly.
template = ::Ai::MissionTemplate.find_or_initialize_by(
  name: "system_provisioning",
  template_type: "system"
)
was_new = template.new_record?

template.assign_attributes(
  account: nil, # system templates are account-agnostic
  description: "AI-driven natural-language provisioning for compute / network / storage stacks. Six phases plus a long-lived adaptation phase driven by ProjectSloSensor.",
  mission_type: "infrastructure",
  status: "active",
  is_default: true,
  version: 1,
  phases: PROVISIONING_PHASES,
  approval_gates: %w[review_plan handoff],
  rejection_mappings: { "review_plan" => "compose_plan", "handoff" => "verify" },
  skill_compositions: {
    # Phase → skills it composes. Reference for the UI rail + audit trail.
    "execute" => %w[provision_full_stack configure_sdwan_for_project attach_storage]
  },
  default_configuration: {
    "brief" => {},
    "plan" => {},
    # F6-04: p99_latency_ms is intentionally NOT a default target — no
    # component emits metric.latency_ms FleetEvents (TelemetryAdapter's
    # transport), so a latency target here would imply violations are
    # detected when they cannot be. Wire a real producer (SDWAN edge
    # probe / agent heartbeat) before re-adding it.
    "slo_targets" => { "availability_pct" => 99.5 },
    "unsupported_slo_targets" => {
      "p99_latency_ms" => "no metric.latency_ms producer wired — latency violations are NOT detected (F6-04)"
    },
    # Per-project scaling bounds (APO 3a). Both are the default window for a
    # project built from this template: scale-OUT may auto-apply inside it, and
    # the scale-in skill clamps a removal at the floor. Scale-IN still takes an
    # operator approval regardless of these numbers.
    #
    # Nothing merges a template's default_configuration into a mission's own
    # configuration, so `Ai::Mission#scaling_bounds` reads this rung off the
    # template directly; a mission that declares its own watch_policies bound
    # overrides it.
    "watch_policies" => { "enabled" => true, "sample_interval_seconds" => 60,
                          "auto_scale_min_replicas" => 1,
                          "auto_scale_max_replicas" => 5 },
    "provisioned_resources" => {}
  }
)
template.save!

puts "    ✓ #{was_new ? 'Created' : 'Updated'} Ai::MissionTemplate \"system_provisioning\" (id=#{template.id}, #{PROVISIONING_PHASES.size} phases, 2 approval gates)"
puts "  Done seeding system_provisioning mission template."
