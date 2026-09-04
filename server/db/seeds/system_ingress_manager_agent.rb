# frozen_string_literal: true

require_relative "concerns/agent_setup_helpers"

# Seeds the Ingress Manager AI agent — the owner of service exposure and
# certificate issuance. Split out of Fleet Autonomy by HIER-P2DECL (2026-09-03,
# Phase 2 wave 1: declarations) and seeded here (HIER-P2D, wave 2) so the
# ingress writes — the `/svc/<slug>` local publish, public TCP and HTTPS
# exposure, ACME DNS-01 issuance and a published service's backend set — sit
# behind ONE agent's queue that an operator can pause on its own.
#
# What it OWNS (PolicyDeclarations::INGRESS_MANAGER_POLICIES, 5 keys):
#   system.expose_service_local / _public_tcp / _publicly  — the executor gates
#   system.acme_certificate_provision                       — DNS-01 issuance
#   system.service_backends_update                          — the
#     system_set_service_backends MCP door (IMP-0c10b9fd5596): the agent that
#     owns the ingress WRITER owns the row that gates it.
# No sensor routes to any of these (sensor_owner_gating_spec asserts it), so
# this agent owns rows but no fleet-tick lane: it acts when an operator (via
# the System Concierge or an MCP door) asks for a service to be published.
#
# What it does NOT own, on purpose:
#   * `system.acme_cert_rotate` stays on Fleet Autonomy: CertExpirySensor runs
#     on the fleet tick and its binding fires PlatformMaintenanceExecutor's
#     fire-and-forget RENEWAL sweep over certificates the platform already
#     holds — a fleet-health remediation, not an issuance decision. Issuing a
#     NEW certificate for a new exposure is this agent's call; keeping an
#     existing one from expiring is the reconciler's.
#   * networks, peers and VIP lifecycle (SDWAN Manager); replica counts
#     (Capacity Manager). This agent READS VIPs to publish against them and
#     hands the lifecycle off.
#
# Canonical rule (HIER-P1 §5): GLOBAL seeded canonical via
# find_or_initialize_global_agent — raises CanonicalAgentConflict on a stray
# account row, never adopts it. Attached under System Concierge by
# db/seeds/system_agent_hierarchy.rb (its attach list is
# PolicyDeclarations::AGENT_IDENTITIES, which already names "ingress-manager").
# Skill bindings come from the executors' `binds_to "ingress_manager"`
# (SkillBindings::AGENT_ALIASES) and are materialised by
# system_skill_bindings_seed.rb — nothing here binds a skill by hand.

puts "\n  Seeding Ingress Manager agent..."

ctx = System::Seeds::AgentSetupHelpers.bootstrap_admin_context!(
  preferred_provider_types: [ "anthropic", "openai" ]
)
admin_account = ctx[:account]
creator       = ctx[:creator]
provider      = ctx[:provider]

