# frozen_string_literal: true

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

admin_account = Account.first
unless admin_account
  puts "  ⚠️  No account found — skipping Runtime Manager seed"
  return
end

# ── Helpers (duplicated from fleet_autonomy_agent for self-containment) ─

def ensure_runtime_trust_score!(account, agent)
  return if Ai::AgentTrustScore.exists?(agent_id: agent.id)

  Ai::AgentTrustScore.create!(
    account: account, agent: agent, tier: "monitored",
    reliability: 0.7, cost_efficiency: 0.7, safety: 0.85,
    quality: 0.7, speed: 0.7, overall_score: 0.74
  )
end

def upsert_runtime_policies!(account, agent, policies)
  return 0 unless agent

  changed = 0
  policies.each do |action_category, policy_type|
    policy = Ai::InterventionPolicy.find_or_initialize_by(
      account: account, action_category: action_category,
      scope: "agent", ai_agent_id: agent.id
    )
    policy.assign_attributes(
      policy: policy_type, priority: 10, is_active: true,
      conditions: { "trust_tier_minimum" => "monitored" },
      preferred_channels: %w[notification]
    )
    if policy.new_record? || policy.changed?
      policy.save!
      changed += 1
    end
  end
  changed
end

# ── Runtime Manager agent ────────────────────────────────────────────

creator  = admin_account.users.find_by(email: "admin@powernode.org") || admin_account.users.first
provider = ::Ai::Provider.first
unless creator && provider
  puts "  ⚠️  Need at least one user + Ai::Provider before seeding the Runtime Manager — skipping"
  return
end

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
ensure_runtime_trust_score!(admin_account, runtime_agent)
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
#   auto_approve       — routine reversible (TLS cert rotation aligns
#                        with `system.cert_rotate`'s hands-off posture).

runtime_policies = {
  # Docker daemon lifecycle
  "system.runtime_docker_provision"        => "notify_and_proceed",
  "system.runtime_docker_decommission"     => "require_approval",
  "system.runtime_docker_tls_rotate"       => "auto_approve",

  # Kubernetes cluster lifecycle (K3s today, kubeadm in Phase 3 —
  # same action vocabulary regardless of flavor; flavor enum on
  # Devops::KubernetesCluster gates which provisioner the agent uses).
  "system.runtime_k8s_cluster_bootstrap"   => "notify_and_proceed",
  "system.runtime_k8s_cluster_decommission" => "require_approval",
  "system.runtime_k8s_node_join"           => "notify_and_proceed",
  "system.runtime_k8s_node_drain"          => "require_approval",
  "system.runtime_k8s_runtime_upgrade"     => "require_approval"
}

count = upsert_runtime_policies!(admin_account, runtime_agent, runtime_policies)
puts "  ✅ Runtime Manager policies: #{count} created/updated (#{runtime_policies.size} total)"

# Clean stale policies for actions removed from this agent
stale = Ai::InterventionPolicy
  .where(account: admin_account, ai_agent_id: runtime_agent.id, scope: "agent")
  .where.not(action_category: runtime_policies.keys)
if stale.any?
  stale_count = stale.count
  stale.destroy_all
  puts "  🧹 Cleaned #{stale_count} stale Runtime Manager policies"
end

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

# ── Skill bindings ────────────────────────────────────────────────────
# Bind the container runtime skills (provision_cluster + docker_provision)
# to this agent. system_skills_seed.rb defers these bindings to here
# because the Runtime Manager doesn't exist until this seed runs.

%w[
  system-provision-cluster
  system-docker-provision
].each_with_index do |slug, i|
  skill = ::Ai::Skill.find_by(slug: slug)
  unless skill
    puts "  ⚠️  Skill #{slug} not found — run system_skills_seed.rb first"
    next
  end

  binding = ::Ai::AgentSkill.find_or_initialize_by(
    ai_agent_id: runtime_agent.id, ai_skill_id: skill.id
  )
  binding.assign_attributes(priority: 100 + i, is_active: true)
  binding.save!
end
puts "  ✅ Bound 2 container-runtime skills to Runtime Manager"

puts "  Done seeding Runtime Manager agent."
