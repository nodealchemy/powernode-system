# frozen_string_literal: true

require_relative "concerns/agent_setup_helpers"

# Seeds the Disk Image Manager AI agent — owns disk image CI publication
# promotion, rollback, and retention. Carved out of Fleet Autonomy
# (2026-05-10) so image-publishing automations have their own queue
# (e.g., a nightly canary promotion can be paused independently of fleet ops).

puts "\n  Seeding Disk Image Manager agent + policies..."

ctx = System::Seeds::AgentSetupHelpers.bootstrap_admin_context!(
  preferred_provider_types: [ "anthropic", "openai" ]
)
admin_account = ctx[:account]
creator       = ctx[:creator]
provider      = ctx[:provider]

disk_image_prompt = <<~PROMPT
  You are the **Disk Image Manager** — the disk-image CI orchestrator for the
  Powernode system extension. You own the publication lifecycle: build → verify
  → promote → retention, plus the webhook ingest that feeds it.

  ## Charter

  CI builds produce OCI disk-image artifacts; you govern which publication is
  promoted to the active fleet, when to roll one back, how long old images are
  retained, and the webhook integrations that trigger builds. Your queue is
  independent (12h approval timeout, 5-minute tick) so image rollouts can pause
  without affecting the rest of fleet autonomy.

  ## Operating Principles

  1. **Promotion and rollback touch the active fleet — gate them.** Promoting a
     publication changes what new instances boot; rolling back reverts the fleet
     baseline. Both are approval-worthy; never promote or roll back unattended.
  2. **Retention is reversible config** (auto-approve) — adjusting GC windows is
     low-risk; webhook secret rotation is recoverable (notify_and_proceed), but
     revoking a webhook cuts an active CI integration (gate it).
  3. **Verify before you promote.** A publication must pass its verification
     before it is a promotion candidate; surface failed verification as a
     blocker, not a warning.
  4. **One publication lineage at a time.** Reason about the current active
     publication and the candidate's provenance (commit, builder) before
     proposing a promote.
  5. **Name the publication, the platform, and the change** in every plan.
PROMPT

disk_image_agent = System::Seeds::AgentSetupHelpers.find_or_initialize_global_agent(
  name: "Disk Image Manager",
  agent_type: "monitor",
  source_key: "disk-image-manager"
)
disk_image_agent.assign_attributes(
  # ROUTING description (HIER-P2F): the first sentence is what
  # Ai::ClaudeExport::RoutingDescription folds into the Claude Code subagent
  # description ("Use this agent when the task involves …"), the rest is the
  # platform-side trigger/exclusion the Concierge router reads. Kept under
  # RoutingDescription::MAX_CHARS (400), and the first sentence under its
  # MAX_DESCRIPTION_CHARS (140) so the export carries it whole, not elided.
  description: "Disk-image CI publication lifecycle: promote a verified publication to the boot default, " \
               "roll a platform back, tune retention. Use when an operator asks to promote, revert or " \
               "retain disk images. Do not use for node lifecycle or module drift work — use Fleet " \
               "Autonomy — nor for the CI build pipeline itself (Gitea workflows, CI workers).",
  status: "active",
  autonomy_config: { "interval_seconds" => 300, "extension" => "system", "scope" => "disk_image" }
)
# Persona prompt, model TIER and tool-family scope. system_prompt= writes into
# mcp_metadata in place; set it FIRST, then reassign mcp_metadata to a fresh
# merged hash so all three survive AR dirty-tracking (the same shape as the
# sibling seeds). A 5-minute monitor stays on the STANDARD tier — declared as a
# tier, never a pinned model id; AgentModelSelector resolves it.
#
# tool_access.tool_families LISTS ONLY THE FAMILIES THIS AGENT NEEDS (HIER-P2F).
# AgentToolBridgeService#scope_to_tool_families and
# Ai::ClaudeExport::ToolAllowlist match each entry by exact registry name or
# `<family>_` prefix, and a list matching nothing fails OPEN to the full
# registry — so every entry names a registered action (pinned by
# spec/db/seeds/system_disk_image_manager_agent_seed_spec.rb). Exact names: the
# disk-image verbs share no prefix of their own (system_revert_disk_image,
# system_set_default_disk_image_publication…). The CI-worker and webhook
# PROVISIONING verbs (DiskImageOperatorTool) are deliberately absent — the
# guide says this agent does not own CI worker provisioning.
#
# The three signal/task READS and the two skill-discovery verbs are listed
# because the RUNTIME door has no bootstrap set: AgentToolBridgeService
# #scope_to_tool_families is a plain select over the registry, while only the
# exporter's ToolAllowlist unions BOOTSTRAP_ACTIONS in. Without them this
# monitor could not read the signals its declared
# `system.disk_image_publication_investigate` lane is about, nor discover a
# skill, once the family scope is in force.
disk_image_agent.system_prompt = disk_image_prompt
disk_image_agent.mcp_metadata = (disk_image_agent.mcp_metadata || {}).merge(
  "model_config" => { "model_requirements" => { "tier" => "standard" } },
  "tool_access" => {
    "tool_families" => %w[
      system_list_disk_image_publications
      system_set_default_disk_image_publication
      system_revert_disk_image
      system_set_disk_image_retention
      system_list_disk_image_webhooks
      system_recent_signals
      system_list_tasks
      system_get_task
      discover_skills
      get_skill_context
    ]
  }
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

# Declared set now lives in System::Governance::PolicyDeclarations so the reconciler can
# assert it against a RUNNING database without executing this seed.
disk_image_policies = System::Governance::PolicyDeclarations::DISK_IMAGE_MANAGER_POLICIES

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
  steps: [ {
    "name" => "Image Operator Approval",
    "approvers" => [ { "type" => "permission", "value" => "system.infra_tasks.control" } ],
    "required_approvals" => 1
  } ]
)
if disk_image_chain.new_record? || disk_image_chain.changed?
  disk_image_chain.save!
  puts "  ✅ Disk Image Manager Approval Chain: created/updated"
else
  puts "  ✅ Disk Image Manager Approval Chain: already up to date"
end
