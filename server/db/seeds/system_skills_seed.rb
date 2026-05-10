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
    name: "Docker Provision",
    slug: "system-docker-provision",
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
      "executor_class" => data[:executor]
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

# ─────────────────────────────────────────────────────────────────────
# Agent skill bindings
# Bind read-shape skills to System Concierge (chat-driven). Bind broad
# autonomous skills to Fleet Autonomy. Container runtime skills
# (docker_provision, provision_cluster) get bound to the Runtime Manager
# agent in slice 3a; we set up *placeholder* bindings here only if the
# Runtime Manager already exists, otherwise slice 3a's seed creates
# them.
# ─────────────────────────────────────────────────────────────────────

# Concierge — read-shape: capacity_recommend, attribute_failure, runbook_generate, cve_runbook_generate
concierge = ::Ai::Agent.where(account: account).find_by(name: "System Concierge")
if concierge
  %w[
    system-capacity-recommend
    system-attribute-failure
    system-runbook-generate
    system-cve-runbook-generate
  ].each_with_index do |slug, i|
    skill = ::Ai::Skill.find_by(slug: slug)
    next unless skill

    binding = ::Ai::AgentSkill.find_or_initialize_by(
      ai_agent_id: concierge.id, ai_skill_id: skill.id
    )
    binding.assign_attributes(priority: 100 + i, is_active: true)
    binding.save!
  end
  puts "    ✓ Bound 4 read-shape skills to System Concierge"
else
  puts "    = System Concierge not seeded yet — skipping concierge bindings"
end

# Fleet Autonomy — broad autonomous: drift_remediate, cve_response, all 4 SDWAN, module_compose, rolling_module_upgrade
fleet_autonomy = ::Ai::Agent.where(account: account).find_by(name: "Fleet Autonomy")
if fleet_autonomy
  %w[
    system-drift-remediate
    system-cve-response
    system-sdwan-failover
    system-sdwan-peer-remediate
    system-sdwan-bgp-session-remediate
    system-sdwan-vip-failover
    system-module-compose
    system-rolling-module-upgrade
  ].each_with_index do |slug, i|
    skill = ::Ai::Skill.find_by(slug: slug)
    next unless skill

    binding = ::Ai::AgentSkill.find_or_initialize_by(
      ai_agent_id: fleet_autonomy.id, ai_skill_id: skill.id
    )
    binding.assign_attributes(priority: 100 + i, is_active: true)
    binding.save!
  end
  puts "    ✓ Bound 8 autonomous-action skills to Fleet Autonomy"
else
  puts "    = Fleet Autonomy not seeded yet — skipping fleet bindings"
end

puts "  Done seeding System extension AI skills."
