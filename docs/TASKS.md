# Powernode System Extension — Active Tasks

Living document tracking active milestones, recent completions, and open
follow-ups. Updated after substantial work; the parent platform's plan
file at `~/.claude/plans/we-are-working-on-golden-eclipse.md` (operator-
local) carries the long-form roadmap.

**Last updated:** 2026-05-02
**Spec coverage:** 1262 examples / 0 failures / 1 conditional-pending
**Frontend:** TS clean across all session-touched files

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

| Milestone | Status | Notes |
|---|---|---|
| M-FE-1 — Visual Template Composer | ✅ done | TemplateComposerPage with split-view, SaveTemplateModal, conflict detection, footprint estimate, save flow with module attach |
| M-FE-2 — Module Marketplace | ⬜ not started |  |
| M-FE-3 — Fleet Dashboard + Live Boot Replay | ✅ partial | FleetDashboardPage with live event feed, correlation chain viewer, HoneypotCanaryTile, AttributionFeedbackButton; Boot Replay viewer pending |
| M-FE-4 — Conversational Provisioning Concierge | ⬜ not started |  |

## Track D — Day-2 ops

| Milestone | Status | Notes |
|---|---|---|
| M-D2-1 — Audit, compliance, SBOM reports | ✅ partial | ComplianceSnapshotService + retention sweep worker; PDF/JSON export pending |
| M-D2-2 — CVE response pipeline | ✅ partial | Cve + CveExposure models, FeedIngestService (NVD), ExposureCalculator, CveResponseExecutor reads persisted exposures, hourly worker job |
| M-D2-3 — GitOps reconciliation | ⬜ not started |  |

## Track E — Marketplace + onboarding

| Milestone | Status | Notes |
|---|---|---|
| M-MK-1 — Module Authoring SDK (`pnmod`) | ⬜ not started |  |
| M-MK-2 — Quick-Start Templates + First-Run Wizard | ⬜ not started |  |

## Track F — Advanced + creative

| Item | Status | Notes |
|---|---|---|
| F-3 — NodeInstance-as-Agent | ⬜ not started | Plumbing exists but not wired |
| F-4 — Module-as-Skill | ✅ done | ModuleSkillRegistrar parses manifest.yaml#skills, trust-tier gate (community → SkillProposal, verified-publisher → direct) |
| F-6 — Honeypot canary modules | ✅ done | CanaryModuleService + HoneypotAccessSensor + dashboard tile + mark/unmark UI |
| F-11 — Live module diff preview | ✅ done | ModuleDiffService computes rsync_spec deltas + package changes via fingerprints |
| F-16 — AI-Generated Runbooks | ✅ done | RunbookGenerateExecutor walks SBOM + KG anchors + relevant learnings |
| F-19 — Per-module SELinux/AppArmor | ✅ done | Loaded by Go agent's internal/security/mac.go on module attach |

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

## Recent significant additions (last 30 days)

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
