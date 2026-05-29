# System Extension — Orchestration Readiness Audit (2026-05)

**Method:** 16-agent read-only workflow audit (7 dimension analysts — federation, SDWAN,
site-local deployment, reverse-proxy, runtime/fleet, orchestration-spine, concierge/missions — each
followed by an adversarial verifier, then synthesis + a completeness critic). Findings below are the
**verified** gaps (verifier verdict `confirmed`/`partial`); `refuted` claims are excluded.

**Goal evaluated against:** let an operator ask the platform **concierge** to run an advanced
multi-step **mission** ("design and stand up a federated multi-site platform with an SDWAN overlay,
public reverse-proxy/ACME ingress, and managed-child deployments") and have platform AI agents
**dynamically generate every resource and coordinate the process end-to-end** with governance, while
the operator can **monitor and control** it from the frontend.

## Verdict

The orchestration **spine exists and is ~60% complete**. Blockers are *coverage and wiring*, not
missing foundations: `SkillCompositionRunner` is a sound DAG engine (topological layering, parallel
dispatch, rollback, idempotency, MissionChannel broadcasting); `BaseSkillExecutor`+`SkillBindings`
give a clean skill→agent binding DSL; the concierge tool bridge already exposes `system_*` tools and
`execute_agent`; a 7-phase provisioning mission template + `PlanComposerService` already exist.

## Five load-bearing blockers (gate concierge-driven end-to-end missions)

| # | Blocker | Verified status | Resolution phase |
|---|---------|-----------------|------------------|
| 1 | **Cross-step data flow** — runner records step outputs but never threads them into downstream inputs | Confirmed (`skill_composition_runner.rb` execute_step! read inputs from config only; `record_outputs` was a silent no-op — no `metadata` column). **RESOLVED 2026-05-28** (added `metadata jsonb`; `depends_on_outputs` resolver). | Phase 0 ✓ |
| 2 | **Reverse-proxy + ACME have no skill executor** — Traefik/ACME exist as library code only | Confirmed (no `*acme*`/`*reverse_proxy*` executor in skills/; `CertificateManager.issue!` never wrapped) | Phase 2 |
| 3 | **Federation acceptance not orchestrated** — manual token, no SDWAN attach/cert/grant chaining | Confirmed (`federation_api/accept_controller.rb` issues grant+enrollment but no topology/VIP/cert; propose is a 5-line stub) | Phase 3 |
| 4 | **Provisioning is a Tool, not a discoverable `Ai::Skill`** | Partial (a `classify_and_dispatch_provisioning` fast-path exists, but `discover_relevant_skills` can't find provisioning) | Phase 1 |
| 5 | **No concierge inline approval loop** | Partial (`platform_provisioning_approve_plan` MCP action + mission gates exist, but no in-chat ApprovalCard→handler wiring) | Phase 1 |

## Verified gaps by dimension

### Federation
- **No end-to-end federation mission orchestration** — `PlatformDeployExecutor` returns after peer proposal + token gen; no composite skill chains propose→accept→enroll→activate. (critical)
- **No MCP federation-grant actions** — `sdwan_tool.rb` ACTION_PERMISSIONS has user-VPN grants only; zero federation-grant actions. (critical)
- **No skill executor for service-subscription activation** — `SubscriptionLifecycleService.activate!` needs a hand-built `operator_response` hash; no MCP/skill/agent binding. (critical)
- Asymmetric accept flow (token shared out-of-band via rails console) breaks agent automation. (high)
- No post-accept automation hooks (grants, topology, VIPs). (high)
- Cross-peer migration (P5) documented (339-line guide) but unimplemented. (medium)
- Frontend: no grant-management UI on FederationHub; no subscription wizard; no peer liveness/heartbeat polling. (high/low)

### SDWAN
- **No end-to-end multi-site topology orchestration mission** — provisioning template execute phase composes only `provision_full_stack configure_sdwan_for_project attach_storage`. (critical)
- **No federation-topology compose skill** — `FederationManagerExecutor` is health-survey only; no `SdwanFederationComposeExecutor` (hub/mesh). (critical)
- Provisioning missions bind SDWAN composition to SDWAN Manager, not the Topology Designer; the documented concierge→Topology-Designer `execute_agent` path is never exercised. (high)
- OVN ACL composition takes pre-formed ACLs; no intent→rule mapping ("isolate tenant A"). (medium)
- No AI integration tests for composition workflows. (medium)

### Site-local deployment
- `cluster_member` PG-replica setup is async and may race with child accept. (high)
- Scale deployment updates `target_replicas` but does not actually provision/deprovision instances. (high)
- No SDWAN topology composition in the platform deployment workflow. (high)
- ACME cert issuance is child-side only; parent has no control/pre-issuance. (medium)
- No skill to wait for a deployment to reach running status (multi-step missions can't block on readiness). (medium)
- No integration test for the full federated spawn→accept→enroll flow. (medium)

### Reverse-proxy / ingress (the user-flagged weak link)
- **No AI skill for ACME certificate issuance/rotation** — `CertificateManager.issue!` is library-only. (critical)
- **No orchestrated "expose service publicly" workflow** — `platform_deploy_executor` accepts `public_dns_hostname` but only records it; no VIP→port-map→cert→DNS→Traefik chain. (critical/high)
- No automatic DNS-record creation in the ACME workflow; DNS limited to Cloudflare (Route53 client returns UNSUPPORTED). (high/medium)
- No integration tests for an end-to-end "expose service" flow. (high)

### Runtime / fleet
- **K3s node drain** is a stub (`drain_k3s_node.rb` returns `drain_scheduled: true`). (high)
- **K3s cluster upgrade** is a stub (`upgrade_k3s_runtime.rb`). (high)
- SDWAN credential-expiry sensor emits a signal with no `decision_engine` route → no executor. (medium)
- Storage migration: only reconciles stuck assignments; no migration coordinator/sensor. (medium)
- Cost adaptation: `decision_engine` routes `system.project_slo_violation`/`project_cost_breach` to `skill: nil`. (low)
- SBOM-based CVE matching is keyword-overlap (false-positive prone). (low)

### Orchestration spine
- No reverse-proxy/ingress skill executor; no ACME lifecycle executor. (critical)
- Federation acceptance not orchestrated (no SDWAN attach + cert handoff). (high)
- No multi-tenant isolation executor (VLAN/namespace/NetworkPolicy). (high)
- `BaseSkillExecutor.validate_inputs!` checks required-ness only (no type/enum/constraint validation). (medium)
- No service-discovery / DNS automation executor. (medium)
- Disk Image Manager has no executor skills (agent-loop only). (medium)
- SDWAN BGP remediation is planning-only (no FRR auto-restart). (medium)

### Concierge / missions
- **No cross-step data flow in the provisioning DAG** (`skill_composition_runner.rb` execute_step!). **RESOLVED 2026-05-28.** (critical)
- ProvisioningTool not a discoverable `Ai::Skill` → blocks concierge discovery. (high/partial)
- No concierge→operator approval feedback loop for provisioning plans (`concierge_service.rb` `handle_confirmed_action` has no `approve_provisioning_plan` case). (critical)
- System Topology Designer not wired into provisioning mission execution. (high)
- Concierge cannot propose/generate multi-mission orchestration plans (single fixed 7-phase template; no `Ai::MissionCompositionPlan`/LLM decomposition). (high)
- System Concierge has read-only skill bindings; no provisioning execution authority. (medium)
- Cost-cap blocks plan composition silently; no user-facing upgrade prompt path from the gate. (medium)
- Rollback contract shape inconsistency between executors and the runner invocation. (low)

## Completeness critique & confidence

**Overall confidence: MEDIUM-HIGH (65-70%).** The 5 load-bearing blockers are well-grounded in code
examination. Coverage gaps the audit itself flagged:
- Did **not** trace the on-node Go agent federation-accept flow (fw-cfg read → accept POST → enrollment fetch) — server-side only.
- Did **not** live-test end-to-end flows (no real provisioning mission run / federation accept).
- Did **not** fully trace the concierge approval feedback path (request_confirmation card → handler → `orchestrator.handle_approval!` → `mission.advance!`).
- Did **not** verify `AiProvisioningStepJob`/`ExecuteJob` worker-seam error surfacing.

**Self-corrected false claim:** GitOps `ApplyService` **does** exist (`system/gitops/apply_service.rb`) — not a gap; do not duplicate.

## Roadmap (basis for the solidification plan)

Phase 0 — spine foundations (cross-step data flow ✓, mission UI primitives, executor output
standardization, docs). Phase 1 — concierge mission control plane (hybrid composition: deterministic
templates + LLM decomposition; approval loop; cockpit UI). Phase 2 — expose-service-publicly w/ TLS
(north-star #1). Phase 3 — federation & multi-site (north-star #2; includes on-node agent
verification). Phase 4 — runtime/fleet hardening (replace all stubs). Phase 5 — comprehensive
verification (Proxmox e2e), docs, knowledge, acceptance.

> Plan of record: `~/.claude/plans/use-workflow-to-deeply-stateful-pumpkin.md`. End-to-end provider
> tests run against a **Proxmox host** (`ProxmoxProvider`), not LocalQemu.
