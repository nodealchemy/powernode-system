# frozen_string_literal: true

require_relative "concerns/agent_setup_helpers"

# Seeds the Capacity Manager AI agent + its intervention policies + dedicated
# approval chain. HIER-P2B (Phase 2 wave 2, 2026-09-03): HIER-P2DECL declared
# the agent — identity, the 22-key CAPACITY_MANAGER_POLICIES set, the
# `owner: "capacity-manager"` sensor bindings and the hierarchy seat — ahead
# of this seed; this file gives the declaration a row to land on.
#
# Owns fleet CAPACITY, split out of Fleet Autonomy so capacity decisions
# (cost-bearing, often irreversible) have a queue of their own: the DR
# replace/reap pair, region expansion, capacity resize, workload relocation,
# the eight instance-pool verbs, the six `project.*` provisioning /
# adaptation verbs, platform-deployment scale-out/in and the cordon.
#
# Canonical rule (HIER-P1): a GLOBAL seeded canonical — the helper raises
# CanonicalAgentConflict on a stray account row rather than adopting it.
# Attached under the System Concierge by db/seeds/system_agent_hierarchy.rb,
# which runs after this file (SYSTEM_SEED_FILES) and writes the lineage edge
# and the P1 leaf delegation policy (conservative, max_depth 2).

puts "\n  Seeding Capacity Manager agent + policies..."

ctx = System::Seeds::AgentSetupHelpers.bootstrap_admin_context!(
  preferred_provider_types: [ "anthropic", "openai" ]
)
admin_account = ctx[:account]
creator       = ctx[:creator]
provider      = ctx[:provider]

capacity_prompt = <<~PROMPT
  You are the **Capacity Manager** — the capacity keeper for the Powernode
  system extension. You own how much fleet there is and where it runs:
  desired vs live replicas on every platform deployment, warm instance pools
  and their ceilings, provisioning and replacement of instances, relocation of
  workloads between regions, the cordon, and the `project.*` adaptation verbs
  a provisioning mission's SLO sensors raise.

  ## Charter

  You reconcile CAPACITY, not health. Fleet Autonomy runs the sensor tick and
  remediates a sick node (reboot, reprovision, drift, certs, rolling
  upgrades); you act when the fleet is the wrong SIZE or in the wrong PLACE.
  Two sensor lanes gate under you — `instance_unrecoverable_sensor` →
  `system.instance_replace` (disaster recovery: acquire a warm pool member,
  reattach volumes, re-enrol SDWAN, move VIPs) and `project_slo_sensor` →
  `project.adapt` / `project.cost_control` (with `System::AdaptationGate`
  routing every `project.<change_type>` plan). Everything else you own is a
  gated executor or an operator door read at your shape: the reap, region
  expansion, capacity resize, workload relocation, the eight
  `system.instance_pool_*` verbs, `system.platform.scale_out` / `scale_in`
  and `system.instance_cordon`.

  ## Operating Principles

  1. **Desired vs live is the only number that matters.** A deployment's
     `target_replicas` is intent; its live count is `active.not_cordoned` —
     one scope pair owned by `System::InstanceCordonService`, read identically
     by the replica reconciler and the Scaling panel. A cordoned replica is
     OUT of the live count (so its replacement is provisioned) and is the
     FIRST scale-in victim, then newest-first. Never reconcile against a
     count that includes cordoned rows.
  2. **Never scale in the deployment hosting the control plane.** The
     replica reconciler refuses the deployment that hosts this control plane
     (`control_plane_self_remediation`); so do you, before the write — a
     hub scale must not leave a `target_replicas` nothing will ever converge.
     Scale-OUT auto-executes only inside the deployment's declared window
     (`scaling_bounds`, fail-closed to "no ceiling"); scale-IN terminates
     instances, is not reversible, and waits for approval.
  3. **Pool ceilings are spend commitments.** `replenish` tops a pool up to
     target automatically; raising target/max (`instance_pool_ceiling_raise`),
     creating or deleting a pool, archiving it, and `drain` (halting
     replenishment) are gated. `acquire` is the fast path — claim a READY
     member, never a warming or draining one.
  4. **Provider quota and region availability are facts, not retries.** A
     provider refusal (quota, instance type unavailable in the region, no
     node with the requested GPU) is a capacity finding to report with the
     region, instance type and count named — not an error to retry into. Cost
     is ALWAYS gated: `region_expansion`, `capacity_resize`,
     `relocate_workload`, `project.relocate` require approval.
  5. **Cordon semantics (IMP-c9adb5a71dca / IMP-3d4058389afa).** A cordon
     marks an instance unschedulable and leaves it RUNNING: a ready pool
     member is fenced out of the allocator (`pool_state=draining`), a claimed
     member is fenced on return rather than re-admitted, a non-pool instance
     is marked only. Uncordon re-admits a fenced member only while it is
     still running; both verbs share one category, `system.instance_cordon`
     (require_approval), and you never lift a cordon an operator placed for
     maintenance — a hold that lifts itself is worse than no hold.
  6. **Replace is additive; the reap is a second decision.** An approved
     `instance_replace` leaves the replacement in service and the dead row
     visible; terminating it is `system.instance_reap`, asked separately, so
     the destructive half can be refused while the additive half proceeds.
     Every replace step is idempotent on its operation id — a re-emitted
     signal replays the replace in progress rather than claiming a second
     pool member.
  7. **Policy decides, not you.** Resolve the intervention policy before
     acting; under require_approval produce the plan (dry run) and stop.
     After repeated ineffective outcomes for a fingerprint, escalate to an
     operator rather than re-running a proven-futile action.
  8. **Name the resource and the number.** Every plan cites the deployment,
     pool, instance or mission id, the observed vs desired count, the region
     and instance type, and the exact verb and policy that gates it.

  ## Hand-offs

  - **Storage Manager** — volumes, snapshots, restore, storage-assignment
    reconciliation (you only reattach a failed instance's volumes during a
    replace; anything else about the data plane is theirs).
  - **Ingress Manager** — published services, ACME certificates, service
    backend sets (a replaced or scaled instance's backends are re-pointed by
    the executor; a service change of its own is theirs).
  - **Supply Chain Manager** — package repositories, package-derived modules,
    the architecture catalog.
  - **Fleet Autonomy** — reboot / reprovision / terminate remediation of a
    silent or compromised instance, module drift, certificate rotation,
    rolling upgrades, replica promotion.
  - **SDWAN Manager** (overlay), **Runtime Manager** (Docker / K3s) and the
    **System Concierge** (operator chat, platform deploy) own their domains;
    route there rather than act across the boundary.
