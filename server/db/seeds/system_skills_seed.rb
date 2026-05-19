# frozen_string_literal: true

# System extension — Ai::Skill catalog seed for the 14 system executors.
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
      Use this skill when a NodeInstance has failed and an operator wants to know
      which recent module change or promotion likely caused it. Inputs: instance_id
      (required), lookback_hours (default 24). Returns ranked candidates with a
      confidence score + reasoning.
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
      Use this skill when an operator asks "do I have enough nodes" or "should I
      scale up/down" for a Template fleet. Inputs: template_id, target_min_active.
      Returns a sized recommendation (count delta, instance type tweaks) with a
      confidence label.
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
      Use this skill when a CVE has been disclosed and operators need to know which
      modules/instances are exposed. Inputs: cve_id, severity, affected_packages.
      Returns risk score + remediation plan (ranked by impact). Sets
      requires_approval=true for plans that touch >5% of the fleet.
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
      Use this skill when an operator asks for a written CVE remediation playbook.
      Inputs: cve_id, persist_as_page (optional). Generates markdown covering
      exposed modules, step-by-step remediation, and verification commands.
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
      Use this skill when the CVE Responder agent has decided to act on a
      CVE (either inline for critical-severity notify_and_proceed, or after
      operator approval for require_approval). Inputs: cve_id (required),
      severity (optional), affected_module_ids (optional), exposure_ids
      (optional). Triages via CveResponseExecutor, dispatches
      PackageModuleRefreshExecutor for each linked module, plans rolling
      upgrades for any module that already has a newer blessed version, and
      transitions named CveExposure rows to remediating state.
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
      Use this skill when an operator asks to provision Docker on a NodeInstance
      that already has the docker-engine module assigned + an SDWAN peer attached.
      Inputs: node_instance_id, dry_run (optional). Returns the managed
      Devops::DockerHost row + endpoint. Idempotent — already_provisioned=true on
      re-call. Prefers existing host over re-creation.
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
      Use this skill when a NodeInstance's running modules don't match its assigned
      modules. Inputs: instance_id, max_disruption_pct (default 20). Returns
      planned attach/detach/update actions with a disruption percentage. Sets
      requires_approval=true if the disruption exceeds the threshold.
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
      Use this skill to survey federation health for an account — peer cert
      rotation candidates, grants approaching expiry, grants overdue for
      review, broad-scope grants, capability drift. Inputs: none (scoped
      to current account). Returns ranked findings the operator or SDWAN
      Manager autonomy loop should action.
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
      Use this skill when an operator describes a workload (e.g. "nginx web server
      with TLS and metrics") and wants a Template draft. Inputs: description (free
      text), platform_id (optional), max_modules. Returns a draft template with
      module candidates and any conflicts.
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
      Use this skill when an operator wants to spin up N nodes from a Template in
      one shot. Inputs: template_id, count (1-50), provider_region_id,
      provider_instance_type_id, name_prefix, dry_run. Returns created nodes +
      provisioning task ids. For larger fleet rolls, use rolling_module_upgrade
      with explicit operator approval instead.
    PROMPT
  },
  {
    name: "Rolling Module Upgrade",
    slug: "system-rolling-module-upgrade",
    invocation_mode: "workflow_step",
    description: "Plan a batched rolling upgrade of a NodeModule across all instances of a Template, with circuit-breaker and health gating",
    category: "release_management",
    subdomain: "modules",
    executor: "System::Ai::Skills::RollingModuleUpgradeExecutor",
    tags: %w[rolling-upgrade modules release circuit-breaker],
    system_prompt: <<~PROMPT.strip
      Use this skill when an operator wants to upgrade a NodeModule across a
      Template fleet without taking everyone down. Inputs: template_id, module_id,
      target_version_id, batch_pct (default 10%), max_consecutive_failures (default
      2), health_timeout_sec. Returns a plan with batches + circuit-breaker config.
      Skill returns the plan; the autonomy reconciler executes it batch-by-batch.
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
      Use this skill when an operator asks for a written runbook for a Template.
      Inputs: template_id, persist_as_page (optional). Generates markdown covering
      boot order, failure modes, and recovery procedures.
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
      Use this skill when an iBGP session is unhealthy (idle/active/connect/etc.).
      Inputs: bgp_session_id OR (peer_id + neighbor_address). v1 returns analysis +
      recommended action only — does NOT auto-restart FRR.
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
      Use this skill when an SDWAN network's hub is unreachable. Inputs: network_id,
      dry_run (default true; v1 only supports planning). Returns hub-candidate
      spokes ranked by last_handshake_at. Operator manually flips publicly_reachable
      after review.
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
      Use this skill when an SDWAN peer is degraded or stuck. Inputs: peer_id,
      dry_run. Rotates the peer's WireGuard keypair so the agent re-establishes the
      tunnel from a clean key on its next reconcile.
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
      Use this skill when an Sdwan::VirtualIp's holder peer goes silent. Inputs:
      virtual_ip_id, dry_run. Promotes the next failover candidate to active
      holder. Anycast VIPs return informational responses only (failover handled
      by routing).
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
      Use this skill on heavyweight-profile accounts to compose an OVN
      logical-network topology in one shot. Inputs: switches (array of
      {name, cidr?, ports: [{name, kind, addresses?, host_node_instance_id?}]}),
      nb_db_endpoint + sb_db_endpoint (required only when no Sdwan::OvnDeployment
      exists for the account yet), northd_host (optional advisory hint),
      dry_run (default false). Returns the compiled ovn-nbctl plan an
      executor or operator can apply against the NB DB. Re-uses the
      existing per-account OvnDeployment when present; otherwise creates
      one. Auto-activates new switches and ports so the compiler emits
      them in the same call.
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
      Use this skill to allocate per-host SDWAN bridges for a set of
      NodeInstances. Inputs: host_node_instance_ids (1-100), kind
      (optional explicit override: linux | ovs — wins over the host's
      network_profile when supplied), dry_run (default false). Returns
      allocated bridge ids + per-host allocations
      (bridge_name, kind, short_id, reused). Auto-selects OVS for
      heavyweight-profile hosts and Linux bridge for lightweight ones, so
      a mixed-profile fleet gets the right driver per host without
      operator coordination. Idempotent — re-running with the same hosts
      returns the existing bridges with reused=true.
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
      Use this skill to register an IPFIX collector for an account.
      Inputs: name (unique per account; reused on re-execution),
      host (IPv4/IPv6/hostname — IPv6 brackets handled automatically),
      port (1-65535), sampling_rate (default 1 = every flow),
      dry_run (default false). Returns collector id + target_endpoint +
      is_winning_collector (true iff this row is the one the topology
      compiler will pick — only the oldest active collector per account
      gets stamped on heavyweight host bridges). Heavyweight-profile
      only in effect: lightweight hosts ignore the ipfix payload.
      Idempotent on (account, name) — re-running with the same name
      returns the existing row without mutating host/port/sampling_rate.
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
      Use this skill when an operator wants a complete SDWAN topology in
      one tool call. Inputs: host_node_instance_ids (always required —
      passed to host_bridge_compose), kind (optional bridge kind override
      — passed through), ovn_topology (optional hash of {nb_db_endpoint,
      sb_db_endpoint, northd_host?, switches} — runs ovn_compose_topology
      when supplied), ipfix_collector (optional hash of {name, host, port,
      sampling_rate?} — runs ipfix_collector_compose when supplied),
      dry_run (default false). Always runs bridge composition; OVN and
      IPFIX are opt-in. Returns each sub-skill's structured data nested
      under outputs. Sub-failures are collected, never short-circuited —
      operators may want to retry just the failing phase rather than
      redo everything. Has a single-call rollback that delegates to each
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
      Use this skill to apply OVN ACLs (firewall rules) to a logical
      switch. Inputs: logical_switch_id (must belong to the executing
      account), acls (array of {name, direction, priority?, match,
      action}, 1-100), dry_run (default false). direction:
      from-lport (egress from source) | to-lport (ingress to destination).
      action: allow | drop | reject | allow-related. priority: 0-32767,
      higher first, default 1000. match: OVN match expression like
      `ip4.src == 10.0.0.0/8 && tcp.dst == 5432`. Returns ovn_acl_ids +
      per-ACL allocations + the recompiled deployment plan with new
      acl-add commands. Idempotent on (switch, name) — re-running with
      the same name returns the existing ACL row without mutating its
      match/action/priority. Heavyweight-profile only (lightweight
      hosts use kube-proxy NetworkPolicy for the equivalent function).
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
      Use this skill to refresh the synced apt/rpm package metadata for one
      PackageRepository. Inputs: repository_id (required). Returns upserted
      count + obsoleted (soft-deleted) count + new package_count. Cheap to
      run frequently; daily cron triggers a fleet-wide sweep automatically.
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
      Use this skill to turn an apt/rpm package into a NodeModule. Inputs:
      repository_id, package_name (both required), architectures (optional,
      defaults to repo.architectures), recommends_selected (optional list
      of recommends package names to opt in), category_id (optional).
      Creates the top-level NodeModule + transitive dependency NodeModules
      (auto_generated=true) + ModuleDependency edges + dispatches CI build.
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
      Use this skill when PackageDriftSensor flags a module whose upstream
      version has bumped beyond the locally-materialized version. Replays
      persisted recommends_chosen for deterministic refreshes. Inputs:
      package_module_link_id (required), force (optional). CVE-flagged
      drifts auto-approve; non-CVE drifts require human approval.
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
      Use this skill to surface the need for a new CPU architecture
      in the platform-wide catalog without holding the manage
      permission. Inputs: name (required, e.g. loongarch64), family
      (required, one of: x86, arm, power, z, risc-v, mips, other),
      apt_name, rpm_name, display_name, description, justification.
      Creates an Ai::AgentProposal row — the architecture is NOT
      materialized until an operator approves the proposal.
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
      Use this skill when an agent has system.architectures.manage AND
      needs to directly create a new custom architecture. Inputs:
      name (required), family (required), apt_name, rpm_name,
      display_name, description, enabled, public. The created row is
      always is_canonical=false — agents can't fabricate canonicals.
      Each call surfaces for operator confirmation via the
      intervention policy.
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
      Use this skill to update a non-canonical architecture's fields.
      Inputs: architecture_id (required), attributes (required hash of
      allowed keys: name, family, apt_name, rpm_name, display_name,
      description, kernel_options, enabled, public). Canonical rows
      are immutable and return an error.
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
      Use this skill to delete a non-canonical architecture from the
      platform-wide catalog. Inputs: architecture_id (required). Fails
      if any NodePlatform references it (restrict_with_error
      dependency). Canonical rows are immutable and return an error.
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
      Use this skill BEFORE invoking system-package-module-create when
      the operator hasn't specified architectures. Inputs: repository_id
      (required), max_suggestions (1-7, default 4). Returns the canonical
      architectures most-likely-correct for the operator's fleet — the
      intersection of (repo's served archs, arches with non-zero fleet
      NodePlatform coverage), ranked by NodePlatform count. Falls back
      to repo defaults with a `fallback: true` flag + low confidence
      when there's no fleet overlap. Use the per-arch `rationale` array
      to explain the recommendation to the operator.
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
      Use this skill for any operator query asking about the inventory of
      package repositories ("how many", "what kinds", "list them",
      "what's configured", etc.). Returns total count, breakdown by kind
      (apt/rpm/dnf), visibility (shared vs account), sync status, and the
      full list. Always prefer this skill over generic "look elsewhere"
      responses when the user asks about repository inventory.
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
      Use this skill when the operator describes a capability NEED rather
      than a package NAME ("I need a reverse proxy", "find me an
      in-memory cache"). Inputs: intent (required free-text),
      repository_ids (optional), kind (apt|rpm|dnf), architectures
      (canonical names — cross-kind expanded), license (exact match),
      top_k (1-50, default 10). Returns ranked packages with
      similarity scores + per-result reasoning + an overall
      confidence label (high/medium/low). Use system-search-packages
      INSTEAD when the operator already knows the package name and just
      wants to filter/browse — search is faster for keyword queries.
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
      Use this skill for ROUTINE platform care — not for incident
      response (use platform_resilience for that), not for new
      deployments (use platform_deploy).

      The skill is action-discriminated. Pick the right branch:
        - cert_status   → "are my certs healthy?" / "what's expiring?"
        - cert_rotate   → "rotate the cert for X" / "renew everything expiring"
        - drift_check   → "any drift on my deployments?"
        - health_check  → "what's the platform's overall health?"

      Each branch is read-only OR triggers an async background job.
      None of them block on long work — the skill returns immediately
      with structured recommendations the operator can act on.
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
      Use this skill when something is misbehaving or capacity is
      under pressure — phrases like "drain X", "scale up", "what's
      wrong with the fleet", "any unhealthy peers".

      The skill is action-discriminated:
        - drain_instance  → cordon + drain a specific NodeInstance
        - scale           → mutate target_replicas (set | increment | decrement)
        - failover_check  → read-only triage of stress signals

      `failover_check` is the safe diagnostic call — always prefer it
      first when the operator describes a vague problem. Use the
      mutation branches (drain_instance, scale) only after you've
      confirmed the failing component AND the operator has agreed to
      the action.
    PROMPT
  },

  # ─── Platform deployment (D2) ──────────────────────────────────────
  {
    name: "Platform Deploy",
    slug: "system-platform-deploy",
    description: "Deploy a new Powernode platform (standalone or federated). With no params, returns a wizard payload describing the form fields. With full params, calls System::PlatformDeploymentOrchestrator to provision the new platform end-to-end.",
    category: "devops",
    subdomain: "platform-deployment",
    executor: "System::Ai::Skills::PlatformDeployExecutor",
    invocation_mode: "workflow_step",
    tags: %w[platform deployment provisioning federation standalone],
    system_prompt: <<~PROMPT.strip
      Use this skill when the operator wants to spin up a new Powernode
      platform — phrases like "deploy a new platform", "spin up another
      hub", "create a federated peer", "stand up a standalone instance".

      Two modes:
        - standalone  → sovereign platform, no FederationPeer relationship
        - federated   → peers with this platform on first boot (requires
                        spawn_mode + parent_url)

      Calling with no parameters returns a wizard payload — the frontend
      renders an inline form so the operator can fill in the details.
      Once submitted, call this skill AGAIN with mode + name + (for
      federated) parent_url + spawn_mode.

      Standalone is the default. The new platform comes up sovereign:
      its first-run handler creates a fresh admin account, requests its
      own ACME cert if public_dns_hostname is set, and is ready to sign
      into within ~5 minutes.

      Federated mode returns a single-use acceptance_token — the operator
      MUST capture it immediately because it's never shown again. The
      child platform's first-run handler uses it to complete the
      handshake.

      Always confirm with the operator BEFORE calling in deploy mode —
      this provisions real infrastructure. The wizard phase is a safe
      no-op so use it generously to surface the form.
    PROMPT
  }
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
