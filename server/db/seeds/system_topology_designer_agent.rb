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
# HIER-P2F: since HIER-P2DECL this agent carries the topology policy set
# (PolicyDeclarations::TOPOLOGY_DESIGNER_POLICIES — the three composer
# executor gates, written by PolicyReconciler like every declared set); this
# seed adds the "Topology Designer Actions" approval chain those
# require_approval gates route to, a routing description and a tool-family
# scope. The composer
# executors (sdwan_federation_compose / multi_tenant_isolation /
# service_discovery_composer) bind here via `binds_to "topology_designer"`;
# system_skill_bindings_seed.rb materialises the rows.
#
# Phase O6 follow-up — first specialist agent in the cross-cutting design
# track.

puts "\n  Seeding System Topology Designer agent..."

ctx = System::Seeds::AgentSetupHelpers.bootstrap_admin_context!(
  preferred_provider_types: [ "anthropic", "openai" ]
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
    - the SDWAN read verbs (`system_sdwan_get_*` / `system_sdwan_list_*`)
      plus the COMPOSITION writes (bridges, OVN, IPFIX, networks, route
      policies, federation). Day-to-day peer / VIP / BGP remediation is
      deliberately NOT in your grant — hand that to the SDWAN Manager.
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

topology_agent = System::Seeds::AgentSetupHelpers.find_or_initialize_global_agent(
  name: "System Topology Designer",
  agent_type: "assistant",
  source_key: "topology-designer"
)
topology_agent.assign_attributes(
  # ROUTING description (HIER-P2F): the first sentence is what
  # Ai::ClaudeExport::RoutingDescription folds into the Claude Code subagent
  # description, the rest is the platform-side trigger/exclusion. Kept under
  # RoutingDescription::MAX_CHARS (400), and the first sentence under its
  # MAX_DESCRIPTION_CHARS (140) so the export carries it whole, not elided.
  description: "Cross-cutting topology composition: SDWAN bridges, OVN networks, IPFIX collectors, " \
               "federation overlays, tenant isolation, service discovery. Use when an operator asks to " \
               "design or compose a network topology. Do not use for day-to-day SDWAN peer, VIP or BGP " \
               "remediation — use SDWAN Manager — nor for node lifecycle work — use Fleet Autonomy.",
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
# Cross-cutting topology composition is reasoning-heavy. Reassign mcp_metadata
# (not in-place) so the tier persists alongside the in-place system_prompt.
# No hardcoded model id — AgentModelSelector resolves it.
#
# tool_access.tool_families LISTS ONLY THE FAMILIES THIS AGENT NEEDS (HIER-P2F)
# in the vocabulary AgentToolBridgeService#scope_to_tool_families and
# Ai::ClaudeExport::ToolAllowlist read: exact registry name, or `<family>_`
# prefix. EXACT NAMES, never the bare `system_sdwan` prefix — that one entry
# would admit every system_sdwan_* verb there is, deletes, VIP failover and
# user-device issuance included, i.e. exactly the day-to-day remediation this
# agent's own description hands to the SDWAN Manager. So: the SDWAN READ
# surface, the COMPOSITION writes (bridges, OVN, IPFIX, networks, route
# policies, federation), the two other composer gates, the K8s / Docker
# topology reads, and skill discovery — which the runtime door needs listed
# because, unlike the exporter, it unions in no bootstrap set of its own.
#
# A list matching nothing fails OPEN to the full registry, so every entry must
# match a registered action; the seed spec holds that AND an equality oracle
# over the derived allowlist, so a verb registered later under one of these
# names' prefixes cannot widen the grant unnoticed. `docker_get_network`, named
# by the filter above but registered nowhere, is absent for the same reason.
topology_agent.mcp_metadata = (topology_agent.mcp_metadata || {}).merge(
  "model_config" => { "model_requirements" => { "tier" => "reasoning" } },
  "tool_access" => {
    "tool_families" => %w[
      system_sdwan_get_account_bgp
      system_sdwan_get_audit_log
      system_sdwan_get_bgp_config_for_peer
      system_sdwan_get_bgp_sessions
      system_sdwan_get_federation_peer
      system_sdwan_get_firewall_rule
      system_sdwan_get_host_bridge
      system_sdwan_get_ipfix_collector
      system_sdwan_get_network
      system_sdwan_get_ovn_deployment
      system_sdwan_get_peer
      system_sdwan_get_port_mapping
      system_sdwan_get_route_policy
      system_sdwan_get_routing_summary
      system_sdwan_get_topology
      system_sdwan_get_virtual_ip
      system_sdwan_list_access_grants
      system_sdwan_list_federation_peers
      system_sdwan_list_firewall_rules
      system_sdwan_list_host_bridges
      system_sdwan_list_ipfix_collectors
      system_sdwan_list_networks
      system_sdwan_list_ovn_acls
      system_sdwan_list_ovn_deployments
      system_sdwan_list_ovn_logical_switches
      system_sdwan_list_peers
      system_sdwan_list_port_mappings
      system_sdwan_list_route_policies
      system_sdwan_list_subnet_advertisements
      system_sdwan_list_user_devices
      system_sdwan_list_vip_assignments
      system_sdwan_list_virtual_ips
      system_sdwan_activate_host_bridge
      system_sdwan_activate_ovn_logical_switch
      system_sdwan_activate_ovn_logical_switch_port
      system_sdwan_compile_ovn_plan
      system_sdwan_compile_route_policy
      system_sdwan_create_host_bridge
      system_sdwan_create_ipfix_collector
      system_sdwan_create_network
      system_sdwan_create_ovn_acl
      system_sdwan_create_ovn_deployment
      system_sdwan_create_ovn_logical_switch
      system_sdwan_create_ovn_logical_switch_port
      system_sdwan_create_route_policy
      system_sdwan_federation_compose
      system_sdwan_federation_scan
      system_sdwan_propose_federation_peer
      system_sdwan_update_ipfix_collector
      system_sdwan_update_network
      system_sdwan_update_network_routing_mode
      system_sdwan_update_route_policy
      system_multi_tenant_isolation
      system_service_discovery_compose
      kubernetes_list_clusters
      kubernetes_list_nodes
      kubernetes_get_cluster
      kubernetes_get_kubeconfig
      docker_list_networks
      docker_list_volumes
      discover_skills
      get_skill_context
    ]
  }
)
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

# ── Intervention policies: NOT written here ──────────────────────────────
# System::Governance::PolicyReconciler is the SINGLE WRITER of the declared
# set (PolicyDeclarations::TOPOLOGY_DESIGNER_POLICIES, POLICY_SETS "topology-designer") —
# on every boot, the first one included (rails-start.sh runs the governance
# reconcile after db:seed), and via `rails system:governance:reconcile`. It
# writes against the account's acting principal for this agent (HIER-P2I)
# and creates absence only, so an operator's tuned verb survives a re-seed.
# The approval chain below stays here: the reconciler writes policy rows and
# nothing else. Proposal §5 ruling 7 / IMP-10e4f6c3bcd2.
puts "  ℹ️  System Topology Designer policies: written by System::Governance::PolicyReconciler " \
     "(#{System::Governance::PolicyDeclarations::TOPOLOGY_DESIGNER_POLICIES.size} declared; " \
     "boot-time governance-reconcile or `rails system:governance:reconcile`)"

# ── Topology Designer Approval Chain (HIER-P2F) ───────────────────────────
# Single-step chain for the require_approval composer gates (federation
# overlay, multi-tenant isolation, service-discovery composition). Composition
# is operator/Concierge-driven design work that can wait for a reviewer within
# the workday, so the timeout matches the GitOps Reconciler's rather than the
# SDWAN Manager's 4h remediation window.
topology_chain = Ai::ApprovalChain.find_or_initialize_by(
  account: admin_account,
  name: "Topology Designer Actions"
)
topology_chain.assign_attributes(
  trigger_type: "autonomy_action",
  status: "active",
  is_sequential: true,
  timeout_action: "reject",
  timeout_hours: 8,
  steps: [ {
    "name" => "Topology Operator Approval",
    "approvers" => [ { "type" => "permission", "value" => "system.infra_tasks.control" } ],
    "required_approvals" => 1
  } ]
)
if topology_chain.new_record? || topology_chain.changed?
  topology_chain.save!
  puts "  ✅ Topology Designer Approval Chain: created/updated"
else
  puts "  ✅ Topology Designer Approval Chain: already up to date"
end
