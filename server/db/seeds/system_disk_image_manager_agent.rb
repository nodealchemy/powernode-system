# frozen_string_literal: true

require_relative "concerns/agent_setup_helpers"

# Seeds the Disk Image Manager AI agent — owns disk image CI publication
# promotion, rollback, and retention. Carved out of Fleet Autonomy
# (2026-05-10) so image-publishing automations have their own queue
# (e.g., a nightly canary promotion can be paused independently of fleet ops).

puts "\n  Seeding Disk Image Manager agent + policies..."

ctx = System::Seeds::AgentSetupHelpers.bootstrap_admin_context!(
  preferred_provider_types: ["anthropic", "openai"]
)
admin_account = ctx[:account]
creator       = ctx[:creator]
provider      = ctx[:provider]

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
System::Seeds::AgentSetupHelpers.ensure_trust_score!(
  account: admin_account, agent: disk_image_agent,
  tier: "monitored", overall: 0.70,
  dimensions: {
    reliability: 0.65, cost_efficiency: 0.70, safety: 0.80, quality: 0.70, speed: 0.70
  }
)
puts "  ✅ Disk Image Manager agent: #{disk_image_agent.previously_new_record? ? 'created' : 'updated'}"

disk_image_policies = {
  "system.disk_image_publication_promote"   => "require_approval",  # production rollout
  "system.disk_image_publication_rollback"  => "require_approval",  # reverting affects active fleet
  "system.disk_image_retention_update"      => "auto_approve",      # GC config, low-risk
  "system.disk_image_webhook_trigger"       => "notify_and_proceed", # webhook ingest
  "system.disk_image_webhook_revoke"        => "require_approval",  # cuts active CI integration
  "system.disk_image_webhook_rotate_secret" => "notify_and_proceed" # invalidates old, but recoverable
}

count = System::Seeds::AgentSetupHelpers.upsert_policies!(
  account: admin_account, agent: disk_image_agent,
  definitions: disk_image_policies
)
System::Seeds::AgentSetupHelpers.clean_stale_policies!(
  account: admin_account, agent: disk_image_agent,
  keep_keys: disk_image_policies.keys
)
puts "  ✅ Disk Image Manager policies: #{count} changed (#{disk_image_policies.size} total)"

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
