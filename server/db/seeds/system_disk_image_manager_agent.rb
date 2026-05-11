# frozen_string_literal: true

# Seeds the Disk Image Manager AI agent — owns disk image CI publication
# promotion, rollback, and retention. Carved out of Fleet Autonomy
# (2026-05-10) so image-publishing automations have their own queue
# (e.g., a nightly canary promotion can be paused independently of fleet ops).

puts "\n  Seeding Disk Image Manager agent + policies..."

admin_account = Account.first
unless admin_account
  puts "  ⚠️  No account found — skipping Disk Image Manager seed"
  return
end

def ensure_disk_image_trust_score!(account, agent)
  return if Ai::AgentTrustScore.exists?(agent_id: agent.id)
  Ai::AgentTrustScore.create!(
    account: account, agent: agent, tier: "monitored",
    reliability: 0.7, cost_efficiency: 0.7, safety: 0.85,
    quality: 0.7, speed: 0.7, overall_score: 0.74
  )
end

def upsert_disk_image_policies!(account, agent, policies)
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
  puts "  ⚠️  Need at least one user + Ai::Provider before seeding Disk Image Manager — skipping"
  return
end

disk_image_agent = admin_account.ai_agents.find_or_initialize_by(
  name: "Disk Image Manager",
  agent_type: "monitor"
)
disk_image_agent.assign_attributes(
  description: "Disk image CI orchestrator — publication promotion, rollback, retention",
  status: "active",
  autonomy_config: { "interval_seconds" => 300, "extension" => "system", "scope" => "disk_image" }
)
if disk_image_agent.new_record?
  disk_image_agent.creator  = creator
  disk_image_agent.provider = provider
end
disk_image_agent.save!
ensure_disk_image_trust_score!(admin_account, disk_image_agent)
puts "  ✅ Disk Image Manager agent: #{disk_image_agent.previously_new_record? ? 'created' : 'updated'}"

disk_image_policies = {
  "system.disk_image_publication_promote"  => "require_approval",  # production rollout
  "system.disk_image_publication_rollback" => "require_approval",  # reverting affects active fleet
  "system.disk_image_retention_update"     => "auto_approve",      # GC config, low-risk
  "system.disk_image_webhook_trigger"      => "notify_and_proceed" # webhook ingest
}

count = upsert_disk_image_policies!(admin_account, disk_image_agent, disk_image_policies)
puts "  ✅ Disk Image Manager policies: #{count} created/updated (#{disk_image_policies.size} total)"

stale = Ai::InterventionPolicy
  .where(account: admin_account, ai_agent_id: disk_image_agent.id, scope: "agent")
  .where.not(action_category: disk_image_policies.keys)
if stale.any?
  stale_count = stale.count
  stale.destroy_all
  puts "  🧹 Cleaned #{stale_count} stale Disk Image Manager policies"
end

disk_image_chain = Ai::ApprovalChain.find_or_initialize_by(
  account: admin_account,
  name: "Disk Image Manager Actions"
)
disk_image_chain.assign_attributes(
  trigger_type: "autonomy_action",
  status: "active",
  is_sequential: true,
  timeout_action: "reject",
  timeout_hours: 12,
  steps: [{
    "name" => "Image Operator Approval",
    "approvers" => [{ "type" => "permission", "value" => "system.infra_tasks.control" }],
    "required_approvals" => 1
  }]
)
if disk_image_chain.new_record? || disk_image_chain.changed?
  disk_image_chain.save!
  puts "  ✅ Disk Image Manager Approval Chain: created/updated"
else
  puts "  ✅ Disk Image Manager Approval Chain: already up to date"
end
