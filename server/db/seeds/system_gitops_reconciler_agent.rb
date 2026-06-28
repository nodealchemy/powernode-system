# frozen_string_literal: true

require_relative "concerns/agent_setup_helpers"

# Seeds the GitOps Reconciler AI agent — owns the declarative fleet-state
# reconciliation domain: diffing a registered Git repository's desired state
# against live fleet state, opening Ai::AgentProposal rows for the drift, and
# (when a repository opts into auto_apply) applying the reconciled change.
#
# WHY THIS AGENT EXISTS (the gap it closes):
#   `System::Gitops::Reconciler#gitops_agent_id` attributes every GitOps
#   proposal to an agent it looks up by name. Before this seed, no such agent
#   existed, so attribution fell back to `Ai::Agent.where(account:).first` — an
#   ARBITRARY agent (whichever was created first). GitOps drift then appeared in
#   the operator UI authored by, say, "Fleet Autonomy" or "System Concierge".
#   Seeding a dedicated reconciler agent gives those proposals a correct,
#   stable author. The Reconciler service resolves it by name (kept in sync
#   with NAME below).
#
# AUTONOMOUS vs OPERATOR ownership (mirrors the 2026-05-10 SDWAN split):
#   - The AUTONOMOUS drift signal (`system.gitops.drift_detected`, emitted by
#     FleetAutonomyService::SENSORS → GitopsDriftSensor) gates as the
#     "Fleet Autonomy" agent — so its `system.gitops_drift_remediate` policy
#     lives in fleet_autonomy_agent.rb, NOT here (same reason the autonomous
#     system.sdwan_* remediations live on Fleet Autonomy).
#   - The OPERATOR-initiated GitOps actions (apply a proposal, register a repo,
#     trigger a sync — the `system_gitops_*` MCP surface) are owned HERE, giving
#     the domain a dedicated approval queue an operator can pause independently
#     (e.g. freeze GitOps applies during a maintenance window without halting
#     the rest of fleet autonomy). This matches how SDWAN Manager owns operator
#     `sdwan.*` CRUD while Fleet Autonomy owns the autonomous remediations.

puts "\n  Seeding GitOps Reconciler agent + policies..."

agent_name = "GitOps Reconciler"

ctx = System::Seeds::AgentSetupHelpers.bootstrap_admin_context!(
  preferred_provider_types: [ "anthropic", "openai" ]
)
admin_account = ctx[:account]
creator       = ctx[:creator]
provider      = ctx[:provider]

gitops_prompt = <<~PROMPT
  You are the **GitOps Reconciler** — the agent of record for declarative
  fleet-state reconciliation in the Powernode system extension.

  ## Charter

  A registered `System::GitopsRepository` holds the *desired* fleet state as
  versioned YAML/JSON in Git. On each sync you (via `System::Gitops::Reconciler`)
  diff that desired state against the *live* fleet, and for every drift you open
  an `Ai::AgentProposal` describing the change. You are the author those
  proposals are attributed to, so an operator reviewing the GitOps queue sees a
  single, correct, domain-specific reconciler rather than an arbitrary agent.

  ## Operating Principles

  1. **Desired state is the source of truth.** Drift is the gap between Git and
     live; your job is to surface it precisely (resource kind, name, change
     class) and propose the minimal reconciling action — never a broader rewrite.
  2. **Destroy-class changes get the highest priority.** A diff that deletes a
     live resource warrants operator attention before create/update drift.
  3. **Auto-apply is a privilege, not a default.** Only a repository explicitly
     marked `auto_apply` skips human review, and even then a stale-conflict or
     apply failure reverts the proposal to `pending_review` for an operator.
  4. **One proposal per drifted resource.** Group nothing; an operator approves
     or rejects each reconciling change on its own merits.
  5. **Never act outside a registered repository's declared scope.** A repo
     reconciles only the resources its manifests name.

  Surface counts and the repository/branch/commit context up front so an
  operator can triage the queue without opening every proposal.
PROMPT

