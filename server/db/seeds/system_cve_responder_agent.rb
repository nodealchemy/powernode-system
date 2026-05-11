# frozen_string_literal: true

# Seeds the CVE Responder AI agent — dedicated to CVE intake (SBOM ingestion,
# exposure scanning) and remediation orchestration. Carved out of Fleet
# Autonomy (2026-05-10) so security incidents have their own queue + can
# be elevated to higher-trust auto-remediation later without reshuffling
# fleet ops policies.

puts "\n  Seeding CVE Responder agent + policies..."

admin_account = Account.first
unless admin_account
  puts "  ⚠️  No account found — skipping CVE Responder seed"
  return
end

def ensure_cve_trust_score!(account, agent)
  return if Ai::AgentTrustScore.exists?(agent_id: agent.id)
  Ai::AgentTrustScore.create!(
    account: account, agent: agent, tier: "monitored",
    reliability: 0.7, cost_efficiency: 0.7, safety: 0.85,
    quality: 0.7, speed: 0.7, overall_score: 0.74
  )
end

def upsert_cve_policies!(account, agent, policies)
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

creator  = admin_account.users.find_by(email: "admin@powernode.org") || admin_account.users.first
provider = ::Ai::Provider.first
unless creator && provider
  puts "  ⚠️  Need at least one user + Ai::Provider before seeding CVE Responder — skipping"
  return
end

cve_agent = admin_account.ai_agents.find_or_initialize_by(
  name: "CVE Responder",
  agent_type: "monitor"
)
cve_agent.assign_attributes(
  description: "CVE intake + remediation — SBOM ingest, exposure scan, patch orchestration",
  status: "active",
  autonomy_config: { "interval_seconds" => 60, "extension" => "system", "scope" => "cve" }
)
if cve_agent.new_record?
  cve_agent.creator  = creator
  cve_agent.provider = provider
end
cve_agent.save!
ensure_cve_trust_score!(admin_account, cve_agent)
puts "  ✅ CVE Responder agent: #{cve_agent.previously_new_record? ? 'created' : 'updated'}"

cve_policies = {
  "system.cve_remediate"      => "require_approval",   # patch strategy needs operator review
  "system.cve_sbom_ingest"    => "auto_approve",       # importing inventory is read-shape
  "system.cve_exposure_scan"  => "auto_approve",       # scanning produces findings, no mutations
  "system.cve_auto_remediate" => "block"               # off by default; operators opt in per-policy
}

count = upsert_cve_policies!(admin_account, cve_agent, cve_policies)
puts "  ✅ CVE Responder policies: #{count} created/updated (#{cve_policies.size} total)"

stale = Ai::InterventionPolicy
  .where(account: admin_account, ai_agent_id: cve_agent.id, scope: "agent")
  .where.not(action_category: cve_policies.keys)
if stale.any?
  stale_count = stale.count
  stale.destroy_all
  puts "  🧹 Cleaned #{stale_count} stale CVE Responder policies"
end

cve_chain = Ai::ApprovalChain.find_or_initialize_by(
  account: admin_account,
  name: "CVE Responder Actions"
)
cve_chain.assign_attributes(
  trigger_type: "autonomy_action",
  status: "active",
  is_sequential: true,
  timeout_action: "reject",
  timeout_hours: 8,  # CVE response often spans business days
  steps: [{
    "name" => "Security Operator Approval",
    "approvers" => [{ "type" => "permission", "value" => "system.infra_tasks.control" }],
    "required_approvals" => 1
  }]
)
if cve_chain.new_record? || cve_chain.changed?
  cve_chain.save!
  puts "  ✅ CVE Responder Approval Chain: created/updated"
else
  puts "  ✅ CVE Responder Approval Chain: already up to date"
end
