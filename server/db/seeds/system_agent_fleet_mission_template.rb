# frozen_string_literal: true

# System extension — Ai::MissionTemplate seed for AI/MCP workload substrate L3:
# the agent-fleet orchestration mission. One system-wide template named
# "system_agent_fleet" with 6 phases:
#
#   plan_fleet → review_fleet (approval gate)
#              → provision_fleet → delegate → aggregate → reap
#
# The single gate (review_fleet) is the Bulk-Operation-Safety checkpoint: the
# operator approves provisioning N agent-instances + their capability grants
# BEFORE any instances are created. Every non-gate phase self-advances by
# calling OrchestratorService#advance!(expected_phase:) in its worker_api
# controller action (the verify/handoff pattern), so after approval the chain
# runs provision → delegate → aggregate → reap autonomously.
#
# `rejection_mappings` send the operator back to plan_fleet when the fleet
# review is rejected.
#
# Idempotent: re-running updates the existing template by name without
# duplicating (mirrors system_provisioning_mission_template.rb).
#
# Invoke explicitly:
#   cd server && bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/system_agent_fleet_mission_template.rb')"

puts "\n  Seeding system_agent_fleet Ai::MissionTemplate..."

# ─────────────────────────────────────────────────────────────────────
# Phase definitions. job_class strings name WORKER job classes
# (worker/app/jobs/ai_agent_fleet_*_job.rb); core's OrchestratorService
# enqueues them by string via WorkerJobService — core never references the
# class. review_fleet has job_class nil (approval gates don't auto-dispatch).
# ─────────────────────────────────────────────────────────────────────
AGENT_FLEET_PHASES = [
  { "order" => 0, "key" => "plan_fleet",      "label" => "Plan Fleet",
    "requires_approval" => false, "job_class" => "AiAgentFleetPlanJob" },
  { "order" => 1, "key" => "review_fleet",    "label" => "Review & Approve Fleet",
    "requires_approval" => true,  "job_class" => nil, "gate_name" => "fleet_review" },
  { "order" => 2, "key" => "provision_fleet", "label" => "Provision Agent Instances",
    "requires_approval" => false, "job_class" => "AiAgentFleetProvisionJob" },
  { "order" => 3, "key" => "delegate",        "label" => "Delegate Subtasks",
    "requires_approval" => false, "job_class" => "AiAgentFleetDelegateJob" },
  { "order" => 4, "key" => "aggregate",       "label" => "Aggregate Results",
    "requires_approval" => false, "job_class" => "AiAgentFleetAggregateJob" },
  { "order" => 5, "key" => "reap",            "label" => "Reap Fleet",
    "requires_approval" => false, "job_class" => "AiAgentFleetReapJob" }
].freeze

template = ::Ai::MissionTemplate.find_or_initialize_by(
  name: "system_agent_fleet",
  template_type: "system"
)
was_new = template.new_record?

template.assign_attributes(
  account: nil, # system templates are account-agnostic
  description: "AI/MCP workload substrate L3 — dynamically provision a fleet of isolated " \
              "agent-instances, grant them platform-MCP (L2) + agent-to-agent (L2.5) " \
              "capabilities, delegate subtasks (hybrid: coordinator-assigned with optional " \
              "peer sub-delegation), aggregate results, and reap. One approval gate before " \
              "provisioning.",
  mission_type: "agent_fleet",
  status: "active",
  is_default: true,
  version: 1,
  phases: AGENT_FLEET_PHASES,
  approval_gates: %w[review_fleet],
  rejection_mappings: { "review_fleet" => "plan_fleet" },
  skill_compositions: {},
  default_configuration: {
    # The operator / MCP launch action fills in fleet_spec; the service
    # normalizes it into configuration["fleet"]["plan"] during plan_fleet.
    "fleet_spec" => {
      "size" => 0,
      "source" => "provision",          # "provision" (per-mission) | "pool" (acquire pre-warmed)
      "provider_region_id" => nil,
      "provider_instance_type_id" => nil,
      "node_id" => nil,
      "pool_name" => nil,
      "grant_mcp_tools" => [],          # L2: platform-MCP tool globs each member may invoke
      "grant_peer_skills" => [],        # L2.5: peer-skill globs each member may invoke on peers
      "member_skills" => [],            # skills each member OFFERS (declared_skills)
      "subtasks" => [],                 # [{ "id", "skill", "payload" }]
      "delegation" => "hybrid",         # "central" | "a2a" | "hybrid"
      "inference" => nil,               # optional { "model", "endpoint_override", ... } to wire shared GPU
      "reap" => true
    },
    # Populated by AgentFleetMissionService across phases:
    #   fleet.plan, fleet.members, fleet.assignments, fleet.report, fleet.reaped
    "fleet" => {}
  }
)
template.save!

puts "    ✓ #{was_new ? 'Created' : 'Updated'} Ai::MissionTemplate \"system_agent_fleet\" " \
     "(id=#{template.id}, #{AGENT_FLEET_PHASES.size} phases, 1 approval gate)"
puts "  Done seeding system_agent_fleet mission template."
