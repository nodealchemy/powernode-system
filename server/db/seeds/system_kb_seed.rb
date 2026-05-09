# frozen_string_literal: true

# Seeds the System Extension knowledge-base articles. Each article ingests a
# Phase 1 operator runbook for AI Concierge RAG retrieval. Idempotent via
# `find_or_create_by!(slug:)`.
#
# Articles surface in `platform.list_kb_articles` / `get_kb_article` and via
# the standard /app/wiki UI.
#
# Run via:
#   cd server && bundle exec rails runner \
#     "load Rails.root.join('../extensions/system/server/db/seeds/system_kb_seed.rb')"

puts "\n  Seeding System Extension KB articles..."

admin_account = ::Account.first
unless admin_account
  puts "  ⚠️  No account found — skipping system KB seed"
  return
end

author = admin_account.users.find_by(email: "admin@powernode.org") || admin_account.users.first
unless author
  puts "  ⚠️  No admin user found — skipping system KB seed"
  return
end

# ── Category ─────────────────────────────────────────────────────────────

category = ::KnowledgeBase::Category.find_or_initialize_by(slug: "system-extension")
category.assign_attributes(
  name: "System Extension",
  description: "Operator runbooks + reference material for the Powernode system extension (node lifecycle, modules, SDWAN, container runtimes, fleet autonomy, disk image CI, credential restoration).",
  is_public: true,
  sort_order: 50,
  parent_id: nil
)
category.save!
puts "  ✅ KB Category: #{category.previously_new_record? ? 'created' : 'updated'} — #{category.slug}"

# ── Articles ─────────────────────────────────────────────────────────────

