# frozen_string_literal: true

require_relative "concerns/agent_setup_helpers"

# Seeds the Supply Chain Manager AI agent — the custodian of the software
# supply chain: package repository ingestion, package-derived NodeModule
# creation and refresh, and the platform-wide architecture catalog. Carved
# out of Fleet Autonomy by HIER-P2DECL (2026-09-03, Phase 2 wave 1 declared
# it; this seed is wave 2 — HIER-P2E) so every package entering the fleet is
# audited in its own queue, independent of node-lifecycle remediation.
#
# WHAT THIS SEED WRITES: the global canonical agent, its trust score and its
# approval chain. It writes NO intervention-policy rows. The set
# (PolicyDeclarations::SUPPLY_CHAIN_MANAGER_POLICIES) moved off Fleet
# Autonomy, and System::Governance::PolicyReconciler is the writer for a
# moved set: on a fresh install it creates the seven rows the first time it
# runs after this seed (boot-time governance-reconcile, or
# `rails system:governance:reconcile`), and on an established install it
# RE-HOMES the operator's tuned rows off Fleet Autonomy in place (same row,
# verb / priority / conditions kept, audit written). A seed upsert here would
# race that: the reconciler leaves a former owner's row alone once the new
# owner has its own, so the old row would survive as a duplicate. Same shape
# as system_topology_designer_agent.rb, the other agent whose set moved.

puts "\n  Seeding Supply Chain Manager agent..."

ctx = System::Seeds::AgentSetupHelpers.bootstrap_admin_context!(
  preferred_provider_types: [ "anthropic", "openai" ]
)
admin_account = ctx[:account]
creator       = ctx[:creator]
provider      = ctx[:provider]

supply_chain_prompt = <<~PROMPT
  You are the **Supply Chain Manager** — the software-supply-chain custodian
  for the Powernode system extension. You own package repository ingestion
  (apt/rpm metadata sync), package-derived NodeModule creation and refresh,
  and the platform-wide architecture catalog.

  ## Charter

  Every package that enters the fleet passes through you, and every one of
  them is operator-audited: materialising a package as a NodeModule is a
  supply-chain decision (which upstream, which version, which transitive
  closure, which architectures), not a routine refresh. Repository metadata
  sync is routine and reversible. The architecture catalog is shared by every
  account, so changing it is gated even for a holder of
  `system.architectures.manage`.

  ## Policy verbs you may take

  | Action category | Default | Door |
  |---|---|---|
  | `system.package_repository.sync` | auto_approve | `package_drift_sensor` → `system.package_drift_pressure`; `package_repository_sync` skill |
  | `system.package_module.create` | require_approval | `package_module_create` skill (`system_create_module_from_package`) |
  | `system.package_module.refresh` | require_approval | `package_module_refresh` skill — see the CVE lane below |
  | `system.architecture.propose` | auto_approve | `architecture_propose` skill — the Ai::AgentProposal it files IS the human gate |
  | `system.architecture.create` | require_approval | `architecture_create` skill |
  | `system.architecture.update` | require_approval | `architecture_update` skill |
  | `system.architecture.delete` | require_approval | `architecture_delete` skill |

  `suggest_architectures_for_fleet` is read-shaped (no gate): use it to ground
  a materialisation in the operator's actual fleet coverage before proposing
  architectures.

  ## Operating Principles

  1. **Creation is audited; sync is routine.** Never materialise a package
     unattended — `system.package_module.create` waits in your queue for an
     operator. A repository sync only refreshes cached metadata and may
     proceed on the sensor's signal.
  2. **Provenance is the product.** Name the repository, the upstream
     version, the transitive closure and the target architectures in every
     plan. Treat an artifact's ingested SBOM as the evidence of what a module
     ships, and a VEX/CVE statement as the evidence of what that means — a
     package name match with no version evidence is a suspicion, not a fact.
  3. **The CVE lane calls refresh through the CVE Responder.** Nothing
     sensor-routed reaches `package_module_refresh`; the CVE Responder's
     remediation orchestration invokes it directly for each exposed module,
     under the CVE lane's own gate. When you refresh outside that lane,
     `system.package_module.refresh` requires approval.
  4. **Propose, don't impose, on the catalog.** Prefer `architecture_propose`
     (auto-approved because the proposal is the review) over direct
     create/update/delete, which every account feels.
  5. **Stale metadata is not drift.** A stale repository sync window is a
     sync; a manifest diverging from its registered NodeModule is a refresh
     decision — do not conflate the two.

  ## Hand-offs

  - **CVE Responder** — vulnerability exposure, triage and patch rollout;
    it owns `system.cve_*` and calls your refresh executor when a fix exists.
  - **Disk Image Manager** — disk-image publications, promotion, rollback,
    retention.
  - **Fleet Autonomy** — module composition onto templates, module version
    promotion and rolling upgrades once a module exists; node-lifecycle
    remediation.
  - **System Concierge** — operator chat routing; it delegates supply-chain
    questions to you and package discovery (`discover_packages_by_intent`)
    stays there.
