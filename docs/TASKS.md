# Powernode System Extension — Active Tasks

Living document tracking active milestones, recent completions, and open
follow-ups. Updated after substantial work; the parent platform's plan
file at `~/.claude/plans/we-are-working-on-golden-eclipse.md` (operator-
local) carries the long-form roadmap.

**Last updated:** 2026-05-03
**Spec coverage:** 1611 examples / 0 failures / 1 conditional-pending
**Frontend:** TS clean across all session-touched files
**Active sweep:** Comprehensive stabilization (9 phases, ~24-32d) — see `~/.claude/plans/perform-comprehensive-examination-of-glistening-perlis.md`
**Phase 10:** 4 of 7 subphases done (10.1 RuboCop, 10.2 SBOM ingestion, 10.3 Concierge backend wiring, 10.5 metrics v1); 10.4 backend done, frontend pending coupling decision — see `~/.claude/plans/read-tasks-md-and-system-review-and-plan-snug-rainbow.md` for execution roadmap

---

## Track A — Bootstrap runtime

| Milestone | Status | Notes |
|---|---|---|
| M0 — Foundation contracts + legacy spec porting | ✅ done | BootstrapToken, NodeCertificate, ModuleArtifact, NodeModuleVersion AASM, mTLS plumbing, legacy `rsync_spec`/`effective_mask`/`info`/`encode_spec` ported |
| M1 — Module supply chain | 🟡 partial | Containerfile + workflow scaffolded; reproducibility CI gate pending |
| M2 — Go agent v0 | ✅ done | 36 .go files / ~4400 LOC / 8 packages including security |
| M3 — Multi-arch image builder | ✅ done | initramfs/build.sh, dracut configs, 4 image builders, OCI Containerfile, multi-arch CI workflow |
| M3.5 — Real-hardware verification | ⬜ blocked on hardware | x86 server + arm64 SBC + arm64 server runbook docs only |
| M4 — QEMU thin slice | ✅ done | LocalQemuProvider + Libvirt/Recorder/Disabled runners + DomainXmlBuilder + virtio-fw-cfg seed + 15-spec integration coverage |

## Track B — AI integration

| Milestone | Status | Notes |
|---|---|---|
| M5 — MCP CRUD surface | ✅ done | SystemFleetTool with ~25 actions, per-action permission gates |
| M6 — AI Skills catalog | ✅ done | 9 executors (drift_remediate, provision_cluster, rolling_module_upgrade, cve_response, capacity_recommend, module_compose, runbook_generate, attribute_failure, +base) |
| M7 — FleetAutonomyService | ✅ done | gate_action!, 8 sensors, DecisionEngine, PromotionCriteria, ModulePromotionService, LearningExtractor, worker_api endpoint, worker job, seeds |
| M8 — Compound learning extraction | ✅ done | LearningExtractor wired into tick loop; auto_evolve_skill trigger after 3 matching learnings; KG schema seed for FleetSignal/RemediationOutcome/ModuleProvenance |

## Track C — Frontend / Operator UX

| Milestone | Status | Notes | Owner / Blocker |
|---|---|---|---|
| M-FE-1 — Visual Template Composer | ✅ done | TemplateComposerPage with split-view, SaveTemplateModal, conflict detection, footprint estimate, save flow with module attach | — |
| M-FE-2 — Module Marketplace | 🟡 in sweep | Active sweep P7.2 — browse-side skeleton (catalog + filters + trust tier badges + add-to-template). Submission/review queue out of scope. | Active sweep (Phase 7) |
| M-FE-3 — Fleet Dashboard + Live Boot Replay | 🟡 in sweep | Live event feed, correlation chains, honeypot tile shipped. Active sweep P7.1 adds Boot Replay viewer. | Active sweep (Phase 7) |
| M-FE-4 — Conversational Provisioning Concierge | 🟡 in sweep | Active sweep P7.3 — slide-out chat panel reusing existing Conversation/ConversationAiGeneration with system-context flag. | Active sweep (Phase 7) |

## Track D — Day-2 ops