ingress_prompt = <<~PROMPT
  You are the **Ingress Manager** — the service-exposure and certificate
  agent for the Powernode system extension. You own the moment a backend
  becomes REACHABLE: the local `/svc/<slug>` publish behind ForwardAuth,
  public TCP (HostSNI) and public HTTPS exposure, ACME DNS-01 certificate
  issuance, and the load-balanced backend set of a published service.

  ## Charter

  Every exposure is modelled as an `Sdwan::Service` (identity + slug + one
  overlay backend [a VIP or a static host] + port) with facets you switch on.
  The verbs you own. Each of the first five is an autonomy action category
  with its own intervention policy on your queue (the fail-safe ungated ones
  are listed last):

  - `system_expose_service_local` (`system.expose_service_local`) — publish
    at `/svc/<slug>` on the platform's own host(s). Resolve-or-create the
    service, enable the local facet (auth mode public | authenticated |
    scoped + permission/group, strip-prefix, which host certificate's CN to
    mount under), then `Sdwan::ServiceExposureWriter` regenerates
    `local-services-<account>.yaml` and Traefik hot-reloads — no restart.
    Prefer `system_create_service` first when the operator wants to review
    the record before it is reachable.
  - `system_expose_service_publicly` (`system.expose_service_publicly`) —
    public HTTPS: VIP → port map → ACME certificate → Traefik router.
  - `system_expose_service_public_tcp` (`system.expose_service_public_tcp`)
    — raw TLS-carrying TCP over HostSNI; needs the `tls` protocol and, under
    `edge_mode: terminate`, a valid certificate whose CN matches the host.
  - `system_acme_provision_certificate` (`system.acme_certificate_provision`)
    — DNS-01 issuance through a stored DNS credential. Issue for a NEW
    exposure; check `system_acme_get_certificate` first — a valid cert for
    the host already exists more often than not.
  - `system_set_service_backends` (`system.service_backends_update`) — the
    backend set, declaratively.
  - `system_unexpose_service_local` / `system_unexpose_service_public_tcp`
    are fail-safe OFF and are never gated: turning a route off is the safe
    direction. `system_reverse_proxy_compose` repairs a stale proxy file
    after a regen failure.

  ## The backend set (IMP-0c10b9fd5596 — read before touching one)

  - The `backends` list you pass IS the set: members are matched by address
    + port and updated in place, absent members are removed, `[]` clears the
    set. Never send a partial list to "add one" — you will drop the rest.
  - A `draining` member keeps its row and its history but leaves the emitted
    server list. **Draining EVERY member takes the service OUT OF ROTATION**:
    the writer skips it (`drained_service_ids`) rather than render an empty
    server list or fall back to the legacy column that names the host that
    died. `system_set_service_backends` answers `out_of_rotation: true` when
    the set it just wrote is entirely draining, and the local expose skill
    fails with "every backend … is draining" instead of reporting a
    `local_url` nothing serves. Keep the original backend LISTED while you
    rebuild a set.
  - An EMPTY set (no rows) is a different state: the service renders its
    legacy `backend_host` / `backend_vip` exactly as before.
  - The fleet executors maintain the set automatically by ADDRESS
    (`scale_project` add/remove replicas, `replace_instance` drains the dead
    member, `reap_instance` removes it); a VIP-fronted service is left to the
    VIP move. Only repoint a set they wrote when the operator asks.

  ## Health checks are opt-in (tier 1), on purpose

  `health_check_enabled` defaults to `false`. Traefik drops a check-failing
  server from the pool and answers 503 once none are left, so a check
  pointed at the wrong path does not degrade a scaled service — it takes the
  whole service dark. The path is per service (Grafana `/api/health`, Rails
  `/up`, a bare exporter `/`), so enable it where you KNOW the path, per
  service through `load_balancer` on `system_set_service_backends`
  (`{ health_check_enabled: true, health_check_path: "/-/ready" }`); a lower
  tier always beats a higher one and `false` counts as a value. Never flip
  the deployment-wide SiteSetting on the operator's behalf.

  ## ACME: issuance is yours, renewal is Fleet Autonomy's

  `system.acme_cert_rotate` stays in Fleet Autonomy's core set: CertExpirySensor
  runs on the fleet tick and fires the platform_maintenance `cert_rotate`
  renewal sweep over certificates the platform already holds — a
  fleet-health remediation with no issuance decision in it (`notify_and_proceed`).
  You decide whether a new certificate should EXIST — you issue it. You do
  not hold renew, revoke or DNS-credential creation: those are ungated verbs
  no intervention policy covers, so they stay operator doors. If an expiring
  certificate backs one of your routes, say so and let the rotation lane run;
  if one was mis-issued, hand the revocation to an operator with the hostname
  and the reason.

  ## Hand-offs

  - **SDWAN Manager** — networks, peers, VIP create / failover / delete. You
    READ VIPs (`system_sdwan_list_virtual_ips`, `system_sdwan_get_virtual_ip`,
    the assignments) to publish against them; a missing or unassigned VIP is
    a hand-off, not something you create.
  - **Capacity Manager** — replica counts. "The service needs more backends"
    means scale the project; the new replicas join the set by address on
    their own. Do not add a backend that no instance serves.
  - **Fleet Autonomy** — certificate renewal (above) and node-level cert
    rotation (`system.cert_rotate`).
  - **System Concierge** — routes operator chat to you and carries the
    approval card; every exposure verb parks an approval on the
    "Ingress Manager Actions" chain (4h, reject on timeout).

  ## Operating Principles

  1. **Reachability is the blast radius.** Every expose is a new door;
     every backend-set write can blackhole a service. Name the service, the
     facet, the host, and what changes for callers, before proposing.
  2. **Check, then issue.** Read `system_get_service` / `system_acme_get_certificate`
     before creating anything; re-running an expose with the same slug
     updates in place — duplicates are a bug, not a retry.
  3. **Prefer the fail-safe direction.** Unexpose is ungated; expose,
     issuance and backend writes wait for approval. You do not hold
     `system_update_service` — repointing a live service's backend goes
     through the gated `system_set_service_backends`, never around it.
  4. **Keep the operator's tuning.** A per-service `load_balancer` override
     was set for a reason; carry it forward when you rewrite a set.
  5. **Say what you did not do.** A hand-off to the SDWAN or Capacity
     Manager is part of the answer, not an omission.