gitops_agent = admin_account.ai_agents.find_or_initialize_by(
  name: agent_name,
  agent_type: "monitor"
)
gitops_agent.assign_attributes(
  description: "Declarative fleet-state reconciler — diffs registered Git repositories against live state and authors drift proposals; owns operator-initiated GitOps actions",
  status: "active",
  autonomy_config: {
    "interval_seconds" => 300, # matches SystemGitopsSyncJob's 5-minute staleness window
    "extension" => "system",
    "scope" => "gitops"
  },
  metadata: (gitops_agent.metadata || {}).merge(
    "kind" => "system_gitops_reconciler",
    "extension" => "system",
    "capability_domains" => %w[gitops]
  )
)
# system_prompt= writes into mcp_metadata["system_prompt"] in place; set it
# FIRST, then reassign mcp_metadata to a fresh merged hash so BOTH the prompt
# and the model_config survive (a clean attribute reassignment AR persists,
# avoiding the in-place-mutation dirty-tracking gotcha). Diff/proposal
# reasoning over declarative manifests warrants a reasoning-tier model —
# resolved at runtime by Ai::AgentModelSelector from the account's credentialed
# providers (no hardcoded model id).
gitops_agent.system_prompt = gitops_prompt
gitops_agent.mcp_metadata = (gitops_agent.mcp_metadata || {}).merge(
  "model_config" => { "model_requirements" => { "tier" => "reasoning" } }
)
if gitops_agent.new_record?
  gitops_agent.creator  = creator
  gitops_agent.provider = provider
end
gitops_agent.save!
System::Seeds::AgentSetupHelpers.ensure_trust_score!(
  account: admin_account, agent: gitops_agent,
  tier: "monitored", overall: 0.72,
  dimensions: {
    reliability: 0.70, cost_efficiency: 0.72, safety: 0.85, quality: 0.74, speed: 0.70
  }
)
puts "  ✅ GitOps Reconciler agent: #{gitops_agent.previously_new_record? ? 'created' : 'updated'} (id=#{gitops_agent.id[0, 8]})"

# ── Operator-initiated GitOps action policies ─────────────────────────────
#
# These own the `system.gitops_*` operator surface (the `system_gitops_*` MCP
# actions). They mirror SDWAN Manager's operator-CRUD ownership: the action
# vocabulary + approval posture is declared on the owning agent so the GitOps
# queue is independently pause-able. (The AUTONOMOUS drift remediation policy
# lives on Fleet Autonomy — see header.)
gitops_policies = {
  "system.gitops_apply_proposal"      => "require_approval",  # applies a diff to live fleet state
  "system.gitops_register_repository" => "require_approval",  # adds a new declarative source of truth
  "system.gitops_sync_repository"     => "auto_approve"       # read-side: refresh the diff, no mutation
}

count = System::Seeds::AgentSetupHelpers.upsert_policies!(
  account: admin_account, agent: gitops_agent,
  definitions: gitops_policies
)
System::Seeds::AgentSetupHelpers.clean_stale_policies!(
  account: admin_account, agent: gitops_agent,
  keep_keys: gitops_policies.keys
)
puts "  ✅ GitOps Reconciler policies: #{count} changed (#{gitops_policies.size} total)"

# ── GitOps Reconciler Approval Chain ──────────────────────────────────────
# Single-step chain for GitOps require_approval actions (apply proposal /
# register repository). Surfaces in the same operator approval UI via
# source_type="system_gitops_reconciler" — no UI changes needed.
gitops_chain = Ai::ApprovalChain.find_or_initialize_by(
  account: admin_account,
  name: "GitOps Reconciler Actions"
)
gitops_chain.assign_attributes(
  trigger_type: "autonomy_action",
  status: "active",
  is_sequential: true,
  timeout_action: "reject",
  timeout_hours: 8, # a declarative apply can wait for a reviewer within the workday
  steps: [ {
    "name" => "GitOps Operator Approval",
    "approvers" => [ { "type" => "permission", "value" => "system.infra_tasks.control" } ],
    "required_approvals" => 1
  } ]
)
if gitops_chain.new_record? || gitops_chain.changed?
  gitops_chain.save!
  puts "  ✅ GitOps Reconciler Approval Chain: created/updated"
else
  puts "  ✅ GitOps Reconciler Approval Chain: already up to date"
end

puts "  Done seeding GitOps Reconciler agent."
