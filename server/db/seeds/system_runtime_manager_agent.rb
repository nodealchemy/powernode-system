# frozen_string_literal: true

require_relative "concerns/agent_setup_helpers"

# Seeds the Runtime Manager AI agent — specialized monitor agent for
# container runtime lifecycle (Phase 1 Docker + Phase 2 K3s; Phase 3
# kubeadm follows the same shape).
#
# Decouples container-runtime autonomy from broader Fleet Autonomy
# concerns (cert rotation, SDWAN, CVE response, drift). Operators tune
# trust scores + autonomy policies per-domain — e.g. allow auto-rotation
# of `docker_daemon_tls` certs while keeping cluster decommission gated.
#
# Mirrors fleet_autonomy_agent.rb shape so all monitor agents share
# the same approval queue UI without code-path divergence.
#
# Spicy-bear plan slice 3a.

puts "\n  Seeding Runtime Manager agent..."

ctx = System::Seeds::AgentSetupHelpers.bootstrap_admin_context!(
  preferred_provider_types: [ "anthropic", "openai" ]
)
admin_account = ctx[:account]
creator       = ctx[:creator]
provider      = ctx[:provider]

# ── Runtime Manager agent ────────────────────────────────────────────

runtime_prompt = <<~PROMPT
  You are the **Runtime Manager** — the container-runtime lifecycle reconciler
  for the Powernode system extension. You own managed Docker daemons (Phase 1)
  and K3s/Kubernetes clusters (Phase 2; kubeadm in Phase 3 follows the same
  action vocabulary), gating provision / decommission / node-join / drain /
  upgrade actions.

  ## Charter

  When an operator assigns a runtime module to a NodeInstance, you carry the
  follow-through: provision the daemon or bootstrap the cluster, then keep its
  lifecycle gated. The cluster flavor (k3s vs kubeadm) selects the provisioner;
  the action vocabulary (`system.runtime_*`) stays flavor-independent.

  ## Operating Principles

  1. **Provisioning is the obvious follow-through** (notify_and_proceed) — the
     operator already opted in by assigning the module. Destructive actions are
     not: decommission destroys the managed host row + its Vault credentials,
     and cluster decommission cascade-deletes node rows — those are gated.
  2. **Upgrades affect running workloads.** Treat a runtime upgrade as
     approval-worthy; reason about what's scheduled on the cluster before
     proposing a node drain.
  3. **Rotate TLS via the cert flow.** There is no dedicated Docker-daemon
     TLS-rotate action; route daemon TLS rotation through `system.cert_rotate`
     or a daemon re-provision.
  4. **One runtime per concern.** Keep Docker and K3s actions distinct so an
     operator can pause one runtime class without affecting the other.
  5. **Name the host/cluster and the action** in every plan, with the blast
     radius (which instances/workloads are affected).
PROMPT

runtime_agent = System::Seeds::AgentSetupHelpers.find_or_initialize_global_agent(
  name: "Runtime Manager",
  agent_type: "monitor",
  source_key: "runtime-manager"
)
runtime_agent.assign_attributes(
  description: "Container runtime lifecycle reconciler — Phase 1 Docker + Phase 2 K3s clusters; gates provision/decommission/upgrade actions",
  status: "active",
  system_prompt: runtime_prompt,
  autonomy_config: {
    "interval_seconds" => 60,
    "extension" => "system",
    "scope" => "container_runtimes"
  },
  metadata: (runtime_agent.metadata || {}).merge(
    "kind" => "system_runtime_manager",
    "managed_runtimes" => %w[docker k3s_server k3s_agent]
  )
)
if runtime_agent.new_record?
  runtime_agent.creator  = creator
  runtime_agent.provider = provider
end
runtime_agent.save!
System::Seeds::AgentSetupHelpers.ensure_trust_score!(
  account: admin_account, agent: runtime_agent,
  tier: "monitored", overall: 0.72,
  dimensions: {
    reliability: 0.68, cost_efficiency: 0.65, safety: 0.85, quality: 0.70, speed: 0.70
  }
)
puts "  ✅ Runtime Manager agent: #{runtime_agent.previously_new_record? ? 'created' : 'updated'} (id=#{runtime_agent.id[0, 8]})"

# ── Intervention policies: NOT written here ──────────────────────────────
# System::Governance::PolicyReconciler is the SINGLE WRITER of the declared
# set (PolicyDeclarations::RUNTIME_MANAGER_POLICIES, POLICY_SETS "runtime-manager") —
# on every boot, the first one included (rails-start.sh runs the governance
# reconcile after db:seed), and via `rails system:governance:reconcile`. It
# writes against the account's acting principal for this agent (HIER-P2I)
# and creates absence only, so an operator's tuned verb survives a re-seed.
# The approval chain below stays here: the reconciler writes policy rows and
# nothing else. Proposal §5 ruling 7 / IMP-10e4f6c3bcd2.
# TWO sets, two audiences: the agent set above and the OPERATOR-path twin
# (RUNTIME_OPERATOR_POLICIES, POLICY_SETS "runtime-operator", scope
# "action_type") — deliberately the GATED subset, not all seven, so no
# operator row renders for a category no gate site reads
# (IMP-9b9653e6514e; system_runtime_operator_policies_spec pins both halves).
# The vocabulary is `system.runtime_*`; `system.runtime_docker_tls_rotate`
# was removed in the 2026-05-19 audit (no executor) — rotate daemon TLS
# through `system.cert_rotate` or a daemon re-provision.
puts "  ℹ️  Runtime Manager policies: written by System::Governance::PolicyReconciler " \
     "(#{System::Governance::PolicyDeclarations::RUNTIME_MANAGER_POLICIES.size} declared; " \
     "boot-time governance-reconcile or `rails system:governance:reconcile`)"

# ── Runtime Manager Approval Chain ────────────────────────────────────
# Single-step chain for runtime require_approval actions. Surfaces in
# the same operator approval UI as Fleet Autonomy via
# source_type="system_runtime_manager" — no UI changes needed.

runtime_chain = Ai::ApprovalChain.find_or_initialize_by(
  account: admin_account,
  name: "Runtime Manager Actions"
)
runtime_chain.assign_attributes(
  trigger_type: "autonomy_action",
  status: "active",
  is_sequential: true,
  timeout_action: "reject",
  timeout_hours: 4,
  steps: [ {
    "name" => "Runtime Operator Approval",
    "approvers" => [ "*" ],
    "required_approvals" => 1
  } ]
)
if runtime_chain.new_record? || runtime_chain.changed?
  runtime_chain.save!
  puts "  ✅ Runtime Manager Approval Chain: created/updated"
else
  puts "  ✅ Runtime Manager Approval Chain: already up to date"
end

puts "  Done seeding Runtime Manager agent."