PROMPT

ingress_agent = System::Seeds::AgentSetupHelpers.find_or_initialize_global_agent(
  name: "Ingress Manager",
  agent_type: "monitor",
  source_key: "ingress-manager"
)
# A ROUTING description. Two consumers, and they do NOT agree:
#   * the platform router and this record read it whole (under 400 chars,
#     RoutingDescription::MAX_CHARS) — trigger, then the exclusion naming the
#     sibling that owns each adjacent domain;
#   * the Claude Code frontmatter exports only a COMPACTION of it —
#     Ai::ClaudeExport::RoutingDescription#build keeps the FIRST SENTENCE
#     (truncated to 140 chars) and REPLACES the "Do not use for …" clause with
#     a machine-derived exclusion naming whichever sibling the exporter picks.
#     So the SDWAN / Capacity exclusions below reach the platform router and
#     this file's readers, never the .claude/agents skeleton. The first
#     sentence therefore has to stand alone as the trigger.
ingress_agent.assign_attributes(
  description: "Service publishing: the /svc/<slug> local publish, public TCP/HTTPS exposure, ACME DNS-01 " \
               "issuance and backend sets. Use when an operator asks to publish, expose or certify a service " \
               "or change its backends. Do not use for overlay networks, peers or VIP lifecycle (SDWAN " \
               "Manager), replica counts (Capacity Manager) or certificate renewal (Fleet Autonomy).",
  status: "active",
  autonomy_config: { "interval_seconds" => 300, "extension" => "system", "scope" => "ingress" },
  metadata: (ingress_agent.metadata || {}).merge(
    "kind" => "system_ingress_manager",
    "extension" => "system",
    "capability_domains" => %w[ingress acme services]
  )
)
# system_prompt= writes into mcp_metadata in place; set it FIRST, then
# reassign mcp_metadata to a fresh merged hash so the prompt, the model
# requirement and the tool scope all survive AR dirty-tracking.
#
# Model: reasoning tier — an exposure decision reads a service record, a
# certificate, a VIP and a backend set together. Resolved at runtime by
# Ai::AgentModelSelector; no pinned provider or model id.
#
# tool_access.tool_families LISTS ONLY the families this agent needs. Both
# consumers match a registered action by exact name or `<family>_` prefix
# (Ai::AgentToolBridgeService#scope_to_tool_families at runtime,
# Ai::ClaudeExport::ToolAllowlist for the committed Claude Code `tools:`
# allowlist), and a list that matches NOTHING fails open to the full registry —
# so every entry here is pinned against the registry by the seed spec.
#   services            — list/get/create + the gated backend-set door
#   ingress / expose    — system_expose_service_* and system_unexpose_service_*
#   ACME                — ONLY provision + get, named in full
#   SDWAN VIPs (read)   — list/get VIPs and their assignments; lifecycle stays SDWAN Manager's
#   reverse proxy       — system_reverse_proxy_compose (repair a stale proxy file)
#   discovery/knowledge — discover_skills / get_skill_context / search_knowledge /
#     query_learnings. NOT decoration: BASE_GUARDRAILS (prepended to every
#     agent prompt) ORDER the agent to "query platform guidance
#     (search_knowledge tag:guidance-*)" and to reuse-first via
#     discover_skills. The Claude Code exporter re-adds its own
#     BOOTSTRAP_ACTIONS, but Ai::AgentToolBridgeService#scope_to_tool_families
#     adds nothing — omit them and the runtime agent cannot obey its own
#     guardrails. (The sibling wave-2 seeds omit them; see open_questions.)
#
# Deliberately ABSENT, because a family entry matches by `<family>_` PREFIX and
# a bare family silently widens the grant:
#   * the bare `system_acme` family — it would admit
#     system_acme_{renew,revoke}_certificate and system_acme_create_dns_credential.
#     All three are `mutating: true` with no action_category and appear in NO
#     POLICY_SETS entry, so nothing downstream gates them; revoking a live
#     certificate takes an HTTPS route dark with no approval card and a DNS-01
#     credential is secret-bearing. Renewal is Fleet Autonomy's lane anyway.
#   * system_update_service — it writes backend_vip_id / backend_host /
#     backend_port and regenerates the proxy for an exposed service
#     (SystemIngressTool#update_service), i.e. the same blackhole blast radius
#     the GATED system_set_service_backends exists to control, with no gate on
#     it. Identity/plumbing edits are an operator door.
#   * system_delete_service — unpublishing is the unexpose verbs; deleting the
#     record is an operator door.
ingress_agent.system_prompt = ingress_prompt
ingress_agent.mcp_metadata = (ingress_agent.mcp_metadata || {}).merge(
  "model_config" => { "model_requirements" => { "tier" => "reasoning" } },
  "tool_access" => {
    "tool_families" => %w[
      system_list_services system_get_service system_create_service
      system_set_service_backends
      system_expose_service system_unexpose_service
      system_acme_provision_certificate system_acme_get_certificate
      system_sdwan_list_virtual_ips system_sdwan_get_virtual_ip system_sdwan_list_vip_assignments
      system_reverse_proxy_compose
      discover_skills get_skill_context search_knowledge query_learnings
    ]
  }
)
if ingress_agent.new_record?
  ingress_agent.creator  = creator
  ingress_agent.provider = provider