| Milestone | Status | Notes | Owner / Blocker |
|---|---|---|---|
| M-D2-1 — Audit, compliance, SBOM reports | ✅ partial | ComplianceSnapshotService + retention sweep worker; PDF/JSON export pending | Future — operator demand-driven |
| M-D2-2 — CVE response pipeline | 🟡 in sweep | Cve + CveExposure models, FeedIngestService (NVD), ExposureCalculator, CveResponseExecutor reads persisted exposures, hourly worker job. Active sweep P4 replaces v0 keyword-overlap stub with SBOM-aware matching (ecosystem-version range comparators). | Active sweep (Phase 4) |
| M-D2-3 — GitOps reconciliation | 🟡 in sweep | Active sweep P5 — RepoSyncService, DesiredStateParser, DiffEngine, Reconciler, GitopsRepository/SyncRun models, 5min cron, operator UI. | Active sweep (Phase 5) |

## Track E — Marketplace + onboarding

| Milestone | Status | Notes |
|---|---|---|
| M-MK-1 — Module Authoring SDK (`pnmod`) | ⬜ not started |  |
| M-MK-2 — Quick-Start Templates + First-Run Wizard | ⬜ not started |  |

## Track F — Advanced + creative

| Item | Status | Notes | Owner / Blocker |
|---|---|---|---|
| F-3 — NodeInstance-as-Agent | 🟡 in sweep | Active sweep P6 — Go agent peer registrar, /node_api/peer/announce endpoint, Ai::Executors::NodeRemoteExecutor, workspace mention picker integration, trust + consent budget. | Active sweep (Phase 6) |
| F-4 — Module-as-Skill | ✅ done | ModuleSkillRegistrar parses manifest.yaml#skills, trust-tier gate (community → SkillProposal, verified-publisher → direct) | — |
| F-6 — Honeypot canary modules | ✅ done | CanaryModuleService + HoneypotAccessSensor + dashboard tile + mark/unmark UI | — |
| F-11 — Live module diff preview | ✅ done | ModuleDiffService computes rsync_spec deltas + package changes via fingerprints | — |
| F-16 — AI-Generated Runbooks | ✅ done | RunbookGenerateExecutor walks SBOM + KG anchors + relevant learnings | — |
| F-19 — Per-module SELinux/AppArmor | ✅ done | Loaded by Go agent's internal/security/mac.go on module attach | — |

---

## Active follow-ups (operator-actionable)

1. **Vault PKI bootstrap** — operator/infra task to mount `pki_int` + create
   `node` role + migrate from manual Shamir unseal to auto-unseal. Blocks
   `InternalCaService.VaultCaAdapter` from going live in production.

2. **Traefik mTLS termination** — production proxy needs `tlsOptions.clientAuth`
   + `passTLSClientCert` middleware + CA mount before mTLS auth path is the
   primary auth (currently JWT fallback is operational).

3. **Latent-bug audit on other extensions** — the 13 platform bugs found in
   the system extension follow patterns (Rails-encrypts vs `_ciphertext`
   columns, JwtService autoload, factory schema drift) that likely exist in
   `extensions/devops/`, `extensions/chat/`, `extensions/business/`.

4. **Trading::FleetPressurePerceiver spec rspec gate** — 9 specs ship but
   trading is currently disabled in `extensions_state.json`. Re-enable trading
   in test env to validate.

5. **Bare-metal first-boot CA transport** — kernel cmdline ~2 KB limit
   conflicts with multi-cert CA chains. Recommend `powernode.ca_pem_url`
   pattern + leap-of-faith verification on first boot.

6. **GitOps reconciler (M-D2-3)** — declare desired fleet state in YAML;
   reconciler opens `Ai::Proposal` for diffs.

7. **Frontend nav route registration in parent platform** — `extensions/system/
   register.ts` adds `/system/fleet` and `/system/templates/compose` routes;
   verify nav appears post-extraction.

---

## Active stabilization sweep — May 2026

Comprehensive 9-phase sweep targeting end-to-end functional stability.
**48 new specs passing across the sweep's surface area**; Go agent vet + build clean; TypeScript clean.