PROMPT

capacity_agent = System::Seeds::AgentSetupHelpers.find_or_initialize_global_agent(
  name: "Capacity Manager",
  agent_type: "monitor",
  source_key: "capacity-manager"
)
capacity_agent.assign_attributes(
  # A ROUTING description: HIER-P1B exports it as the Claude Code subagent
  # description (first sentence ≤ 140 chars is the trigger; ≤ 400 total).
  description: "Fleet capacity — replicas vs target, instance pools and ceilings, provisioning, " \
               "replacement, relocation, cordons, platform scale-out/in. Use when capacity must grow, " \
               "shrink, move or be fenced. Do not use for node drift, cert or module remediation " \
               "(use Fleet Autonomy), volumes and snapshots (Storage Manager), published services " \
               "(Ingress Manager) or package/module ingestion (Supply Chain Manager).",
  status: "active",
  autonomy_config: { "interval_seconds" => 60, "extension" => "system", "scope" => "capacity" }
)
# Persona prompt + reasoning-tier model (cost-bearing, often irreversible
# decisions). system_prompt first (it writes into mcp_metadata in place), then
# a clean mcp_metadata reassignment so both survive AR dirty-tracking. No
# hardcoded model id — AgentModelSelector resolves it.
#
# tool_access.tool_families LISTS ONLY the families this agent needs. The
# bridge (AgentToolBridgeService#scope_to_tool_families) and the Claude Code
# export (Ai::ClaudeExport::ToolAllowlist) both match a registry action by
# exact name or `<family>_` prefix, so the list doubles as the CC `tools:`
# allowlist — the first canonical monitor scoped this way, where every
# earlier one inherited the full read set. Instances, instance pools,
# nodes/templates (read), platform scaling, provisioning, tasks (read) and
# storage (read); nothing from the SDWAN / ingress / supply-chain / disk-image
# / runtime domains. Every name below is a registered `system_*` action; a
# name that is not registered simply matches nothing.
capacity_agent.system_prompt = capacity_prompt
capacity_agent.mcp_metadata = (capacity_agent.mcp_metadata || {}).merge(
  "model_config" => { "model_requirements" => { "tier" => "reasoning" } },
  "tool_access" => {
    "tool_families" => %w[
      system_list_instances system_get_instance system_get_silent_instances
      system_provision_instance system_update_instance system_start_instance
      system_replace_instance system_reap_instance system_refresh_instance_modules
      system_cordon_instance system_uncordon_instance system_drain_instance
      system_list_instance_pools system_get_instance_pool system_create_instance_pool
      system_update_instance_pool system_delete_instance_pool system_drain_instance_pool
      system_replenish_instance_pool system_acquire_pooled_instance system_return_pooled_instance
      system_recycle_pool
      system_list_nodes system_get_node system_find_node_with_gpu
      system_list_templates system_get_template system_discover_templates
      system_compose_preview_template system_list_instance_types_by_gpu
      system_platform_resilience
      system_list_providers system_get_provider
      system_list_tasks system_get_task
      system_list_volumes system_get_volume system_list_volume_snapshots
      system_list_storage_assignments_by_owner system_get_storage_recommendations
    ]
  }
)
if capacity_agent.new_record?
  capacity_agent.creator  = creator
  capacity_agent.provider = provider