articles = [
  {
    slug: "node-instance-lifecycle",
    title: "Node + NodeInstance Lifecycle",
    excerpt: "Step-by-step guide for the full Node + NodeInstance lifecycle: create → bootstrap → enroll → run → drain → decommission. Per-AASM-state error recovery + LocalQemuProvider variant.",
    content: <<~MD
      # Node + NodeInstance Lifecycle

      Full operator runbook for provisioning, running, and decommissioning Powernode-managed instances.

      ## Phases

      1. **Create Node** — `system_create_node` creates a logical row (no provider VM yet)
      2. **Provision** — `system_provision_instance` triggers provider VM creation
      3. **Bootstrap** — agent installs, mTLS handshake, module reconcile (~90s cold)
      4. **Run** — heartbeats every 30s, reconcile loop, task lease
      5. **Drain** — `system_drain_instance` (graceful) — relocates workloads
      6. **Decommission** — `system_terminate_instance` — cascade FK cleanup

      ## Per-state error recovery

      Each state has known failure modes with recovery procedures. See the full runbook for the matrix.

      ## Source

      Full runbook: [`docs/runbooks/node-provisioning.md`](https://github.com/nodealchemy/powernode-system/blob/develop/docs/runbooks/node-provisioning.md) in the system extension.
    MD
  },
  {
    slug: "module-composition-rules",
    title: "Module Composition & Conflict Resolution",
    excerpt: "Quick-start for authoring + registering + signing + publishing a NodeModule. Covers manifest.yaml schema, package_spec / file_spec / protected_spec / dependency_spec semantics, two-stage CI pipeline, and Cosign keyless signing.",
    content: <<~MD
      # Module Composition & Conflict Resolution

      Reference for `manifest.yaml` schema and how the platform composes modules into a NodeInstance's union root.

      ## Identity fields

      - `name` — globally unique; account-scoped
      - `category` — references a seeded `NodeModuleCategory`; position determines layer order
      - `variety` — `subscription` (always-on) / `config` (override) / `instance` (per-NodeInstance)
      - `cosign_identity_regexp` + `cosign_issuer_regexp` — trust pin

      ## Composition rules

      - `package_spec` — Debian packages installed via mmdebstrap
      - `file_spec.include` / `exclude` — rsync-glob patterns for rootfs/ contents
      - `protected_spec` — files this module owns (carve-out via `mask` only)
      - `dependency_spec` — modules pulled in transitively

      ## Conflict resolution

      Higher-priority modules win for non-protected files. `protected_spec` is enforced strictly: an override module must explicitly `mask:` the protected path to override.

      ## Source

      Full runbook: [`docs/runbooks/module-authoring.md`](https://github.com/nodealchemy/powernode-system/blob/develop/docs/runbooks/module-authoring.md).
    MD
  },
  {
    slug: "sdwan-network-setup",
    title: "SDWAN Network Setup End-to-End",
    excerpt: "Operator runbook covering SDWAN slices 1-9: networks, peers, VIPs, port mappings, firewall rules, route policies, BGP/iBGP, federation peers. Troubleshooting per-failure mode.",
    content: <<~MD
      # SDWAN Network Setup

      End-to-end SDWAN operator runbook covering the system extension's WireGuard-based overlay layer.

      ## Concepts

      - **Network** — IPv6 overlay (`/64` prefix)
      - **Peer** — endpoint on the network
      - **Virtual IP (slice 3)** — first-class `/128` with primary + failover holders
      - **Route Policy (slice 9)** — JSONB statements compiled to FRR route-map
      - **Federation Peer (slice 11, in sweep)** — cross-account peering

      ## Phases

      1. Create overlay network (`system_sdwan_create_network`)
      2. Attach NodeInstance peers
      3. Allocate VIPs for HA addresses
      4. Add port mappings + firewall rules
      5. (Optional) Enable iBGP routing
      6. (Optional) Issue user device VPN access grants
      7. (Optional) Propose federation peers

      ## Source

      Full runbook: [`docs/runbooks/sdwan-network-setup.md`](https://github.com/nodealchemy/powernode-system/blob/develop/docs/runbooks/sdwan-network-setup.md).
    MD
  },
  {
    slug: "multi-cluster-k3s",
    title: "Multi-cluster K3s Patterns",
    excerpt: "Operator guide for running multiple K3s clusters in one account with metadata.target_cluster_id, HA control plane via slice 3 VIP failover, and per-cluster kubeconfig retrieval.",
    content: <<~MD
      # Multi-cluster K3s

      Patterns for running prod + staging + workload-specific K3s clusters in a single Powernode account.

      ## Critical rule

      **Every k3s-agent module assignment MUST set `metadata.target_cluster_id`** in multi-cluster accounts. Without it, agents auto-select the most recent active cluster — workers join the wrong cluster silently.

      ## HA control plane

      Slice 3 enables VIP-backed HA: when the primary k3s-server goes silent, `sdwan_vip_failover` skill promotes the next holder. Requires ≥2 server NodeInstances; single-server clusters cannot use VIP failover.

      ## Source

      Full runbook: [`docs/runbooks/multi-cluster-k3s.md`](https://github.com/nodealchemy/powernode-system/blob/develop/docs/runbooks/multi-cluster-k3s.md).
    MD
  },
  {
    slug: "cve-response-workflow",
    title: "CVE Response Workflow",
    excerpt: "End-to-end CVE response: NVD ingest → SBOM-aware exposure calculation → triage with cve_response skill → operator approval → rolling remediation → verification → learning extraction.",
    content: <<~MD
      # CVE Response Workflow

      Reference for the system extension's automated CVE response pipeline.

      ## Pipeline

      1. **Ingest** — `system_cve_feed` job pulls NVD JSON 2.0 every 6 hours
      2. **Exposure** — `ExposureCalculator` matches `affected_packages` against module SBOMs
      3. **Triage** — `cve_response` skill computes risk_score and remediation plan
      4. **Approval** — `require_approval` policy gates fleet-wide responses (risk_score ≥ 50)
      5. **Remediate** — `rolling_module_upgrade` skill executes batched upgrades with circuit breaker
      6. **Verify** — exposure recompute confirms zero remaining affected instances
      7. **Learn** — `create_learning` documents the response for future similar CVEs

      ## Source

      Full runbook: [`docs/runbooks/cve-response.md`](https://github.com/nodealchemy/powernode-system/blob/develop/docs/runbooks/cve-response.md).
    MD
  },
  {
    slug: "fleet-autonomy-policies",
    title: "Fleet Autonomy Intervention Policies",
    excerpt: "Reference for all 27 intervention policies (19 Fleet Autonomy + 8 Runtime Manager) covering when each action runs auto / notify / require_approval. Override path + consent budget tuning.",
    content: <<~MD
      # Fleet Autonomy Intervention Policies

      Per-action behavior table for the Fleet Autonomy + Runtime Manager AI agents.

      ## Policy semantics

      - `auto_approve` — skill executes immediately on next reconciler tick
      - `notify_and_proceed` — executes + operator notification
      - `require_approval` — `ApprovalRequest` queued; blocked until approved
      - `blocked` — disabled entirely

      ## Override path

      Operators tune via the AI Agents UI or `update_intervention_policy` MCP. Consent budgets cap daily decision counts per module.

      ## Source

      Full reference: [`docs/FLEET_SENSORS.md#intervention-policy-reference`](https://github.com/nodealchemy/powernode-system/blob/develop/docs/FLEET_SENSORS.md#intervention-policy-reference).
    MD
  },
  {
    slug: "container-runtime-troubleshooting",
    title: "Container Runtime Troubleshooting",
    excerpt: "Operator troubleshooting reference for Phase 1 Docker + Phase 2 K3s. Covers TLS errors, daemon.json overrides, K3s join failures, kubelet log retrieval, pod-CNI gaps, registry access.",
    content: <<~MD
      # Container Runtime Troubleshooting

      Common failure modes + recovery procedures for managed Docker daemons + K3s clusters.

      ## Docker

      - TLS verification fails → rotate cert via `system.runtime_docker_tls_rotate`
      - Daemon listens on wrong address → check `Sdwan::Peer.host_address` is the source of truth
      - daemon.json overrides not applied (slice 10) → verify higher `effective_priority`

      ## K3s

      - Agent can't join → verify same SDWAN network as bootstrap server; check `metadata.target_cluster_id`
      - Token mismatch → restart `powernode-agent` to clear stale cache
      - Pod-to-pod traffic unencrypted → known gap (slice 9 not yet shipped); use NetworkPolicy + service mesh

      ## Source

      Full troubleshooting reference: [`docs/CONTAINER_RUNTIMES.md#troubleshooting`](https://github.com/nodealchemy/powernode-system/blob/develop/docs/CONTAINER_RUNTIMES.md#troubleshooting).
    MD
  },
  {
    slug: "instance-pool-tuning",
    title: "Instance Pool Tuning (Slice 7)",
    excerpt: "Operator guide for System::InstancePool: pool creation, target_size sizing heuristics (target_size > reap_rate × bootstrap_latency), reaping triggers, draining, troubleshooting.",
    content: <<~MD
      # Instance Pool Tuning

      Slice 7 introduced pre-warmed pools for ephemeral workloads. Pools cut burst provisioning latency from 5–10 min to <30 s.

      ## Sizing heuristic

      Given peak claim rate C (claims/min), warmup latency W (seconds), reaper interval R (60s):

          target_size ≥ ceil(C × (W / 60 + R / 60))

      Worked example: 4 claims/min, 90s warmup → target_size ≥ 10.

      ## When to use

      - Bursty / ephemeral workloads (CI runners, ML training, batch processing)
      - Need <30 s claim latency
      - Can afford warm idle capacity

      ## When NOT to use

      - Persistent workloads (use direct provisioning)
      - Low burst frequency (cost > savings)
      - Need >50 instances at once (use `provision_cluster` skill instead)

      ## Source

      Full runbook: [`docs/runbooks/instance-pool-tuning.md`](https://github.com/nodealchemy/powernode-system/blob/develop/docs/runbooks/instance-pool-tuning.md).
    MD
  }
]

created = 0
updated = 0

articles.each do |attrs|
  article = ::KnowledgeBase::Article.find_or_initialize_by(slug: attrs[:slug])

  was_new = article.new_record?

  article.assign_attributes(
    title: attrs[:title],
    content: attrs[:content],
    excerpt: attrs[:excerpt],
    category: category,
    author: author,
    status: "published",
    is_public: true,
    is_featured: false,
    sort_order: 100,
    published_at: Time.current,
    views_count: 0,
    likes_count: 0
  )

  if article.changed? || was_new
    article.save!
    if was_new
      created += 1
    else
      updated += 1
    end
  end
end

puts "  ✅ KB Articles: #{created} created, #{updated} updated (#{articles.size} total)"
puts "  Done seeding System Extension KB articles."