PROMPT

supply_chain_agent = System::Seeds::AgentSetupHelpers.find_or_initialize_global_agent(
  name: "Supply Chain Manager",
  agent_type: "monitor",
  source_key: "supply-chain-manager"
)
supply_chain_agent.assign_attributes(
  # A ROUTING description: Ai::ClaudeExport::RoutingDescription lifts its
  # first sentence into the Claude Code subagent's frontmatter, and the
  # platform router reads the whole thing. ≤ 400 chars, trigger then hand-offs.
  description: "Software supply chain custodian — package repositories, package-derived modules and the " \
               "architecture catalog. Use when a package repository needs syncing, a package must become a " \
               "NodeModule, or an architecture is proposed or changed. Do not use for CVE exposure or patch " \
               "rollout (CVE Responder), disk images (Disk Image Manager) or module promotion (Fleet Autonomy).",
  status: "active",
  autonomy_config: { "interval_seconds" => 300, "extension" => "system", "scope" => "supply_chain" }
)
# Persona prompt + reasoning-tier model (provenance / closure reasoning).
# system_prompt first (it writes into mcp_metadata in place), then a clean
# mcp_metadata reassignment so both persist. No hardcoded model id —
# AgentModelSelector resolves it.
#
# tool_access.tool_families LISTS ONLY the registry actions this agent needs
# (exact names, or a `<family>_` prefix — Ai::AgentToolBridgeService
# #scope_to_tool_families and Ai::ClaudeExport::ToolAllowlist read the same
# list): package repositories, packages and package modules; the architecture
# catalog; modules READ-only; CVE READ-only. Everything else (SDWAN, disk
# images, module promotion, CVE writes, repository delete) is a sibling's.
supply_chain_agent.system_prompt = supply_chain_prompt
supply_chain_agent.mcp_metadata = (supply_chain_agent.mcp_metadata || {}).merge(
  "model_config" => { "model_requirements" => { "tier" => "reasoning" } },
  "tool_access"  => {
    "tool_families" => %w[
      system_list_package_repositories system_get_package_repository
      system_create_package_repository system_update_package_repository
      system_sync_package_repository
      system_search_packages system_discover_packages system_get_package
      system_resolve_package_dependencies
      system_list_package_module_links system_create_module_from_package
      system_refresh_package_module
      system_list_architectures system_get_architecture system_propose_architecture
      system_create_architecture system_update_architecture system_delete_architecture
      system_suggest_architectures_for_fleet
      system_list_modules system_get_module system_list_module_versions
      system_discover_modules system_validate_module_manifest
      system_get_cve system_get_cve_exposure
    ]
  }
)
if supply_chain_agent.new_record?
  supply_chain_agent.creator  = creator
  supply_chain_agent.provider = provider
end
supply_chain_agent.save!
System::Seeds::AgentSetupHelpers.ensure_trust_score!(
  account: admin_account, agent: supply_chain_agent,
  tier: "monitored", overall: 0.70,
  dimensions: {
    reliability: 0.65, cost_efficiency: 0.70, safety: 0.85, quality: 0.70, speed: 0.65
  }
)
puts "  ✅ Supply Chain Manager agent: #{supply_chain_agent.previously_new_record? ? 'created' : 'updated'}"
puts "  ℹ️  Supply Chain Manager policies: written by System::Governance::PolicyReconciler " \
     "(#{System::Governance::PolicyDeclarations::SUPPLY_CHAIN_MANAGER_POLICIES.size} declared; " \
     "boot-time governance-reconcile or `rails system:governance:reconcile`)"

supply_chain_chain = Ai::ApprovalChain.find_or_initialize_by(
  account: admin_account,
  name: "Supply Chain Manager Actions"
)
supply_chain_chain.assign_attributes(
  trigger_type: "autonomy_action",
  status: "active",
  is_sequential: true,
  timeout_action: "reject",
  timeout_hours: 8,  # a package audit spans business hours; reject, never auto-proceed
  steps: [ {
    "name" => "Supply Chain Operator Approval",
    "approvers" => [ { "type" => "permission", "value" => "system.infra_tasks.control" } ],
    "required_approvals" => 1
  } ]
)
if supply_chain_chain.new_record? || supply_chain_chain.changed?
  supply_chain_chain.save!
  puts "  ✅ Supply Chain Manager Approval Chain: created/updated"
else
  puts "  ✅ Supply Chain Manager Approval Chain: already up to date"
end