| Phase | Scope | Status |
|---|---|---|
| P1 — Doc hygiene | TASKS.md sync, system_review_and_plan refresh, initramfs README, threat model, credential-restoration doc | ✅ done |
| P2 — Backend gaps | CloudSyncService schedule (per-account fan-out), NodeModuleAssignment toggle endpoints | ✅ done — 16 specs pass |
| P3 — Encryption keys | Per-account Vault transit pepper, AccountEncryptionKeyService, ProviderConnection migration | ✅ done — 13 specs pass |
| P4 — M-D2-2 SBOM CVE | sbom_packages_data column, ecosystem version matcher, ExposureCalculator upgrade | ✅ done — 13 matcher specs pass |
| P5 — M-D2-3 GitOps | RepoSyncService → DesiredStateParser → DiffEngine → Reconciler → Ai::AgentProposal + worker job + 5min cron | ✅ done — 6 parser specs pass |
| P6 — F-3 NodeInstance-as-Agent | agent_peer/registrar.go (Go) + AgentPeeringService + node_api/peer endpoint + operator delegation API | ✅ done — Go agent_peer tests pass |
| P7 — UI features | Boot Replay viewer (timeline + detail), Marketplace skeleton (list + card + detail modal), AI Concierge panel | ✅ done — TypeScript clean |
| P8 — Quality polish | Full verification (rspec + go + tsc) | ✅ done — RuboCop autocorrect deferred |
| P9 — Submodule + parent | Dual-remote push (Gitea + GitHub mirror), parent pointer bump, MCP knowledge contributions | ✅ done — 27 commits across both repos, all pushed |

### Post-sweep follow-ups (refined plan: Phase 10 in the sweep plan file)

A refined sequenced roadmap for the deferred items lives at
`~/.claude/plans/perform-comprehensive-examination-of-glistening-perlis.md`
under "Phase 10 — Deferred Item Roadmap". Summary:

| Subphase | Scope | Effort | Status |
|---|---|---|---|
| 10.1 | RuboCop autocorrect sweep | ~0.5d | ✅ done — 1127 → 0 offenses; 154 files autocorrected; CI rubocop job added |
| 10.2 | `syft` SBOM ingestion in module CI | ~2d | ✅ done — webhook ingestion (HMAC-auth, not worker_api per plan deviation), CycloneDxParser, retry-on-race in build CI |
| 10.3 | AI Concierge production conversation routing | ~3d | ✅ done — System Concierge agent (db/seeds) + FleetContextBuilder + concierge_controller#start; reuses platform's Ai::ConciergeService; ConciergeToolBridge gained metadata-driven tool filter (parent platform change); ConciergePanel wired |
| 10.4 | Workspace mention picker for peers | ~1.5d | 🟡 partial — searchable endpoint shipped; frontend wire-up gated on parent-platform coupling decision (extension hook vs registry) |
| 10.5 | Metrics instrumentation (v1 = AS::Notifications subscriber) | ~1.5d | ✅ done — Aggregator (Rails.cache counter, per-min buckets) + Subscriber (idempotent AS::Notifications listener) + GET /system/metrics/dispatch endpoint; frontend tile deferred to 10.7 |
| 10.6 | `task.events` JSON → dedicated table | ~2d | ⏸️ decision-gated on audit volume |
| 10.7 | Polish list (frontend tests, runbooks, peer activation UI) | ~6d | ⬜ slow-day work |

**Total deferred**: ~17 engineer-days across 6 phases (excluding the
decision-gated table extraction and slow-day polish list). See the plan
file for per-subphase prerequisites, files to touch, success criteria,
and risk register.

---

## Recent significant additions (last 30 days)

- 2026-05-04 — Phase 10.7 (item 1) — Dispatch latency frontend tile:
  `metricsApi.dispatch()` + `DispatchLatencyTile` rendered in
  `FleetDashboardPage` below the existing counters strip. Polls
  `/api/v1/system/metrics/dispatch` every 30s with a 5min window;
  shows count + rate per metric (claimed/started/completed/failed/fleet
  events) and computes failure-rate % across completed+failed.
