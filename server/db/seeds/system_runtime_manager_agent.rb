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

puts "\n  Seeding Runtime Manager agent + policies..."

ctx = System::Seeds::AgentSetupHelpers.bootstrap_admin_context!(
  preferred_provider_types: ["anthropic", "openai"]
)
admin_account = ctx[:account]
creator       = ctx[:creator]
provider      = ctx[:provider]

# ── Runtime Manager agent ────────────────────────────────────────────

runtime_agent = admin_account.ai_agents.find_or_initialize_by(
  name: "Runtime Manager",
  agent_type: "monitor"
)
runtime_agent.assign_attributes(
  description: "Container runtime lifecycle reconciler — Phase 1 Docker + Phase 2 K3s clusters; gates provision/decommission/upgrade actions",
  status: "active",
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

# ── Default action policies ───────────────────────────────────────────
#
# Vocabulary uses `system.runtime_*` prefix so the autonomy executor
# can dispatch on (extension, action_category) without colliding with
# Fleet Autonomy's `system.cert_*` / `system.sdwan_*` action space.
#
# Decision rationale:
#   notify_and_proceed — operator already opted-in by assigning the
#                        runtime module to a NodeInstance; provisioning
#                        is the obvious follow-through.
#   require_approval   — destructive (decommission destroys managed
#                        host row + Vault credentials; cluster
#                        decommission cascade-deletes node rows;
#                        upgrades affect workloads).
#   auto_approve       — routine reversible.
#
# NOTE: `system.runtime_docker_tls_rotate` was previously seeded as
# `auto_approve` but had no executor implementation; removed during the
# 2026-05-19 doc accuracy audit. Operators rotate Docker daemon TLS via
# the `system.cert_rotate` skill (the broader cert-rotation flow) or by
# re-running the daemon provisioner; a dedicated TLS-rotate executor
# would be added when the lifecycle requires it.

runtime_policies = {
  # Docker daemon lifecycle
  "system.runtime_docker_provision"        => "notify_and_proceed",
  "system.runtime_docker_decommission"     => "require_approval",

  # Kubernetes cluster lifecycle (K3s today, kubeadm in Phase 3 —
  # same action vocabulary regardless of flavor; flavor enum on
  # Devops::KubernetesCluster gates which provisioner the agent uses).
  "system.runtime_k8s_cluster_bootstrap"   => "notify_and_proceed",
  "system.runtime_k8s_cluster_decommission" => "require_approval",
  "system.runtime_k8s_node_join"           => "notify_and_proceed",
  "system.runtime_k8s_node_drain"          => "require_approval",
  "system.runtime_k8s_runtime_upgrade"     => "require_approval"
}

count = System::Seeds::AgentSetupHelpers.upsert_policies!(
  account: admin_account, agent: runtime_agent,
  definitions: runtime_policies
)
System::Seeds::AgentSetupHelpers.clean_stale_policies!(
  account: admin_account, agent: runtime_agent,
  keep_keys: runtime_policies.keys
)
puts "  ✅ Runtime Manager policies: #{count} changed (#{runtime_policies.size} total)"

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
