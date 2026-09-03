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
# AUTONOMOUS and OPERATOR ownership both live HERE (HIER-P2A):
#   - The AUTONOMOUS drift signal (`system.gitops.drift_detected`, emitted by
#     GitopsDriftSensor on the Fleet Autonomy tick) is gated under THIS agent —
#     its DecisionEngine binding declares `owner: "gitops-reconciler"` — so its
#     `system.gitops_drift_remediate` policy is declared in
#     GITOPS_RECONCILER_POLICIES. (Until HIER-P2A the tick could only gate as
#     the agent running it, which is why the row sat on Fleet Autonomy.)
#   - The OPERATOR-initiated GitOps actions (apply a proposal, register a repo,
#     trigger a sync — the `system_gitops_*` MCP surface) are owned here too,
#     giving the domain a dedicated approval queue an operator can pause
#     independently (e.g. freeze GitOps applies during a maintenance window
#     without halting the rest of fleet autonomy).

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

gitops_agent = System::Seeds::AgentSetupHelpers.find_or_initialize_global_agent(
  name: agent_name,
  agent_type: "monitor",
  source_key: "gitops-reconciler"
)
gitops_agent.assign_attributes(
  # ROUTING description (HIER-P2F): the first sentence is what
  # Ai::ClaudeExport::RoutingDescription folds into the Claude Code subagent
  # description, the rest is the platform-side trigger/exclusion. Kept under
  # RoutingDescription::MAX_CHARS (400), and the first sentence under its
  # MAX_DESCRIPTION_CHARS (140) so the export carries it whole, not elided.
  description: "Declarative fleet-state reconciliation: sync a GitOps repository, diff it against the " \
               "live fleet, apply an approved drift proposal. Use when an operator asks to " \
               "register, sync or apply GitOps repositories or proposals. Do not use for node or module " \
               "drift remediation — use Fleet Autonomy — nor for SDWAN topology work — use System " \
               "Topology Designer.",
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
#
# tool_access.tool_families LISTS ONLY THE FAMILIES THIS AGENT NEEDS (HIER-P2F):
# the `system_gitops` prefix admits exactly the seven system_gitops_* verbs
# (register / sync / apply plus the four reads) and nothing else — pinned by
# spec/db/seeds/system_gitops_reconciler_agent_seed_spec.rb, which also holds
# the count so a verb registered later under the prefix is noticed. The two
# skill-discovery verbs are named explicitly because the RUNTIME door
# (AgentToolBridgeService#scope_to_tool_families) is a plain select over the
# registry — only the exporter's ToolAllowlist unions BOOTSTRAP_ACTIONS in.
gitops_agent.system_prompt = gitops_prompt
gitops_agent.mcp_metadata = (gitops_agent.mcp_metadata || {}).merge(
  "model_config" => { "model_requirements" => { "tier" => "reasoning" } },
  "tool_access" => { "tool_families" => %w[system_gitops discover_skills get_skill_context] }
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
# actions) AND the sensor-routed `system.gitops_drift_remediate` row: the action
# vocabulary + approval posture is declared on the owning agent so the GitOps
# queue is independently pause-able (see header).
# Declared set now lives in System::Governance::PolicyDeclarations so the reconciler can
# assert it against a RUNNING database without executing this seed.
gitops_policies = System::Governance::PolicyDeclarations::GITOPS_RECONCILER_POLICIES

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
