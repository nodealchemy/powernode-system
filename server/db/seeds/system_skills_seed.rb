# frozen_string_literal: true

# System extension — Ai::Skill catalog seed for the system executors.
#
# Each entry corresponds to a class at
# extensions/system/server/app/services/system/ai/skills/*_executor.rb.
# Seeding Ai::Skill records makes them discoverable via
# `platform.discover_skills` + bindable to agents via `Ai::AgentSkill`.
# Without this seed, executors exist as code but are invisible to the
# AI catalog.
#
# Category mapping note: the executor's internal `descriptor[:category]`
# uses tighter labels (`sdwan`, `runtime`, `fleet`) but the platform
# Ai::Skill model's category enum is fixed (devops, security,
# sre_observability, release_management, documentation, ...). We map
# each executor onto the closest platform category and stash the
# tighter system subdomain in `metadata.system_subdomain` for UI
# grouping.
#
# Idempotent: re-running the seed updates existing records by slug
# without duplicating.
#
# Spicy-bear plan slice 2.
#
# Invoke explicitly:
#   cd server && bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/system_skills_seed.rb')"

puts "\n  Seeding System extension AI skills catalog..."

account = Account.first
unless account
  puts "  ⚠️  No account — run platform seeds first; aborting"
  return
end

# ─────────────────────────────────────────────────────────────────────
# Skill metadata
# Each row corresponds to one System::Ai::Skills::*Executor class.
# - category: platform Ai::Skill enum value (NOT the executor's
#             internal category)
# - subdomain: finer-grained system subdomain stored in metadata
# - executor_class: fully-qualified class name (also in metadata)
# - system_prompt: short paragraph telling an LLM agent when to invoke
# ─────────────────────────────────────────────────────────────────────
SKILLS_DATA = [
  {
    name: "Attribute Failure",
    slug: "system-attribute-failure",
    description: "Given a failed NodeInstance, rank recent module changes + promotions by likelihood of being the cause",
    category: "sre_observability",
    subdomain: "fleet",
    executor: "System::Ai::Skills::AttributeFailureExecutor",
    tags: %w[fleet failure-analysis modules diagnostics],
    system_prompt: <<~PROMPT.strip
      Rank likely causes of a failed NodeInstance among recent module changes/promotions.
      Inputs: instance_id (required), lookback_hours (default 24).
      Returns ranked candidates with confidence score + reasoning.
    PROMPT
  },
  {
    name: "Capacity Recommend",
    slug: "system-capacity-recommend",
    description: "Recommend instance count or instance-type adjustments for a Template's fleet based on heartbeat health and assignment density",
    category: "sre_observability",
    subdomain: "fleet",
    executor: "System::Ai::Skills::CapacityRecommendExecutor",
    tags: %w[fleet capacity-planning autoscale],
    system_prompt: <<~PROMPT.strip
      Size a Template fleet — answers "do I have enough nodes" / "scale up or down".
      Inputs: template_id, target_min_active.
      Returns count delta + instance-type tweaks with a confidence label.
    PROMPT
  },
  {
    name: "CVE Response",
    slug: "system-cve-response",
    invocation_mode: "workflow_step",
    description: "Triage a CVE entry against the fleet — enumerates exposure, scores risk, proposes a remediation plan",
    category: "security",
    subdomain: "cve",
    executor: "System::Ai::Skills::CveResponseExecutor",
    tags: %w[cve security fleet exposure],
    system_prompt: <<~PROMPT.strip
      Triage a disclosed CVE — enumerate exposed modules/instances and plan remediation.
      Inputs: cve_id, severity, affected_packages.
      Returns risk score + impact-ranked remediation plan.
      Sets requires_approval=true when a plan touches >5% of the fleet.
    PROMPT
  },
  {
    name: "CVE Runbook Generate",
    slug: "system-cve-runbook-generate",
    description: "Generate a markdown remediation runbook for a CVE — exposed modules, recommended steps, verification commands",
    category: "security",
    subdomain: "cve",
    executor: "System::Ai::Skills::CveRunbookGenerateExecutor",
    tags: %w[cve security runbook documentation],
    system_prompt: <<~PROMPT.strip
      Generate a markdown CVE remediation playbook.
      Inputs: cve_id, persist_as_page (optional).
      Covers exposed modules, step-by-step remediation, and verification commands.
    PROMPT
  },
  {
    name: "CVE Remediation Orchestration",
    slug: "system-cve-remediation-orchestration",
    invocation_mode: "workflow_step",
    description: "Chain the full CVE → exposure → package refresh → rolling upgrade flow for one CVE",
    category: "security",
    subdomain: "cve",
    executor: "System::Ai::Skills::CveRemediationOrchestrationExecutor",
    tags: %w[cve security remediation orchestration autonomy],
    system_prompt: <<~PROMPT.strip
      Run the full CVE remediation chain once the CVE Responder agent decides to act
      (inline for critical-severity notify_and_proceed, or post-approval for require_approval).
      Inputs: cve_id (required), severity, affected_module_ids, exposure_ids (all optional).
      Triages via CveResponseExecutor, dispatches PackageModuleRefreshExecutor per linked module,
      plans rolling upgrades for modules with a newer blessed version, and transitions the
      CveExposure rows of the modules that actually got a dispatch to remediating.
      Modules that produced no plan are reported in skipped_modules with a reason; when nothing
      was dispatched and a module's fix is built but not promoted, the run returns failure naming
      the module and the candidate version an operator must promote.
    PROMPT
  },
  {
    name: "Docker Provision",
    slug: "system-docker-provision",
    invocation_mode: "workflow_step",
    description: "Provision a managed Docker daemon on a NodeInstance — auto-registers as a Devops::DockerHost on the SDWAN overlay",
    category: "devops",
    subdomain: "runtime",
    executor: "System::Ai::Skills::DockerProvisionExecutor",
    tags: %w[runtime docker container fleet],
    system_prompt: <<~PROMPT.strip
      Provision a managed Docker daemon on a NodeInstance that already has the
      docker-engine module assigned and an SDWAN peer attached.
      Inputs: node_instance_id, dry_run (optional).
      Returns the managed Devops::DockerHost row + endpoint.
      Idempotent — reuses an existing host, setting already_provisioned=true on re-call.
    PROMPT
  },
  {
    name: "Drift Remediate",
    slug: "system-drift-remediate",
    description: "Reconcile a NodeInstance's running modules against its assigned modules; returns a planned action set + estimated disruption %",
    category: "sre_observability",
    subdomain: "fleet",
    executor: "System::Ai::Skills::DriftRemediateExecutor",
    tags: %w[drift modules reconcile fleet],
    system_prompt: <<~PROMPT.strip
      Reconcile a NodeInstance's running modules against its assigned modules.
      Inputs: instance_id, max_disruption_pct (default 20).
      Returns planned attach/detach/update actions with a disruption percentage.
      Sets requires_approval=true when disruption exceeds the threshold.
    PROMPT
  },
  {
    name: "Federation Manager",
    slug: "system-federation-manager",
    description: "Survey federation peer + grant + cert health for an account and surface findings — feeds the SDWAN Manager autonomy loop and the operator dashboard",
    category: "sre_observability",
    subdomain: "sdwan",
    executor: "System::Ai::Skills::FederationManagerExecutor",
    tags: %w[federation sdwan peers grants certs health],
    system_prompt: <<~PROMPT.strip
      Survey federation health for the current account: peer cert rotation candidates,
      grants near expiry, grants overdue for review, broad-scope grants, capability drift.
      Inputs: none (account-scoped).
      Returns ranked findings for the operator or SDWAN Manager autonomy loop to action.
    PROMPT
  },
  {
    name: "Module Compose",
    slug: "system-module-compose",
    description: "Compose a Template draft from a workload description — keyword-matches modules and proposes a composition with conflict checks",
    category: "devops",
    subdomain: "modules",
    executor: "System::Ai::Skills::ModuleComposeExecutor",
    tags: %w[modules composition templates planning],
    system_prompt: <<~PROMPT.strip
      Draft a Template from a workload description (e.g. "nginx web server with TLS and metrics").
      Inputs: description (free text), platform_id (optional), max_modules.
      Returns a draft template with module candidates and any conflicts.
    PROMPT
  },
  {
    name: "Provision Cluster",
    slug: "system-provision-cluster",
    invocation_mode: "workflow_step",
    description: "Provision N instances of a Template in a region — composes create_node + provision_instance for each",
    category: "devops",
    subdomain: "fleet",
    executor: "System::Ai::Skills::ProvisionClusterExecutor",
    tags: %w[provisioning fleet templates batch],
    system_prompt: <<~PROMPT.strip
      Spin up N nodes from a Template in one shot.
      Inputs: template_id, count (1-50), provider_region_id,
      provider_instance_type_id, name_prefix, dry_run.
      Returns created nodes + provisioning task ids.
      For larger fleet rolls, use rolling_module_upgrade with explicit operator approval.
    PROMPT
  },
  {
    name: "Rolling Module Upgrade",
    slug: "system-rolling-module-upgrade",
    invocation_mode: "workflow_step",
    description: "Size a FLEET-ATOMIC module upgrade across all instances of a Template — PLAN ONLY, and the upgrade cannot be batched or staged",
    category: "release_management",
    subdomain: "modules",
    executor: "System::Ai::Skills::RollingModuleUpgradeExecutor",
    tags: %w[rolling-upgrade modules release fleet-atomic],
    system_prompt: <<~PROMPT.strip
      Size a module upgrade across a Template fleet. Inputs: template_id, module_id,
      target_version_id, max_consecutive_failures (default 2), health_timeout_sec.

      FLEET-ATOMIC. The version an instance receives resolves from
      NodeModule#current_version_id, a per-MODULE pointer, and the per-node
      assignment row carries no version column. So every instance carrying the
      module converges together and there is no batch size to choose. Do not offer
      the operator a percentage, a canary batch, or a paced rollout — none exist.

      PLAN ONLY: nothing in the platform executes this plan. Moving the fleet is a
      manual repoint of current_version_id (system_rollback_module_version, which
      moves the pointer in either direction). For genuine staging, separate the
      SCOPE instead: an instance pool, or a second NodeModule row with its own
      pointer. See docs/tutorials/06-rolling-upgrade.md.
    PROMPT
  },
  {
    name: "Runbook Generate",
    slug: "system-runbook-generate",
    description: "Generate a markdown operational runbook for a NodeTemplate — boot order, common failure modes, recovery procedures",
    category: "documentation",
    subdomain: "docs",
    executor: "System::Ai::Skills::RunbookGenerateExecutor",
    tags: %w[runbook documentation templates ops],
    system_prompt: <<~PROMPT.strip
      Generate a markdown operational runbook for a Template.
      Inputs: template_id, persist_as_page (optional).
      Covers boot order, failure modes, and recovery procedures.
    PROMPT
  },
  {
    name: "SDWAN BGP Session Remediate",
    slug: "system-sdwan-bgp-session-remediate",
    description: "Triage an unhealthy iBGP session; returns a plan with likely cause + recommended next step",
    category: "sre_observability",
    subdomain: "sdwan",
    executor: "System::Ai::Skills::SdwanBgpSessionRemediateExecutor",
    tags: %w[sdwan bgp routing diagnostics],
    system_prompt: <<~PROMPT.strip
      Triage an unhealthy iBGP session (idle/active/connect/etc.).
      Inputs: bgp_session_id OR (peer_id + neighbor_address).
      v1 returns analysis + recommended action only — does NOT auto-restart FRR.
    PROMPT
  },
  {
    name: "SDWAN Failover",
    slug: "system-sdwan-failover",
    description: "Plan an SDWAN hub failover for an unreachable network; identifies promotion candidates without auto-flipping",
    category: "sre_observability",
    subdomain: "sdwan",
    executor: "System::Ai::Skills::SdwanFailoverExecutor",
    tags: %w[sdwan failover hub topology],
    system_prompt: <<~PROMPT.strip
      Plan a hub failover for an SDWAN network whose hub is unreachable.
      Inputs: network_id, dry_run (default true; v1 plans only).
      Returns hub-candidate spokes ranked by last_handshake_at.
      Operator manually flips publicly_reachable after review.
    PROMPT
  },
  {
    name: "SDWAN Peer Remediate",
    slug: "system-sdwan-peer-remediate",
    description: "Rotate an SDWAN peer's keypair and force the agent to re-establish its tunnel on next reconcile",
    category: "sre_observability",
    subdomain: "sdwan",
    executor: "System::Ai::Skills::SdwanPeerRemediateExecutor",
    tags: %w[sdwan peers key-rotation tunnel],
    system_prompt: <<~PROMPT.strip
      Recover a degraded or stuck SDWAN peer.
      Inputs: peer_id, dry_run.
      Rotates the peer's WireGuard keypair so the agent re-establishes the tunnel
      from a clean key on its next reconcile.
    PROMPT
  },
  {
    name: "SDWAN Credential Refresh",
    slug: "system-sdwan-credential-refresh",
    description: "Re-issue an SDWAN peer's expiring membership credential server-side, without touching the WireGuard keypair",
    category: "sre_observability",
    subdomain: "sdwan",
    executor: "System::Ai::Skills::SdwanCredentialRefreshExecutor",
    tags: %w[sdwan credentials membership refresh],
    system_prompt: <<~PROMPT.strip
      Refresh an SDWAN peer's expiring membership credential.
      Inputs: peer_id, dry_run.
      Re-issues the MC server-side via the constellation signer so a fresh
      envelope is ready for the agent's next pull. Never rotates WireGuard
      keys — key rotation is drift/compromise remediation, not credential
      refresh.
    PROMPT
  },
  {
    name: "SDWAN VIP Failover",
    slug: "system-sdwan-vip-failover",
    description: "Promote the next failover candidate of a silent-holder Sdwan::VirtualIp. Anycast VIPs return informational only.",
    category: "sre_observability",
    subdomain: "sdwan",
    executor: "System::Ai::Skills::SdwanVipFailoverExecutor",
    tags: %w[sdwan vip failover anycast],
    system_prompt: <<~PROMPT.strip
      Promote the next failover candidate when an Sdwan::VirtualIp's holder peer goes silent.
      Inputs: virtual_ip_id, dry_run.
      Anycast VIPs return informational responses only (failover handled by routing).
    PROMPT
  },
  {
    name: "SDWAN OVN Compose Topology",
    slug: "system-sdwan-ovn-compose-topology",
    invocation_mode: "workflow_step",
    description: "Compose an OVN logical-network topology (deployment + logical switches + ports) for a heavyweight-profile account, then compile the ovn-nbctl plan",
    category: "devops",
    subdomain: "sdwan",
    executor: "System::Ai::Skills::SdwanOvnComposeTopologyExecutor",
    tags: %w[sdwan ovn topology heavyweight composition],
    system_prompt: <<~PROMPT.strip
      Compose an OVN logical-network topology in one shot. Heavyweight-profile accounts only.
      Inputs: switches (array of {name, cidr?, ports: [{name, kind, addresses?, host_node_instance_id?}]}),
      nb_db_endpoint + sb_db_endpoint (required only when no Sdwan::OvnDeployment exists for the account yet),
      northd_host (optional advisory hint), dry_run (default false).
      Returns the compiled ovn-nbctl plan to apply against the NB DB. Reuses the existing
      per-account OvnDeployment or creates one. Auto-activates new switches and ports so the
      compiler emits them in the same call.
    PROMPT
  },
  {
    name: "SDWAN Host Bridge Compose",
    slug: "system-sdwan-host-bridge-compose",
    invocation_mode: "workflow_step",
    description: "Allocate per-host SDWAN bridges (Linux for lightweight profile, OVS for heavyweight) for a set of NodeInstances. Composes Sdwan::HostBridgeAllocator. Idempotent.",
    category: "devops",
    subdomain: "sdwan",
    executor: "System::Ai::Skills::SdwanHostBridgeComposeExecutor",
    tags: %w[sdwan bridges allocation profile-aware composition],
    system_prompt: <<~PROMPT.strip
      Allocate per-host SDWAN bridges for a set of NodeInstances.
      Inputs: host_node_instance_ids (1-100), kind (optional explicit override:
      linux | ovs — wins over the host's network_profile when supplied), dry_run (default false).
      Returns allocated bridge ids + per-host allocations (bridge_name, kind, short_id, reused).
      Auto-selects OVS for heavyweight-profile hosts and Linux bridge for lightweight ones,
      so a mixed-profile fleet gets the right driver per host. Idempotent — re-running with
      the same hosts returns the existing bridges with reused=true.
    PROMPT
  },
  {
    name: "SDWAN IPFIX Collector Compose",
    slug: "system-sdwan-ipfix-collector-compose",
    invocation_mode: "workflow_step",
    description: "Register an IPFIX collector for an account so the topology compiler stamps ipfix exporter config onto every heavyweight (ovs-kind) HostBridge. Idempotent on (account, name). Composes Sdwan::IpfixCollector.",
    category: "devops",
    subdomain: "sdwan",
    executor: "System::Ai::Skills::SdwanIpfixCollectorComposeExecutor",
    tags: %w[sdwan ipfix telemetry heavyweight composition],
    system_prompt: <<~PROMPT.strip
      Register an IPFIX collector for an account.
      Inputs: name (unique per account; reused on re-execution),
      host (IPv4/IPv6/hostname — IPv6 brackets handled automatically),
      port (1-65535), sampling_rate (default 1 = every flow), dry_run (default false).
      Returns collector id + target_endpoint + is_winning_collector (true iff this is the row
      the topology compiler picks — only the oldest active collector per account gets stamped
      on heavyweight host bridges). Heavyweight-profile only; lightweight hosts ignore the ipfix payload.
      Idempotent on (account, name) — re-running with the same name returns the existing row
      without mutating host/port/sampling_rate.
    PROMPT
  },
  {
    name: "SDWAN Compose Full Topology",
    slug: "system-sdwan-compose-full-topology",
    invocation_mode: "workflow_step",
    description: "Composer-of-composers — orchestrates HostBridge + OVN + IPFIX composition in one tool call. Delegates to the three SDWAN compose primitives and aggregates outputs. Rollback unwinds in reverse dependency order.",
    category: "devops",
    subdomain: "sdwan",
    executor: "System::Ai::Skills::SdwanComposeFullTopologyExecutor",
    tags: %w[sdwan composition orchestration topology],
    system_prompt: <<~PROMPT.strip
      Compose a complete SDWAN topology in one tool call.
      Inputs: host_node_instance_ids (always required — passed to host_bridge_compose),
      kind (optional bridge kind override — passed through),
      ovn_topology (optional hash {nb_db_endpoint, sb_db_endpoint, northd_host?, switches} —
      runs ovn_compose_topology when supplied),
      ipfix_collector (optional hash {name, host, port, sampling_rate?} —
      runs ipfix_collector_compose when supplied), dry_run (default false).
      Always runs bridge composition; OVN and IPFIX are opt-in. Returns each sub-skill's
      structured data nested under outputs. Sub-failures are collected, never short-circuited,
      so the operator can retry just the failing phase. Single-call rollback delegates to each
      sub-executor's rollback in reverse order.
    PROMPT
  },
  {
    name: "SDWAN OVN Apply ACL",
    slug: "system-sdwan-ovn-apply-acl",
    invocation_mode: "workflow_step",
    description: "Apply OVN ACLs (firewall rules) to a logical switch — heavyweight-profile only. Composes Sdwan::OvnAcl entries scoped to one switch and re-compiles the deployment plan. Idempotent on (switch, acl_name).",
    category: "devops",
    subdomain: "sdwan",
    executor: "System::Ai::Skills::SdwanOvnApplyAclExecutor",
    tags: %w[sdwan ovn acl firewall heavyweight composition],
    system_prompt: <<~PROMPT.strip
      Apply OVN ACLs (firewall rules) to a logical switch.
      Inputs: logical_switch_id (must belong to the executing account),
      acls (array of {name, direction, priority?, match, action}, 1-100), dry_run (default false).
      direction: from-lport (egress from source) | to-lport (ingress to destination).
      action: allow | drop | reject | allow-related. priority: 0-32767, higher first, default 1000.
      match: OVN match expression like `ip4.src == 10.0.0.0/8 && tcp.dst == 5432`.
      Returns ovn_acl_ids + per-ACL allocations + the recompiled deployment plan with new acl-add commands.
      Idempotent on (switch, name) — re-running with the same name returns the existing ACL row
      without mutating its match/action/priority. Heavyweight-profile only (lightweight hosts use
      kube-proxy NetworkPolicy for the equivalent function).
    PROMPT
  },
  # ─── Package repository skills ─────────────────────────────────────
  {
    name: "Package Repository Sync",
    slug: "system-package-repository-sync",
    description: "Sync upstream apt/rpm metadata for one package repository",
    category: "devops",
    subdomain: "package-catalog",
    executor: "System::Ai::Skills::PackageRepositorySyncExecutor",
    tags: %w[packages apt rpm sync catalog],
    system_prompt: <<~PROMPT.strip
      Refresh synced apt/rpm package metadata for one PackageRepository.
      Inputs: repository_id (required).
      Returns upserted count + obsoleted (soft-deleted) count + new package_count.
      Cheap to run frequently; a daily cron triggers a fleet-wide sweep automatically.
    PROMPT
  },
  {
    name: "Package Module Create",
    slug: "system-package-module-create",
    invocation_mode: "workflow_step",
    description: "Materialize an apt/rpm package + transitive deps as NodeModule rows + ModuleDependency edges, then dispatch a CI build",
    category: "devops",
    subdomain: "package-catalog",
    executor: "System::Ai::Skills::PackageModuleCreateExecutor",
    tags: %w[packages modules build closure supply-chain],
    system_prompt: <<~PROMPT.strip
      Turn an apt/rpm package into a NodeModule.
      Inputs: repository_id, package_name (both required),
      architectures (optional, defaults to repo.architectures),
      recommends_selected (optional list of recommends package names to opt in),
      category_id (optional). Creates the top-level NodeModule + transitive dependency
      NodeModules (auto_generated=true) + ModuleDependency edges + dispatches a CI build.
      REQUIRES HUMAN APPROVAL — supply-chain critical.
    PROMPT
  },
  {
    name: "Package Module Refresh",
    slug: "system-package-module-refresh",
    invocation_mode: "workflow_step",
    description: "Re-materialize a package-sourced NodeModule when upstream package version drifts",
    category: "devops",
    subdomain: "package-catalog",
    executor: "System::Ai::Skills::PackageModuleRefreshExecutor",
    tags: %w[packages modules refresh drift cve],
    system_prompt: <<~PROMPT.strip
      Re-materialize a package-sourced NodeModule when PackageDriftSensor flags its upstream
      version bumped beyond the locally-materialized one. Replays persisted recommends_chosen
      for deterministic refreshes.
      Inputs: package_module_link_id (required), force (optional).
      CVE-flagged drifts auto-approve; non-CVE drifts require human approval.
    PROMPT
  },
  # ─── Architecture catalog skills ───────────────────────────────────
  {
    name: "Architecture Propose",
    slug: "system-architecture-propose",
    description: "Propose adding a new architecture to the platform-wide catalog (creates an Ai::AgentProposal for human review)",
    category: "devops",
    subdomain: "architecture-catalog",
    executor: "System::Ai::Skills::ArchitectureProposeExecutor",
    tags: %w[architecture catalog proposal fleet],
    system_prompt: <<~PROMPT.strip
      Propose a new CPU architecture for the platform-wide catalog without holding the manage permission.
      Inputs: name (required, e.g. loongarch64),
      family (required, one of: x86, arm, power, z, risc-v, mips, other),
      apt_name, rpm_name, display_name, description, justification.
      Creates an Ai::AgentProposal row — the architecture is NOT materialized until an operator approves.
    PROMPT
  },
  {
    name: "Architecture Create",
    slug: "system-architecture-create",
    description: "Directly create a custom (non-canonical) architecture in the platform-wide catalog. Requires manage permission and surfaces for operator approval.",
    category: "devops",
    subdomain: "architecture-catalog",
    executor: "System::Ai::Skills::ArchitectureCreateExecutor",
    tags: %w[architecture catalog create fleet],
    system_prompt: <<~PROMPT.strip
      Directly create a custom architecture. Requires the system.architectures.manage permission.
      Inputs: name (required), family (required), apt_name, rpm_name,
      display_name, description, enabled, public.
      The created row is always is_canonical=false — agents can't fabricate canonicals.
      Each call surfaces for operator confirmation via the intervention policy.
    PROMPT
  },
  {
    name: "Architecture Update",
    slug: "system-architecture-update",
    description: "Update a non-canonical architecture's fields. Canonical rows are immutable.",
    category: "devops",
    subdomain: "architecture-catalog",
    executor: "System::Ai::Skills::ArchitectureUpdateExecutor",
    tags: %w[architecture catalog update fleet],
    system_prompt: <<~PROMPT.strip
      Update a non-canonical architecture's fields.
      Inputs: architecture_id (required), attributes (required hash of allowed keys:
      name, family, apt_name, rpm_name, display_name, description, kernel_options, enabled, public).
      Canonical rows are immutable and return an error.
    PROMPT
  },
  {
    name: "Architecture Delete",
    slug: "system-architecture-delete",
    description: "Delete a non-canonical architecture. Fails if any NodePlatform still references it. Canonical rows are immutable.",
    category: "devops",
    subdomain: "architecture-catalog",
    executor: "System::Ai::Skills::ArchitectureDeleteExecutor",
    tags: %w[architecture catalog delete fleet],
    system_prompt: <<~PROMPT.strip
      Delete a non-canonical architecture from the platform-wide catalog.
      Inputs: architecture_id (required).
      Fails if any NodePlatform references it (restrict_with_error dependency).
      Canonical rows are immutable and return an error.
    PROMPT
  },
  # ─── T2.B ────────────────────────────────────────────────────────────
  {
    name: "Suggest Architectures for Fleet",
    slug: "system-suggest-architectures-for-fleet",
    description: "Suggest which canonical architectures to materialize a package for, based on the fleet's current NodePlatform coverage and the repository's served architectures.",
    category: "devops",
    subdomain: "package-catalog",
    executor: "System::Ai::Skills::SuggestArchitecturesForFleetExecutor",
    tags: %w[architecture fleet packages materialize suggestion],
    system_prompt: <<~PROMPT.strip
      Suggest which canonical architectures to materialize a package for. Call BEFORE
      system-package-module-create when the operator hasn't specified architectures.
      Inputs: repository_id (required), max_suggestions (1-7, default 4).
      Returns the architectures best-matching the fleet — the intersection of (repo's served archs,
      arches with non-zero fleet NodePlatform coverage), ranked by NodePlatform count.
      Falls back to repo defaults with `fallback: true` + low confidence when there's no fleet overlap.
      Use the per-arch `rationale` array to explain the recommendation.
    PROMPT
  },
  # ─── Wrapper skills for inventory/inspection MCP actions ─────────────
  # These exist so natural-language inventory queries ("how many X?",
  # "what X are configured?") surface in skill discovery. The router can
  # then auto-invoke them for chat surfaces that lack direct MCP tool access.
  {
    name: "List Package Repositories Summary",
    slug: "system-list-package-repositories-summary",
    description: "Summarize package repositories — counts, kinds (apt/rpm/dnf), visibility, sync status. Use for 'how many package repos', 'what package sources are configured', 'list my apt repositories'.",
    category: "devops",
    subdomain: "package-catalog",
    executor: "System::Ai::Skills::ListPackageRepositoriesSummaryExecutor",
    tags: %w[inventory packages repositories summary],
    system_prompt: <<~PROMPT.strip
      Answer any package-repository inventory query ("how many", "what kinds",
      "list them", "what's configured").
      Returns total count, breakdown by kind (apt/rpm/dnf), visibility (shared vs account),
      sync status, and the full list. Always prefer this over a generic "look elsewhere" reply.
    PROMPT
  },
  # ─── Intent-based package discovery (semantic) ───────────────────────
  {
    name: "Discover Packages By Intent",
    slug: "system-discover-packages-by-intent",
    description: "Semantic package discovery — given a free-text capability need ('reverse proxy', 'distributed cache'), returns ranked packages from accessible repositories sorted by cosine similarity.",
    category: "devops",
    subdomain: "package-catalog",
    executor: "System::Ai::Skills::DiscoverPackagesByIntentExecutor",
    tags: %w[packages discovery semantic intent catalog embedding],
    system_prompt: <<~PROMPT.strip
      Semantic package discovery for when the operator describes a capability NEED, not a
      package NAME ("I need a reverse proxy", "find me an in-memory cache").
      Inputs: intent (required free-text), repository_ids (optional), kind (apt|rpm|dnf),
      architectures (canonical names — cross-kind expanded), license (exact match), top_k (1-50, default 10).
      Returns ranked packages with similarity scores + per-result reasoning + an overall
      confidence label (high/medium/low). Use system-search-packages INSTEAD when the operator
      knows the package name and just wants to filter/browse — search is faster for keyword queries.
    PROMPT
  },
  # ─── Platform maintenance (D2-ext.1) ───────────────────────────────
  {
    name: "Platform Maintenance",
    slug: "system-platform-maintenance",
    description: "Routine platform maintenance: cert renewal/rotation, drift checks, health snapshots. Action-discriminated: cert_status, cert_rotate, drift_check, health_check.",
    category: "devops",
    subdomain: "platform-deployment",
    executor: "System::Ai::Skills::PlatformMaintenanceExecutor",
    invocation_mode: "one_shot",
    tags: %w[platform maintenance certificates renewal drift health],
    system_prompt: <<~PROMPT.strip
      ROUTINE platform care only — NOT incident response (use platform_resilience),
      NOT new deployments (use platform_deploy).

      Action-discriminated; pick the branch:
        - cert_status   → "are my certs healthy?" / "what's expiring?"
        - cert_rotate   → "rotate the cert for X" / "renew everything expiring"
        - drift_check   → "any drift on my deployments?"
        - health_check  → "what's the platform's overall health?"

      Each branch is read-only or triggers an async background job — none block on long work;
      returns immediately with structured recommendations.
    PROMPT
  },

  # ─── Platform resilience / incident response (D2-ext.2) ────────────
  {
    name: "Platform Resilience",
    slug: "system-platform-resilience",
    description: "Incident response — drain a misbehaving instance, scale a deployment up or down, or triage cross-platform stress (stale peers, errored instances). Action-discriminated.",
    category: "devops",
    subdomain: "platform-deployment",
    executor: "System::Ai::Skills::PlatformResilienceExecutor",
    invocation_mode: "one_shot",
    tags: %w[platform resilience drain scale failover incident],
    system_prompt: <<~PROMPT.strip
      Incident response when something misbehaves or capacity is under pressure —
      "drain X", "scale up", "what's wrong with the fleet", "any unhealthy peers".

      Action-discriminated:
        - drain_instance  → cordon + drain a specific NodeInstance
        - scale           → mutate target_replicas (set | increment | decrement)
        - failover_check  → read-only triage of stress signals

      Prefer failover_check first for vague problems — it's the safe diagnostic call.
      Use mutation branches (drain_instance, scale) only after confirming the failing
      component AND getting operator agreement.
    PROMPT
  },

  # ─── Platform deployment (D2) ──────────────────────────────────────
  {
    name: "Platform Deploy",
    slug: "system-platform-deploy",
    description: "Deploy a new standalone Powernode platform. No params returns a wizard payload of form fields; full params call System::PlatformDeploymentOrchestrator to provision end-to-end. Federated spawns are refused here — they mint an acceptance token this surface cannot deliver.",
    category: "devops",
    subdomain: "platform-deployment",
    executor: "System::Ai::Skills::PlatformDeployExecutor",
    invocation_mode: "workflow_step",
    tags: %w[platform deployment provisioning federation standalone],
    system_prompt: <<~PROMPT.strip
      Spin up a new Powernode platform — "deploy a new platform", "spin up another hub",
      "stand up a standalone instance".

      Only standalone deployment runs here: a sovereign platform with no FederationPeer
      relationship. It comes up with its own admin account from the first-run handler,
      and requests its own ACME cert if public_dns_hostname is set (signable within
      ~5 minutes).

      No parameters returns a wizard payload; the frontend renders an inline form.
      After submit, call AGAIN with mode=standalone + name.

      DO NOT attempt mode=federated here — it is refused. A federated spawn mints a
      single-use acceptance token, and everything this skill returns is forwarded to
      the model provider and stored with the conversation, so the token cannot be
      delivered here. Tell the operator to deploy federated platforms from the Deploy
      Platform page (or POST /api/v1/system/platform/deployments), which runs the same
      orchestrator and shows the acceptance_token once in its response.

      Deploy mode provisions real infrastructure — confirm with the operator first.
      The wizard phase is a safe no-op; use it generously to surface the form.
    PROMPT
  },

  # ─── Ingress / public exposure (north-star) ────────────────────────
  {
    name: "ACME Certificate Provision",
    slug: "system-acme-certificate-provision",
    description: "Issue a new ACME TLS certificate for the platform's public listeners — creates the record and drives issuance via the ACME server. Inputs: common_name, sans, issuer, challenge_type, dns_credential_id (dns-01 only), acme_email.",
    category: "devops",
    subdomain: "platform-deployment",
    executor: "System::Ai::Skills::AcmeCertificateProvisionExecutor",
    invocation_mode: "one_shot",
    tags: %w[platform acme certificates tls issuance provision],
    system_prompt: <<~PROMPT.strip
      Obtain a NEW TLS certificate for a hostname.
      Inputs: common_name, issuer (letsencrypt-prod | letsencrypt-staging | internal-ca),
      challenge_type (dns-01 | http-01 | tls-alpn-01).
      dns-01 REQUIRES dns_credential_id (a System::AcmeDnsCredential).
      To renew/rotate an EXISTING cert, use platform_maintenance (action=cert_rotate).
    PROMPT
  },
  {
    name: "Reverse Proxy Compose",
    slug: "system-reverse-proxy-compose",
    description: "Regenerate the reverse-proxy (Traefik) dynamic config for a certificate's account from its valid certs, bringing its HTTPS routers online. Traefik file-watches and reloads automatically.",
    category: "devops",
    subdomain: "platform-deployment",
    executor: "System::Ai::Skills::ReverseProxyComposeExecutor",
    invocation_mode: "one_shot",
    tags: %w[platform reverse-proxy traefik certificates routing],
    system_prompt: "(Re)generate the Traefik dynamic config for the account owning a given valid certificate, bringing its HTTPS routers online. Input: certificate_id (must be status=valid). Regenerate-only — emits the account's dynamic YAML; does not change proxy backend/frontend URLs or env."
  },
  {
    name: "Expose Service Publicly",
    slug: "system-expose-service-publicly",
    description: "Expose a backend service to the public internet end-to-end: provisions an SDWAN Virtual IP, a hub DNAT port mapping (443 https / 80 http), an ACME TLS certificate, and regenerates the reverse proxy.",
    category: "devops",
    subdomain: "platform-deployment",
    executor: "System::Ai::Skills::ExposeServicePubliclyExecutor",
    invocation_mode: "one_shot",
    tags: %w[platform sdwan vip port-mapping acme reverse-proxy expose public],
    system_prompt: "Make an internal backend service reachable from the public internet at a hostname with TLS. Chains an SDWAN Virtual IP + hub DNAT port mapping (443/80) + ACME certificate + reverse-proxy regeneration into one approval-gated step."
  },
  {
    name: "Expose Service Locally",
    slug: "system-expose-service-local",
    description: "Expose a backend service locally at /svc/<slug> on the platform's own host(s), authenticated by the reverse proxy (ForwardAuth). Creates/updates the Sdwan::Service, enables its local-exposure facet, and regenerates the proxy.",
    category: "devops",
    subdomain: "platform-deployment",
    executor: "System::Ai::Skills::ExposeServiceLocalExecutor",
    invocation_mode: "one_shot",
    tags: %w[platform sdwan service expose local forward-auth reverse-proxy svc],
    system_prompt: "Publish an internal/overlay service to the site's OWN authenticated users at a /svc/<slug> path (NOT the public internet — use Expose Service Publicly for that). Creates/updates an Sdwan::Service, turns on its local-exposure facet (auth mode public/authenticated/scoped), and regenerates the reverse proxy. Approval-gated."
  },
  {
    name: "Expose Service Public TCP",
    slug: "system-expose-service-public-tcp",
    description: "Toggle a backend service's public (Path B) TLS-carrying TCP exposure via Traefik HostSNI routing — validates protocol tls, a resolvable host, and (under edge_mode terminate) a matching valid ACME certificate before enabling; disabling has no preconditions.",
    category: "devops",
    subdomain: "platform-deployment",
    executor: "System::Ai::Skills::ExposeServicePublicTcpExecutor",
    invocation_mode: "one_shot",
    tags: %w[platform sdwan service expose public path-b tls tcp traefik hostsni reverse-proxy],
    system_prompt: "Enable or disable a service's public Path B (TLS-carrying TCP via Traefik SNI) exposure. EXPOSE (enabled: true, default) validates protocol tls, a resolvable HostSNI host, and — under edge_mode terminate — a matching valid ACME certificate, then flips Sdwan::Service#public_enabled on and regenerates the reverse proxy. UNEXPOSE (enabled: false) simply disables it. NOT for HTTP(S) (use Expose Service Publicly) or the site-local /svc plane (use Expose Service Locally). Approval-gated in both directions."
  },
  # ─── Phase 3 (Federation & Multi-Site) — SDWAN-first federation ────────
  # Five executors landed in Phase 3. Their descriptors all declare the
  # tighter internal category "federation"; the platform Ai::Skill enum has
  # no such value, so they map onto the closest enum category (the SDWAN
  # composers → devops, matching system-sdwan-compose-full-topology; the
  # liveness remediation reconciler → sre_observability, matching the other
  # system-sdwan-*-remediate rows). The "federation" subdomain preserves the
  # finer grouping in metadata for UI.
  {
    name: "Federation Acceptance",
    slug: "system-federation-acceptance",
    invocation_mode: "one_shot",
    description: "Complete a federation handshake from a single-use acceptance token — runs the full accept chain: accept transition, platform enroll, managed-child operator grant, node_api bootstrap-token issuance, SDWAN overlay attach, federation governance health scan.",
    category: "devops",
    subdomain: "federation",
    executor: "System::Ai::Skills::FederationAcceptanceExecutor",
    tags: %w[federation sdwan acceptance handshake peer multi-site],
    system_prompt: <<~PROMPT.strip
      Complete a federation handshake from a single-use acceptance token (held after a peer was proposed).
      Inputs: acceptance_token (required — consumed on success),
      contract_version (required — a supported version, currently [1]),
      capabilities (optional), extension_slugs (optional),
      endpoints (optional array of { url, scope, priority, cidr_hint? }).
      Runs the accept chain synchronously: accept transition → platform enroll → managed-child
      operator grant → node_api bootstrap-token issuance → SDWAN overlay attach → governance health scan.
      APPROVAL-GATED (federation peering is sensitive). Returns peer_id, status, peer_kind,
      contract_version_agreed, node_enrollment, sdwan_attach, governance, and any warnings from
      the soft post-accept steps.
    PROMPT
  },
  {
    name: "SDWAN Federation Compose",
    slug: "system-sdwan-federation-compose",
    invocation_mode: "workflow_step",
    description: "Stand up a federation overlay topology (hub-and-spoke OR full-mesh) — composes per-peer Sdwan::PeerEnroller + Sdwan::TopologyCompiler + Sdwan::Bgp::RoutePolicyCompiler. Creates one Sdwan::Network, enrolls each member as a peer (hubs publicly_reachable), compiles the per-peer WireGuard + FRR route-policy envelope. Reverse-order rollback tears down peers then the network.",
    category: "devops",
    subdomain: "federation",
    executor: "System::Ai::Skills::SdwanFederationComposeExecutor",
    tags: %w[sdwan federation composition topology multi-site],
    system_prompt: <<~PROMPT.strip
      Compose a federation overlay across instances.
      Inputs: network_name (required), topology (required — "hub_and_spoke" or "full_mesh"),
      peers (required array — each {node_instance_id (required), role: "hub"|"spoke" for hub_and_spoke,
      endpoint_host_v6/v4 + endpoint_port for hubs, lan_subnets, bgp_route_reflector_client}),
      routing_protocol (optional — "static" default or "ibgp"), dry_run (default false).
      hub_and_spoke requires >=1 hub and every hub needs an endpoint; full_mesh has no hub/spoke split.
      Returns sdwan_network_id, sdwan_peer_ids, hub_peer_ids, topology_preview (per-peer WG view),
      and route_policy_preview (per-peer FRR route-maps; meaningful for ibgp).
      Failures are collected, not short-circuited. Single-call rollback destroys peers in reverse
      enrollment order then the network.
    PROMPT
  },
  {
    name: "Multi-Tenant Isolation",
    slug: "system-multi-tenant-isolation",
    invocation_mode: "one_shot",
    description: "Provision a fully-isolated SDWAN network slice for one tenant in the account: a dedicated overlay network with its own VRF + isolated iBGP RIB (no shared routing table), a non-overlapping /64 (Sdwan::PrefixAllocator), default-deny nftables rules scoped to the tenant CIDR, an OVN logical switch, and tenant-CIDR OVN ACLs. SDWAN-native — no k8s NetworkPolicy, no VLAN.",
    category: "devops",
    subdomain: "federation",
    executor: "System::Ai::Skills::MultiTenantIsolationExecutor",
    tags: %w[sdwan federation isolation tenant ovn nftables multi-site],
    system_prompt: <<~PROMPT.strip
      Isolate a tenant — "isolate tenant <X>", "give <tenant> its own segregated network",
      "stand up a blast-radius boundary for <tenant>".
      Inputs: tenant_key (required — slug-safe identifier), network_name (optional),
      tenant_cidr (optional — defaults to the auto-allocated /64),
      nb_db_endpoint + sb_db_endpoint (required only when the account has no Sdwan::OvnDeployment yet),
      ovn_switch_name (optional), dry_run (default false).
      Composes a VRF-isolated Sdwan::Network (ibgp) + PrefixAllocator /64 + default-deny nftables rules
      + an OVN logical switch + tenant-CIDR OVN ACLs, entirely on the SDWAN overlay.
      APPROVAL-GATED (high blast radius). Reverse-order rollback: ACLs → switch → firewall rules → network.
    PROMPT
  },
  {
    name: "Service Discovery Composer",
    slug: "system-service-discovery-composer",
    invocation_mode: "one_shot",
    description: "Make a backend service discoverable across the fleet over the SDWAN overlay — provisions a Virtual IP (auto-advertised via iBGP for in-overlay discovery), publishes a VIP-backed federation service-catalog offering for federated peers, regenerates the local Traefik routes, and OPTIONALLY publishes a public DNS record (A/AAAA/CNAME) for internet-facing names.",
    category: "devops",
    subdomain: "federation",
    executor: "System::Ai::Skills::ServiceDiscoveryComposerExecutor",
    tags: %w[sdwan federation discovery service-catalog dns multi-site],
    system_prompt: <<~PROMPT.strip
      Make a service discoverable — "make <service> discoverable",
      "publish <service> to the service catalog", "advertise <service> to other sites".
      Inputs: service_name + service_slug (required),
      sdwan_network_id + backend_peer_id + backend_port + vip_cidr (required),
      protocol (optional — https default), grant_scopes / grant_ttl_days (optional),
      traefik_dynamic_dir (optional),
      public_dns (optional, INTERNET-FACING only — { dns_credential_id, record_name, record_type?, record_content?, ttl? }).
      Discovery rides the SDWAN overlay: the VIP is auto-advertised via iBGP and a VIP-backed
      Federation::ServiceOffering lets federated peers subscribe. External DNS is the only
      non-overlay substrate and is soft (a failure is a warning).
      APPROVAL-GATED. Reverse-order rollback: DNS record → offering → VIP.
    PROMPT
  },
  {
    name: "Federation Peer Remediate",
    slug: "system-federation-peer-remediate",
    invocation_mode: "one_shot",
    description: "Remediate a stale or cert-expiring federation peer: re-handshake a stale peer over mTLS (recovering it if reachable), degrade an unreachable active peer, or alert the operator that a federation cert needs operator-driven rotation. Invoked by the fleet DecisionEngine off the FederationPeerLivenessSensor.",
    category: "sre_observability",
    subdomain: "federation",
    executor: "System::Ai::Skills::FederationPeerRemediateExecutor",
    tags: %w[federation sdwan peers liveness remediation heartbeat certs],
    system_prompt: <<~PROMPT.strip
      Remediate a stale or cert-expiring federation peer.
      Inputs: federation_peer_id (required),
      reason (optional — heartbeat_stale | cert_expiring | cert_expired, default heartbeat_stale),
      dry_run (default false).
      heartbeat_stale re-handshakes over mTLS (a reachable peer self-recovers via its inbound heartbeat;
      an unreachable active peer is degraded; a non-degradable peer is alerted).
      cert_expiring/cert_expired alert the operator — federation cert rotation is operator-driven
      (cross-CA handshake), never auto-rotated. Every branch emits a FleetEvent.
      The SDWAN Manager autonomy loop invokes this off the FederationPeerLivenessSensor;
      also operator-runnable.
    PROMPT
  },

  # ─────────────────────────────────────────────────────────────────────
  # On-demand fulfillment chain (IMP-d4fc286b7ccf).
  #
  # These THREE executors declare `binds_to` but had no Ai::Skill row anywhere
  # in the seed run. That is worse than three invisible skills:
  # `system_skill_bindings_seed.rb` calls `SkillBindings.validate!` UNRESCUED
  # before creating any binding, so ONE missing row aborts the entire bindings
  # seed and leaves ZERO Ai::AgentSkill rows for EVERY system agent. That is
  # what made the end-to-end "purpose → node" orchestration
  # (fulfill_capability_request) unreachable.
  #
  # The other six `binds_to` executors that look missing from THIS file
  # (provision_full_stack, deploy_app_code, attach_storage, scale_project,
  # relocate_workload, configure_sdwan_for_project) are NOT missing — they are
  # seeded by `system_provisioning_skills_seed.rb`, which db/seeds.rb runs
  # immediately after this file and before the bindings seed. Do not re-add them
  # here: both files upsert by slug, so the later provisioning seed would
  # silently clobber a copy added here and leave two sources of truth.
  # ─────────────────────────────────────────────────────────────────────
  {
    name: "Fulfill Capability Request",
    slug: "system-fulfill-capability-request",
    invocation_mode: "workflow_step",
    description: "On-demand: turn a natural-language capability request into a running, leased instance. Composes reusable modules, detects gaps, and creates a DURABLE System::FulfillmentRequest with the plan FROZEN — approval is an out-of-band transition on the persisted row, never a re-composition.",
    category: "devops",
    subdomain: "fleet",
    executor: "System::Ai::Skills::FulfillCapabilityRequestExecutor",
    tags: %w[fulfillment on-demand provisioning modules lease orchestration],
    system_prompt: <<~PROMPT.strip
      Turn "give me a running <X>" into an actual leased instance.
      Inputs: request (required, free-form), count (default 1, capped by
      SiteSetting system.fulfill.max_instances), approved (default false),
      base_os_module_name, platform_id, provider_region_id, provider_instance_type_id.
      Returns fulfillment_request_id + state + the composed plan.
      APPROVAL-GATED, high blast radius. The plan is FROZEN at compose time:
      approving releases exactly those bytes (the TOCTOU fix). Interactive callers
      leave it in `composed` and approve out-of-band via
      POST /api/v1/system/fulfillment_requests/:id/approve; the sweep
      (System::FulfillmentRequestSweepService) then carries it to `ready`.
      Gaps with no materializable package become plan["unresolved_gaps"] and are
      never dropped. On the autonomous (approved: true) path they additionally
      block inline approval and are parked on the row; on the interactive path
      nothing is parked — the gaps live only in plan["unresolved_gaps"], which is
      what the operator is deciding about when they approve.
    PROMPT
  },
  {
    name: "Module Smoke Verify",
    slug: "system-module-smoke-verify",
    description: "Compose a newly-built module onto a pooled instance atop base-os and assert it is actually healthy (systemd unit active, manifest health endpoint answers, ldd closure complete)",
    category: "devops",
    subdomain: "modules",
    executor: "System::Ai::Skills::ModuleSmokeVerifyExecutor",
    tags: %w[modules smoke verification health builds],
    system_prompt: <<~PROMPT.strip
      Prove a freshly-built module actually works before trusting it.
      Inputs: module_name OR module_id (one required), base_os_module_name,
      template_id (optional), instance_id (optional).
      Omit instance_id to self-acquire an ephemeral pool member (released afterward);
      pass instance_id to verify a CALLER-OWNED instance in place — that instance is
      never released or terminated (this is the path the fulfillment orchestrator uses
      on its leased instance).
      Returns ok + per-check results. Read-shape: no approval required.
    PROMPT
  },
  {
    name: "Boot Image Drift Rollout",
    slug: "system-boot-image-drift-rollout",
    description: "Plan a canary-first, halt-on-failure in-place boot-image upgrade across all drifted instances on a node platform, converging the fleet onto the promoted image",
    category: "devops",
    subdomain: "fleet",
    executor: "System::Ai::Skills::BootImageDriftRolloutExecutor",
    tags: %w[fleet boot-image drift rollout canary upgrades],
    system_prompt: <<~PROMPT.strip
      Converge a platform's fleet onto its promoted boot image after a drift signal.
      Inputs: instance_id (required — a drifted instance; the rollout resolves its
      platform and all drifted siblings), batch_pct (default 10),
      max_consecutive_failures (default 1), dry_run (default false).
      Canary-first: batch 0 is the canary. HALTS on a recent failed upgrade, an
      in-flight upgrade, or a platform preflight blocker (no promoted UKI / no cosign
      key) rather than dispatching a silent no-op.
      Convergence is tick-driven — each approved batch upgrades a slice and the next
      sensor tick re-plans the remainder.
      APPROVAL-GATED: reboots every drifted node on the platform, batch by batch.
    PROMPT
  },
].freeze

# ─────────────────────────────────────────────────────────────────────
# Upsert skills (idempotent)
# ─────────────────────────────────────────────────────────────────────
created_count = 0
updated_count = 0

SKILLS_DATA.each do |data|
  skill = ::Ai::Skill.find_or_initialize_by(slug: data[:slug])
  was_new = skill.new_record?
  skill.assign_attributes(
    account: account,
    name: data[:name],
    description: data[:description],
    category: data[:category],
    status: "active",
    system_prompt: data[:system_prompt],
    commands: [],
    activation_rules: {},
    metadata: {
      "author" => "system_extension",
      "icon" => data[:subdomain],
      "system_subdomain" => data[:subdomain],
      "executor_class" => data[:executor],
      # === ConciergeRouter signals ===
      # Domain is "system" for every skill in this extension's seed file —
      # extensions own their domain naming via Ai::Skill.register_domain
      # in engine.rb. invocation_mode defaults to one_shot; flip to
      # workflow_step on skills that require multi-step operator follow-up.
      "domain" => "system",
      "invocation_mode" => data[:invocation_mode] || "one_shot"
    },
    tags: data[:tags] + %w[system workspace],
    is_system: true,
    is_enabled: true,
    version: "1.0.0"
  )
  skill.save!
  was_new ? created_count += 1 : updated_count += 1
end

puts "    ✓ Skills: #{created_count} created, #{updated_count} updated (#{SKILLS_DATA.size} total system extension skills)"

# Agent ↔ skill bindings live in `system_skill_bindings_seed.rb`, which
# walks the SkillBindings registry (populated by each executor's
# `binds_to "Agent Name"` DSL call) and creates Ai::AgentSkill rows.
# That seed is the single source of truth — this file only creates the
# Ai::Skill rows above.

puts "  Done seeding System extension AI skills."