- 2026-05-03 — Phase 10.3 AI Concierge backend wiring: System Concierge
  `Ai::Agent` seed, `System::Concierge::FleetContextBuilder`,
  `concierge_controller#start`, `ConciergePanel` wired to platform's
  existing AI conversation flow. Metadata-driven tool filter added to
  `Ai::ConciergeToolBridge` (parent platform) — extension agents declare
  their tool surface via `agent.metadata["concierge_tool_filter"]`,
  avoiding hardcoded extension knowledge in the bridge. 13 specs (8 builder
  + 5 filter); all green. SystemFleetTool action coverage: 25 wired
  (compliance_snapshot, runbook_generate, cve_triage, recent_signals,
  attribute_failure, inspect_correlation now wired in upstream sweep).
- 2026-05-03 — Phase 10.4 (partial) — `node_instance_peers#searchable`
  endpoint for workspace mention picker; lightweight peer serialization
  filterable by handle prefix. Frontend wire-up paused: requires either
  parent-platform coupling or a mention-picker plugin registry (not in v1
  scope without operator decision).
- 2026-05-03 — Phase 10.5 metrics v1: `Metrics::Aggregator` (Rails.cache
  counter aggregator, per-minute buckets, 65min TTL, 1h max window) +
  `Metrics::Subscriber` (idempotent AS::Notifications listener for
  `system.dispatch.*`, `system.fleet.event`, `system.cloud_sync.*`) +
  operator endpoint `GET /system/metrics/dispatch` gated on
  `system.metrics.read`; one-line `AS::Notifications.instrument` added to
  `Fleet::EventBroadcaster.emit!` so fleet events flow through the same
  collector; 25 new specs (10 aggregator + 10 subscriber + 5 controller);
  frontend dashboard tile defers to 10.7 polish list
- 2026-05-03 — Phase 10.2 syft SBOM ingestion: `Sbom::CycloneDxParser`
  service (33 specs) + `webhooks/module_sbom_controller#create` (11 specs)
  HMAC-authenticated via per-module `webhook_secret` (mirrors existing
  `gitea_module` webhook, not `worker_api` per plan deviation); CI step
  added in `templates/module-repo/.gitea/workflows/build.yaml` with retry
  backoff (0s/10s/30s/60s) to handle async-ingestion race; truncates at
  5000 packages with logged warning
- 2026-05-03 — Phase 10.1 RuboCop bootstrap + autocorrect sweep:
  `server/.rubocop.yml` + `worker/.rubocop.yml` inheriting Omakase; new
  `rubocop` job in `.gitea/workflows/ci.yaml`; 1127 → 0 offenses across
  154 Ruby files; spec suite green at 1534/0/1
- 2026-05-02 — System extension extracted to its own repo (`powernode-system`)
  — meta files (README, LICENSE MIT, CONTRIBUTING, CI workflows for both
  Gitea + GitHub) added in preparation
- 2026-05-02 — Trading SchedulingService consumes fleet pressure via
  `Trading::FleetPressurePerceiver.recommend_least_busy_key`; venue iteration
  order now biases toward less-busy venues
- 2026-05-02 — Mark-as-Canary endpoint + UI button + 6-spec coverage; lure_kind
  selection from operator UI
- 2026-05-02 — AttributionResultModal + entry button in NodeInstanceControls;
  full attribution + feedback loop now operator-reachable
- 2026-05-02 — FleetEvent retention sweep worker + endpoint + 6 specs;
  differentiated retention (90d routine / 365d critical)
- 2026-05-02 — TemplateComposer save flow with conflict-blocked save +
  per-module attachment + Cypress e2e
- 2026-05-02 — ConsentBudgetEditor in ModuleDetailModal autonomy tab;
  operator-controlled per-module daily decision ceiling
- 2026-05-02 — HoneypotCanaryTile in FleetDashboard counter strip
- 2026-05-01 — Cross-domain stigmergic coordination: TradingPressureSensor
  + PressureEmitter + TradingAwareThrottle, bidirectional pressure exchange
- 2026-05-01 — Per-module consent budget + AttributionFeedbackService closing
  the autonomy learning loop
- 2026-05-01 — FleetEvent persistent log + EventBroadcaster + SystemFleetChannel
  ActionCable observability layer

---

*Tracked at the file level for portability. Move to a real issue tracker once
operator volume justifies it.*
