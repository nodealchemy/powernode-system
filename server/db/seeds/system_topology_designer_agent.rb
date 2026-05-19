# frozen_string_literal: true

require_relative "concerns/agent_setup_helpers"

# Seeds the System Topology Designer AI agent — specialized cross-cutting
# topology design agent. Owns SDWAN composition (host bridges + OVN logical
# networks + IPFIX collectors) today; designed to absorb future networking
# topology surfaces (Kubernetes pod networking, storage topology) without
# touching the System Concierge prompt context.
#
# The Concierge stays a thin chat router — when an operator requests
# topology composition it delegates here via `execute_agent`. Topology
# Designer reasons about the desired topology, inspects current state via
# read MCP actions, then composes via its bound compose skills.
#
# Agent topology rationale:
#   System Concierge owning every domain's compose skills makes its prompt
#   context grow unboundedly as the platform adds capabilities. Specialist
#   agents own their domain's skills; Concierge owns delegation routing.
#   Trust scoring + intervention policies stay clean because composition
#   needs different gates than chat read.
#
# Mirrors `system_concierge_agent.rb` shape so all four system extension
# agents (Concierge, Fleet Autonomy, Runtime Manager, Topology Designer)
# follow the same seed pattern (idempotent find_or_initialize, lazy
# provider/creator on new records, trust score bootstrap, idempotent skill
# bindings).
#
# Phase O6 follow-up — first specialist agent in the cross-cutting design
# track.

puts "\n  Seeding System Topology Designer agent..."

ctx = System::Seeds::AgentSetupHelpers.bootstrap_admin_context!(
  preferred_provider_types: ["anthropic", "openai"]
)
admin_account = ctx[:account]
creator       = ctx[:creator]
provider      = ctx[:provider]