end
ingress_agent.save!
# Monitored, like its wave-2 siblings start: every verb it owns is an
# exposure or a backend-set write (blackhole class), so safety is weighted
# and the tier stays below Fleet Autonomy's until its history earns more.
System::Seeds::AgentSetupHelpers.ensure_trust_score!(
  account: admin_account, agent: ingress_agent,
  tier: "monitored", overall: 0.70,
  dimensions: {
    reliability: 0.70, cost_efficiency: 0.72, safety: 0.88, quality: 0.72, speed: 0.70
  }
)
puts "  ✅ Ingress Manager agent: #{ingress_agent.previously_new_record? ? 'created' : 'updated'} (id=#{ingress_agent.id[0, 8]})"

# ── Intervention policies: NOT written here ──────────────────────────────
# System::Governance::PolicyReconciler is the SINGLE WRITER of the declared
# set (PolicyDeclarations::INGRESS_MANAGER_POLICIES, POLICY_SETS "ingress-manager") —
# on every boot, the first one included (rails-start.sh runs the governance
# reconcile after db:seed), and via `rails system:governance:reconcile`. It
# writes against the account's acting principal for this agent (HIER-P2I)
# and creates absence only, so an operator's tuned verb survives a re-seed.
# The approval chain below stays here: the reconciler writes policy rows and
# nothing else. Proposal §5 ruling 7 / IMP-10e4f6c3bcd2.
# An established install's rows still on Fleet Autonomy are re-homed here
# (PolicyReconciler::FORMER_OWNERS).
puts "  ℹ️  Ingress Manager policies: written by System::Governance::PolicyReconciler " \
     "(#{System::Governance::PolicyDeclarations::INGRESS_MANAGER_POLICIES.size} declared; " \
     "boot-time governance-reconcile or `rails system:governance:reconcile`)"

# Exposure changes are operator-visible and reversible (unexpose is ungated),
# so the chain mirrors the SDWAN Manager's 4h window rather than the
# security-grade 8h — a publish request that waits half a day is stale.
ingress_chain = Ai::ApprovalChain.find_or_initialize_by(
  account: admin_account,
  name: "Ingress Manager Actions"
)
ingress_chain.assign_attributes(
  trigger_type: "autonomy_action",
  status: "active",
  is_sequential: true,
  timeout_action: "reject",
  timeout_hours: 4,
  steps: [ {
    "name" => "Ingress Operator Approval",
    "approvers" => [ { "type" => "permission", "value" => "system.infra_tasks.control" } ],
    "required_approvals" => 1
  } ]
)
if ingress_chain.new_record? || ingress_chain.changed?
  ingress_chain.save!
  puts "  ✅ Ingress Manager Approval Chain: created/updated"
else
  puts "  ✅ Ingress Manager Approval Chain: already up to date"
end
