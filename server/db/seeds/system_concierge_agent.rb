# frozen_string_literal: true

# Seeds the System Concierge AI agent — operator-facing chat agent that
# can answer questions about the fleet (nodes, instances, modules, tasks,
# CVE exposures) and SDWAN overlay (networks, peers, firewall rules,
# VIPs, BGP) and dispatch state-changing skills with operator confirmation.
#
# Mirrors the fleet_autonomy_agent.rb seed shape so both system-extension
# agents follow the same pattern (idempotent find_or_initialize, lazy
# provider/creator on new records, trust score bootstrap).
#
# The Concierge's tool surface is declared via metadata.concierge_tool_filter,
# which Ai::ConciergeToolBridge reads at conversation time to restrict the
# LLM to system_* and system_sdwan_* actions only (avoiding overwhelm from
# the platform's ~84+ general-purpose tools).
#
# Reference: comprehensive stabilization sweep Phase 10.3.

puts "\n  Seeding System Concierge agent..."

admin_account = Account.first
unless admin_account
  puts "  ⚠️  No account found — skipping System Concierge seed"
  return
end

creator  = admin_account.users.find_by(email: "admin@powernode.org") || admin_account.users.first
provider = ::Ai::Provider.first
unless creator && provider
  puts "  ⚠️  Need at least one user + Ai::Provider before seeding the System Concierge — skipping"
  return
end

system_prompt = <<~PROMPT
  You are the **System Concierge** — an operator-facing assistant for the Powernode platform's
  System extension. Your job is to help operators understand, navigate, and operate their fleet
  (compute infrastructure) and SDWAN overlay (private networking).

  You have access to read-only and mutating tools across two surfaces:

  **Fleet (system_*)** — nodes, node instances, templates, modules + versions, tasks,
  CVE exposures, fleet events, drift reports, AI skills (provision_cluster, module_compose,
  runbook_generate, cve_response, capacity_recommend, etc.).

  **SDWAN (system_sdwan_*)** — overlay networks, peers, firewall rules, access grants,
  user devices, virtual IPs, BGP sessions, route policies, port mappings, federation
  proposals.

  **Operating principles:**
  1. **Read first, mutate after confirmation.** For any destructive action (delete network,
     terminate instance, revoke user device, failover VIP, etc.) call `request_confirmation`
     so the operator can review the plan in a confirmation card before dispatch.
  2. **Be concise and specific.** Answer with structured data when relevant (counts, IDs,
     status). Avoid hedging — operators want decisions, not options.
  3. **Surface fleet context up front.** When asked open-ended questions ("how is the fleet?",
     "what needs attention?"), summarize counters first, then drill in.
  4. **Don't speculate about state you haven't queried.** Call the appropriate tool — don't
     guess what an instance's status is.

  Current fleet snapshot is provided as the next system message; refer to it as your
  starting context. For deeper queries, dispatch a tool.
PROMPT

concierge_agent = admin_account.ai_agents.find_or_initialize_by(
  name: "System Concierge",
  agent_type: "assistant"
)
concierge_agent.assign_attributes(
  description: "Operator chat agent for fleet + SDWAN — read-only by default, dispatches state-changing skills with operator confirmation",
  status: "active",
  system_prompt: system_prompt,
  metadata: (concierge_agent.metadata || {}).merge(
    "concierge_tool_filter" => %w[system_* request_confirmation],
    "concierge_kind" => "system_concierge",
    "extension" => "system"
  )
)
if concierge_agent.new_record?
  concierge_agent.creator  = creator
  concierge_agent.provider = provider
end
concierge_agent.save!

# Bootstrap trust score so existing approval/intervention flows can score
# the agent's actions. "monitored" tier mirrors fleet_autonomy_agent.
unless ::Ai::AgentTrustScore.exists?(agent_id: concierge_agent.id)
  ::Ai::AgentTrustScore.create!(
    account: admin_account, agent: concierge_agent, tier: "monitored",
    reliability: 0.7, cost_efficiency: 0.7, safety: 0.85,
    quality: 0.7, speed: 0.7, overall_score: 0.74
  )
end

puts "  ✅ System Concierge agent: #{concierge_agent.previously_new_record? ? 'created' : 'updated'} (id=#{concierge_agent.id})"