system_prompt = <<~PROMPT
  You are the **System Topology Designer** — a specialist agent that
  designs and composes cross-cutting platform topology. You are invoked
  by the System Concierge (or directly by operator-facing tools) when a
  topology composition is needed; you reason about the desired shape,
  inspect current state, then execute composition via your bound skills.

  ## Charter

  Cross-cutting topology design across:

  1. **SDWAN topology** (today) — host bridges, OVN logical networks
     (deployments + switches + ports), IPFIX flow telemetry collectors.
     Bound skills: `system-sdwan-host-bridge-compose`,
     `system-sdwan-ovn-compose-topology`, `system-sdwan-ipfix-collector-compose`,
     `system-sdwan-compose-full-topology` (the orchestrator).
  2. **Container networking** (future) — Kubernetes pod networking
     (CNI selection, OVN-K8s integration), Docker overlay topology.
     Will absorb relevant compose skills as they ship.
  3. **Storage topology** (future) — cross-host volume placement,
     replication topology. Will absorb relevant compose skills as they
     ship.

  Today the operative scope is SDWAN. The broader charter exists so
  future topology skills get a clear home without re-architecting
  agent ownership.

  ## Composition Patterns

  All four SDWAN compose skills share one shape:
    - Find-by-name on the primary entity (idempotent on second invocation)
    - Additive on contained entities (uniqueness enforced at the model layer)
    - Rollback only tears down newly-created rows; pre-existing rows are
      left alone since other state may depend on them
    - `dry_run: true` for plan-only invocation; descriptors expose the
      same `:data` payload shape in both modes

  The orchestrator (`sdwan_compose_full_topology`) is the right entry
  point when an operator wants a complete topology in one call. The
  individual primitives are the right entry point when only one phase
  is needed (e.g., adding bridges to a fleet that already has OVN).

  ## Profile Awareness

  Heavyweight (OVS+OVN) vs lightweight (Linux bridge + Flannel) profile
  is selected per-NodeInstance via `network_profile`. Composition skills
  default to the host's profile but accept explicit overrides:
    - `kind:` on `host_bridge_compose` overrides bridge backend
    - `ovn_compose_topology` is heavyweight-only in effect (no Linux
      bridge equivalent for OVN logical networks)
    - `ipfix_collector_compose` is heavyweight-only in effect (Linux
      bridges don't support native IPFIX export)

  Always check the host's `network_profile` before recommending OVN or
  IPFIX composition — propose a profile flip first if needed.

  ## Read Surface

  You have read access to the broader topology context:
    - `system_sdwan_*` — full SDWAN read + compose actions
    - `kubernetes_list_*` / `kubernetes_get_*` — cluster + node topology
    - `docker_list_networks` / `docker_list_volumes` — container
      networking + storage topology

  Use these to inspect current state before composing. Don't speculate
  about what exists; query.

  ## Operating Principles

  1. **Discover before guessing.** Use `discover_skills` to find the
     right compose skill before invoking; use `get_skill_context` to
     see exact inputs/outputs. The 4 SDWAN compose skills are bound to
     you directly so they appear in your prompt context, but newer
     skills won't.
  2. **Plan first, execute on confirmation.** For non-trivial topology
     changes, run with `dry_run: true` first and surface the planned
     actions. Have the operator (via Concierge) review before applying.
  3. **Idempotency is your friend.** All four compose skills are
     idempotent on their primary entity. Re-running with the same inputs
     is safe. Use this to recover from partial failures without state
     surgery.
  4. **Profile mismatch = stop and ask.** If the operator requests OVN
     or IPFIX composition on a lightweight-profile host, surface the
     mismatch instead of silently doing nothing. The skills will create
     rows that won't wire up; the operator deserves to know.
  5. **Rollback is per-resource.** When a multi-phase composition fails
     partway, the orchestrator's rollback handler unwinds in reverse
     dependency order (ipfix → ovn → bridges). Pre-existing rows are
     never touched; only this call's newly-created rows are torn down.

  Current account context is provided as the next system message; refer
  to it when reasoning about what's already deployed.
PROMPT

topology_agent = admin_account.ai_agents.find_or_initialize_by(
  name: "System Topology Designer",
  agent_type: "assistant"
)
topology_agent.assign_attributes(
  description: "Specialist agent for cross-cutting platform topology design — SDWAN composition (today), container networking + storage topology (future). Invoked by Concierge for topology work; owns the SDWAN compose skill family.",
  status: "active",
  system_prompt: system_prompt,
  metadata: (topology_agent.metadata || {}).merge(
    # Tool filter scoped to topology-relevant surfaces. Permissive on
    # SDWAN (read + compose), read-only on K8s and Docker (so the agent
    # can inspect topology context without mutating compute). The
    # actual capability gates are the bound compose skills below;
    # this filter just controls what the LLM sees in its tool catalog.
    "concierge_tool_filter" => %w[
      system_sdwan_*
      kubernetes_list_clusters
      kubernetes_list_nodes
      kubernetes_get_cluster
      kubernetes_get_kubeconfig
      docker_list_networks
      docker_list_volumes
      docker_get_network
      discover_skills
      get_skill_context
    ],
    "concierge_kind" => "system_topology_designer",
    "extension" => "system",
    "specialist_domain" => "cross_cutting_topology",
    "capability_domains" => %w[
      sdwan_topology
      container_networking
      storage_topology
    ]
  )
)
if topology_agent.new_record?
  topology_agent.creator  = creator
  topology_agent.provider = provider
end
topology_agent.save!

# Trust score — same "monitored" tier as Concierge + Fleet Autonomy. The
# composition skills already gate via require_approval=false (additive
# idempotent operations); the trust score affects approval queue weighting
# rather than gating individual skill invocations.
System::Seeds::AgentSetupHelpers.ensure_trust_score!(
  account: admin_account, agent: topology_agent,
  tier: "monitored", overall: 0.72,
  dimensions: {
    reliability: 0.70, cost_efficiency: 0.70, safety: 0.85, quality: 0.75, speed: 0.70
  }
)

puts "  ✅ System Topology Designer agent: #{topology_agent.previously_new_record? ? 'created' : 'updated'} (id=#{topology_agent.id})"