end
capacity_agent.save!
System::Seeds::AgentSetupHelpers.ensure_trust_score!(
  account: admin_account, agent: capacity_agent,
  tier: "monitored", overall: 0.72,
  dimensions: {
    reliability: 0.72, cost_efficiency: 0.70, safety: 0.88, quality: 0.72, speed: 0.70
  }
)
puts "  ✅ Capacity Manager agent: #{capacity_agent.previously_new_record? ? 'created' : 'updated'}"

# Action category registration happens in System::Engine#after_initialize so
# validation passes when these policies are created.

# The declared set lives in System::Governance::PolicyDeclarations
# (CAPACITY_MANAGER_POLICIES — 22 keys, one agent set, no duplicate
# declaration here) so PolicyReconciler can assert it against a RUNNING
# database without executing this seed, and re-home the rows an established
# install still holds on Fleet Autonomy (PolicyReconciler::FORMER_OWNERS) the
# first boot after this agent exists.
#
# AGENT SHAPE ONLY. The three operator twins (instance-pool-operator,
# platform-scaling, instance-cordon-operator — PolicyDeclarations::
# OPERATOR_TWINS) keep their own rows, written by
# system_instance_pool_policies.rb / system_instance_cordon_policies.rb /
# PolicyReconciler at the global shape; no operator-shape row is written here.
#
# project.scale_horizontal carries a per-category condition override
# (PROVISIONING_CONDITION_OVERRIDES — the auto_apply_window on top of the
# trust gate); upsert_policies! takes one `conditions:` per call, so the
# overridden keys are written in their own call rather than flattened to the
# set default.
capacity_policies  = System::Governance::PolicyDeclarations::CAPACITY_MANAGER_POLICIES
capacity_overrides = System::Governance::PolicyDeclarations::PROVISIONING_CONDITION_OVERRIDES

count = System::Seeds::AgentSetupHelpers.upsert_policies!(
  account: admin_account, agent: capacity_agent,
  definitions: capacity_policies.except(*capacity_overrides.keys)
)
capacity_overrides.each do |action_category, conditions|
  next unless capacity_policies.key?(action_category)

  count += System::Seeds::AgentSetupHelpers.upsert_policies!(
    account: admin_account, agent: capacity_agent,
    definitions: capacity_policies.slice(action_category),
    conditions: conditions
  )
end
System::Seeds::AgentSetupHelpers.clean_stale_policies!(
  account: admin_account, agent: capacity_agent,
  keep_keys: capacity_policies.keys,
  owned_prefixes: [ "system.", "project." ]
)
puts "  ✅ Capacity Manager policies: #{count} changed (#{capacity_policies.size} total)"

capacity_chain = Ai::ApprovalChain.find_or_initialize_by(
  account: admin_account,
  name: "Capacity Manager Actions"
)
capacity_chain.assign_attributes(
  trigger_type: "autonomy_action",
  status: "active",
  is_sequential: true,
  timeout_action: "reject",
  timeout_hours: 4,
  steps: [ {
    "name" => "Capacity Operator Approval",
    "approvers" => [ { "type" => "permission", "value" => "system.infra_tasks.control" } ],
    "required_approvals" => 1
  } ]
)
if capacity_chain.new_record? || capacity_chain.changed?
  capacity_chain.save!
  puts "  ✅ Capacity Manager Approval Chain: created/updated"
else
  puts "  ✅ Capacity Manager Approval Chain: already up to date"
end
