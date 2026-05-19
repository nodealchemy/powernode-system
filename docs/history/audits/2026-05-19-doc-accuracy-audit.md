# System Extension Documentation Audit — 2026-05-19

**Status:** Synthesis complete. Awaiting user triage of Phase D remediation.
**Auditor:** Claude Code (Opus 4.7) — six-agent fan-out (1 mechanical preflight + 5 capability deep-audit).
**Audit plan:** `~/.claude/plans/fan-out-agents-to-unified-parrot.md` (approved 2026-05-19).
**Submodule HEAD:** `67d9811` · **Parent HEAD:** `9088779` · **Generated:** 2026-05-19T06:33Z (Phase A) → 2026-05-19T06:55Z (Phase C synthesis).
**Methodology:** Each agent's findings table is preserved verbatim in §2 ("Findings by domain"). Cross-doc inconsistencies and gaps are collated in §3–§4. Mechanical-harness output is included verbatim in §5. Suspected code bugs (with suggested fixes) are in §6. §7 proposes the user-gated remediation phases.

---

## 1. Executive summary

**Total findings: ~165** across five capability slices. The system extension's docs have drifted significantly since the typed-rose audit (2026-05-04): the codebase has roughly tripled in many dimensions (228 services vs prior ~90; 135 controllers vs prior 38; 18 fleet sensors vs prior 12–13; 102 `system_*` MCP actions vs documented 42) but doc updates have not kept pace. The drift is concentrated in **counts, MCP-action signatures, status badges, and capability-area coverage** rather than in any one bad doc.

### Severity distribution (approximate)

| Severity | Count | Definition |
|---|---|---|
| HIGH | ~57 | Would mislead an operator into a wrong call, failed automation, or insecure config |
| MED  | ~55 | Annoyance / confusion / noise; no operational impact |
| LOW  | ~53 | Cosmetic (typo, formatting, dead-wood) |

### Type distribution (approximate)

| Type | Count |
|---|---|
| INACCURACY    | ~87 — text provably wrong vs code |
| GAP           | ~22 — code feature, no doc |
| STALE         | ~20 — status badge no longer matches |
| BROKEN        | ~10 — link / command / MCP call fails today |
| INCONSISTENCY | ~26 — two docs disagree |

### Recurring themes (highest-leverage to fix)

1. **Count drift epidemic.** Every doc that cites a resource count has drift. README.md (sensors 12→18, models 98→120, services ~285→~274, controllers ~138→135, migrations 131→137), CLAUDE.md (sensors `12 sensor reference`→18, SDWAN policies 28→31, Concierge skills 4→7, smoke seeds 16→18, Go packages 12→23), FLEET_SENSORS.md (12→18; 6 missing sensor sections), MCP_API_REFERENCE.md (`system_*` 42→102, `system_sdwan_*` 52→69), SMOKE_TEST.md (16 vs 18, 7 vs 8 passes), ARCHITECTURE.md ("Six sensors" then lists 8; "25+ actions" actually 171).
2. **MCP action signature drift.** ≥12 doc-cited MCP calls have wrong parameter shapes. `bootstrap_disk_image_ci` takes `label`/`owner`/`repo` (not `node_platform_id`/`ref`/`arches`/`account_id`/`force`); `provision_disk_image_webhook` takes `label` not `node_platform_id`; `system_set_disk_image_retention` accepts only `retention_count` (not `retention_days`/`routine_days`/`critical_days`); `system_create_module_from_package` materialises from a PackageRepository (not Gitea repo URL); `system_provision_ci_worker` only takes `name`; `system_update_module_assignment`/`system_get_task`/`platform.execute_skill`/`system_get_instance_stats`/`system_update_node_platform` don't exist.
3. **2026-05-10 agent split incomplete in docs.** Several docs still attribute CVE policies to Fleet Autonomy (real owner: CVE Responder); FLEET_SENSORS.md fleet-policy table still lists SDWAN policies (real owner: SDWAN Manager); Concierge's own system_prompt says "Four agents" (actual: 7); CVE runbook + tutorial 07 introspect `fleet_autonomy_agent` for CVE policy.
4. **Module manifest schema fiction in tutorials + runbook.** Tutorial 02 + `runbooks/module-authoring.md` teach a nested `identity:` block + nested `file_spec: { include, exclude }`. Real schema (per `templates/module-repo/manifest.yaml`, `module-manifest.schema.json`, `ManifestImportService::KNOWN_TOP_KEYS`) is FLAT with no `identity:` wrapper, no `category`/`variety` in manifest, no `cosign_*_regexp` in manifest. Operators authoring modules from these docs will fail.
5. **AASM state drift.** ARCHITECTURE.md NodeInstance lifecycle diagram lists fictional states (`draining`, `failed`) and omits real ones (`starting`, `stopping`, `rebooting`). Module promotion uses `promotion_state` column with values `built, staging, blessed, live, retired` — not `lifecycle_state` with `draft → … → archived`.
6. **Phase O4 CNI features undocumented.** `cni_plugin` argument + `network_profile`-based auto-selection (heavyweight→ovn_kubernetes, lightweight→flannel) in `KubernetesClusterProvisionerService` is implemented + has API surface, but CONTAINER_RUNTIMES.md and tutorials 04/05 still describe flannel as the only choice and call OVN "future".
7. **Phase O6 Topology Designer agent under-documented.** Mentioned in CLAUDE.md but no dedicated doc. Its 5 compose skills (`sdwan_host_bridge_compose`, `sdwan_ovn_compose_topology`, `sdwan_ovn_apply_acl`, `sdwan_ipfix_collector_compose`, `sdwan_compose_full_topology`) are absent from `SKILL_EXECUTORS.md`.
8. **Disk image CI has the worst doc-code alignment.** 12 HIGH + 11 MED findings concentrated around fictional API shapes, fictional event names (`system.disk_image.{webhook_received,cosign_verified,publication_created,platform_updated}` — actual events are `system.disk_image_published` / `system.disk_image_publish_failed`), fictional retention model (`routine_days`/`critical_days` vs real fixed `retention_count` + 7-day grace), and fictional composefs/fs-verity narrative.
9. **MCP_API_REFERENCE.md is ~67 actions behind the registry.** 50+ `system_*` (storage / volumes / NFS / migrations / architecture / GitOps / CI workers / disk-image management / provider / topology) and 17 `system_sdwan_*` (slice 11+ OVN / IPFIX / host-bridge / access-grant / federation accept) operator-visible actions are absent.
10. **8 Go internal packages lack `doc.go`.** boot, fleetevent, fsutil, lifecycle, manifest, migration, storage, systemd. Three (boot, fleetevent, fsutil) are core components per `agent/README.md`.

### Top 10 HIGH-severity findings (highest operational impact)

| # | Doc / Code | Finding | Action |
|---|---|---|---|
| 1 | `docs/runbooks/module-authoring.md:46-99` + `tutorials/02-first-module.md:93-121` | Manifest schema teaches nested `identity:` + nested `file_spec.{include,exclude}` — actual schema is FLAT. Operators following these will fail. | REWRITE-SECTION |
| 2 | Disk image CI runbook + tutorial + reference (~12 places, see Agent 2 §2) | `bootstrap_disk_image_ci`, `provision_disk_image_webhook`, `system_set_disk_image_retention`, `system_list_disk_image_publications`, event names — wrong param shapes and return fields throughout. | REWRITE-SECTION |
| 3 | `extensions/system/server/app/services/system/executors/disk_image/{promote_publication,rollback_publication}.rb` | **Code bug B1**: executors call non-existent `pub.promote!` and write non-existent `active`/`promoted_at` columns. Operator approval crashes. Suggested patch in §6. | Fix code (separate commit). |
| 4 | `CONTAINER_RUNTIMES.md` + `tutorials/{04,05}` | Phase O4 CNI auto-selection (ovn_kubernetes / flannel) and `cni_plugin` override are shipped but undocumented. Operators cannot find the option. | ADD-NEW-CONTENT |
| 5 | `runbooks/sdwan-network-setup.md:3, 286-306` + `tutorials/11-federation.md:104-117` | SDWAN slice 9 routing (live) + slice 11 federation accept (live MCP action `system_sdwan_accept_federation_peer`) described as "in active sweep" / "operator-driven via SQL". | UPDATE-IN-PLACE |
| 6 | `runbooks/cve-response.md:205` + `tutorials/07-cve-response.md:262-265` | Docs introspect `agent_id: "fleet_autonomy_agent"` for CVE policy — actual owner since 2026-05-10 is CVE Responder. | UPDATE-IN-PLACE |
| 7 | `docs/ARCHITECTURE.md:181-194` | NodeInstance AASM diagram shows fictional states (`draining`, `failed`) and omits real ones (`starting`, `stopping`, `rebooting`). | REWRITE-SECTION |
| 8 | `runbooks/module-authoring.md:218-225` + `tutorials/02-first-module.md:218-249` | Module column called `lifecycle_state` with `draft → … → archived` — actual is `promotion_state` with `built, staging, blessed, live, retired`. | UPDATE-IN-PLACE |
| 9 | `runbooks/node-provisioning.md:119` | URL `/api/v1/system/node_api/enrollment` — actual route is `/enroll`. Curl 404s. | UPDATE-IN-PLACE |
| 10 | `docs/MCP_API_REFERENCE.md` (multiple) | 50+ `system_*` + 17 `system_sdwan_*` operator-visible actions absent from operator catalog (storage, architecture, GitOps, CI workers, OVN, IPFIX, host-bridge). | ADD-NEW-CONTENT |

---

## 2. Findings by domain

The five capability agents' findings tables follow **verbatim** (one row per finding, deduplicated where Agent N and Agent N+1 flagged the same line). The text in each row is exactly as the auditing agent emitted it.

### Agent 1 — Node lifecycle + modules + skills (28 findings)

| Severity | Type | File:Line | Finding | Code citation | Recommended action |
|---|---|---|---|---|---|
| HIGH | INACCURACY | docs/ARCHITECTURE.md:181-194 | NodeInstance AASM lifecycle diagram shows states `pending → provisioning → running → draining → stopped → failed → terminated`, but actual AASM has `pending, provisioning, starting, running, stopping, stopped, rebooting, terminated, error` — NO `draining`, NO `failed` (it's `error`), HAS `starting/stopping/rebooting` which are absent from diagram. The diagram conflates Task AASM (`pending → provisioning → running`) with NodeInstance lifecycle. | `app/models/system/node_instance.rb` AASM block (states/events) | REWRITE-SECTION: replace diagram with the actual NodeInstance state set; clarify that `draining` belongs to operator drain workflow (Task), not NodeInstance status |
| HIGH | INACCURACY | docs/runbooks/node-provisioning.md:119 | "POSTs CSR to `/api/v1/system/node_api/enrollment`" — actual route is `/api/v1/system/node_api/enroll` (no trailing -ment) | `config/routes.rb` `post :enroll, to: "enrollment#create"` | UPDATE-IN-PLACE: change `/enrollment` → `/enroll` |
| HIGH | INACCURACY | docs/runbooks/module-authoring.md:46-99 | Manifest schema shown uses nested `identity:` block (`identity.name`, `identity.category`, `identity.variety`, `identity.description`, `identity.cosign_identity_regexp`, `identity.cosign_issuer_regexp`) AND nested `file_spec: { include: [...], exclude: [...] }`. Actual schema uses FLAT top-level keys: `name`, `display_name`, `description`, `license`, `mask`, `file_spec` (flat array), `package_spec`, etc. NO `identity:` wrapper, NO `category`/`variety` in manifest, NO `cosign_*_regexp` in manifest. | `app/services/system/manifest_import_service.rb:81-85`, `modules/.schema/module-manifest.schema.json:9-28`, `templates/module-repo/manifest.yaml:13-48` | REWRITE-SECTION: rewrite Phase 2 manifest example to match the flat schema; remove `identity:`, `category`, `variety`, `cosign_*_regexp`, `file_spec.include/exclude`; cross-reference MODULE_MANIFEST_COMPLETE_SCHEMA.md for authoritative shape |
| HIGH | INACCURACY | docs/tutorials/02-first-module.md:93-121 | Same as above — uses fictional `identity:`-nested manifest with `category: userland`, `variety: subscription`, `cosign_identity_regexp:`, `file_spec: { include: [...], exclude: [...] }`. Mismatches `templates/module-repo/manifest.yaml`. | `templates/module-repo/manifest.yaml:13-48` | REWRITE-SECTION: align Step 2 example with the flat canonical template manifest |
| HIGH | INACCURACY | docs/tutorials/02-first-module.md:166-178 | `platform.system_create_module_from_package({ name: "my-redis", category_slug: "userland", variety: "subscription", gitea_repo_full_name: "..." })` is fictional. Actual MCP signature is `(repository_id, package_name, architectures, recommends_selected, category_id, dispatch_build)` — materializes from a PackageRepository, not a Gitea repo. There is no MCP action that creates a NodeModule from a Gitea repo URL today. Tutorial also claims the response yields `webhook_secret` — webhook_secret is generated per-build by `ModuleBuildDispatchService#generate_webhook_secret`. | `extensions/system/server/app/services/ai/tools/system_package_repository_tool.rb`; `app/services/system/module_build_dispatch_service.rb` | REWRITE-SECTION: either rewrite using the actual Gitea-driven NodeModule registration flow, or downgrade Step 5 to "register via the operator UI at /app/system/modules/new" |
| HIGH | INACCURACY | docs/tutorials/02-first-module.md:218-249, docs/runbooks/module-authoring.md:206, 216-225 | `lifecycle_state: draft` / lifecycle `draft → staging → blessed → live → archived` — actual column is `promotion_state`, valid states are `built, staging, blessed, live, retired`. `draft` and `archived` are NOT valid values. Module ingestion creates rows in `built`. `promote_to!` enforces `PROMOTION_TRANSITIONS`. | `app/models/system/node_module_version.rb` PROMOTION_STATES, PROMOTION_TRANSITIONS, `promote_to!` | UPDATE-IN-PLACE: replace every `lifecycle_state` → `promotion_state`, `draft` → `built`, `archived` → `retired` |
| HIGH | INACCURACY | docs/ARCHITECTURE.md:436 | "25+ tool actions exposed via the platform's MCP server" — actual count is **171 `system_*` actions** registered in PlatformApiToolRegistry. Section also has the known broken `MCP_TOOL_CATALOG.md` link (Phase A baseline). | `server/app/services/ai/tools/platform_api_tool_registry.rb` (`grep -c '"system_' = 171`) | UPDATE-IN-PLACE: change "25+" to "170+" |
| HIGH | INACCURACY | docs/ARCHITECTURE.md:21-22 | "~50 models" + "~80 services" — actual is **96 models** (71 system/ + 25 sdwan/) and **187+ services** (excluding skill executors). | `ls app/models/system/*.rb \| wc -l = 71; ls app/models/sdwan/*.rb \| wc -l = 25; find app/services/system -name '*.rb' -not -path '*/ai/skills/*' \| wc -l = 187` | UPDATE-IN-PLACE: update model/service counts in the Control plane node |
| HIGH | INACCURACY | docs/ARCHITECTURE.md:216 | "Six sensors detect operational signals" (then lists 8 items). Phase A preflight counts **18 active sensors**. (Agent 4 owns full FLEET_SENSORS.md drift; this is the architectural overview.) | `app/services/system/fleet/sensors/*.rb` (18 files + base_sensor.rb) | UPDATE-IN-PLACE: "18 sensors" with link to FLEET_SENSORS.md |
| MED | INACCURACY | docs/ARCHITECTURE.md:107-111 | Module-assignment-materialization table cites `ModuleCommitService#materialize_assignment!` — no such method exists. The service uses `find_or_create_by!` inline. | `app/services/system/module_commit_service.rb` | UPDATE-IN-PLACE: drop the method name; cite the service only |
| MED | INCONSISTENCY | docs/SKILL_EXECUTORS.md:49-173 | Per-executor "Category" labels use `sre_observability` / `release_management`. Actual `descriptor()` returns `devops` / `sdwan` / `security`. Seed maps to platform `Ai::Skill` enum (which IS `sre_observability`); two docs disagree on the same field. | `app/services/system/ai/skills/attribute_failure_executor.rb:30 category: "devops"` vs `db/seeds/system_skills_seed.rb` | UPDATE-IN-PLACE: add a note distinguishing seeded `Ai::Skill.category` from executor descriptor category |
| MED | INACCURACY | docs/SKILL_EXECUTORS.md:7 | "covers the original 14 executors in depth" — 14 sections present, but the doc has not been updated to cover the 26 new executors (architecture_*, configure_sdwan_for_project, attach_storage, deploy_app_code, package_*, platform_*, sdwan_compose_*, sdwan_host_bridge_compose, sdwan_ipfix_collector_compose, sdwan_ovn_*, federation_manager, platform_deploy, suggest_architectures_for_fleet, list_package_repositories_summary, discover_packages_by_intent, relocate_workload, scale_project, provision_full_stack, cve_remediation_orchestration). | `ls app/services/system/ai/skills/*_executor.rb \| wc -l = 40`; SKILL_EXECUTOR_CATALOG.md has all 40 | ADD-NEW-CONTENT: brief in-depth sections for high-value new executors OR explicitly point readers to SKILL_EXECUTOR_CATALOG.md as canonical |
| MED | INACCURACY | docs/SKILL_EXECUTORS.md:14-33 | Agent → Skill bindings table is missing several skills bound to System Concierge (`system-platform-deploy`, `system-platform-maintenance`, `system-platform-resilience`). Concierge `read_shape_skills` array seeds **7**, doc claims "4 read-shape skills bound". Table also missing newer skills (architecture_*, attach_storage, deploy_app_code, federation_manager, package_*, configure_sdwan_for_project, sdwan_host_bridge_compose, …). | `db/seeds/system_concierge_agent.rb` (7 entries); `db/seeds/system_topology_designer_agent.rb` (5 SDWAN-compose) | UPDATE-IN-PLACE: regenerate binding table from union of registry discovery + hardcoded seed blocks. Surface that Topology Designer (Phase O6) owns 5 sdwan-compose-* skills. |
| MED | INACCURACY | docs/SKILL_EXECUTOR_CATALOG.md (ProvisionClusterExecutor entry) | Descriptor omits `partial: :boolean` from outputs; executor's `execute()` returns `partial: failures.any? && created.any?`. Descriptor() method is missing the key. | `app/services/system/ai/skills/provision_cluster_executor.rb` | UPDATE-IN-PLACE (in executor's `descriptor()`): add `partial: :boolean`, then re-run `rails system:skills:generate_catalog`. **This is a small code fix** that propagates to auto-generated docs. |
| MED | INACCURACY | docs/runbooks/node-provisioning.md:74 | "`lifecycle_class` is **immutable after first instance provisions**" — model has `validates :lifecycle_class, inclusion: …` but NO immutability guard (no `attr_readonly`, no validator on update). Also spurious memory citation. | `app/models/system/node.rb:19-20` | UPDATE-IN-PLACE: remove false "immutable" claim OR add `attr_readonly :lifecycle_class` (recommend dropping the doc claim) |
| MED | INACCURACY | docs/runbooks/vendored-binary-bump.md:14 | "`initramfs/.gitea/workflows/build.yaml:48` → `APT_SNAPSHOT`" — actual line is **53**. | `extensions/system/initramfs/.gitea/workflows/build.yaml:53` | UPDATE-IN-PLACE: change `:48` → `:53` |
| MED | INACCURACY | docs/runbooks/vendored-binary-bump.md:124 | "Kernel selection happens in `build_kernel_initrd()` (`initramfs/build.sh:94–110`)" — actual function starts at line 79. | `extensions/system/initramfs/build.sh:79` | UPDATE-IN-PLACE: change `94-110` → `79-110` |
| MED | INACCURACY | docs/runbooks/module-authoring.md:60-61 | "Default seeded: `system-base`, `network-overlay`, …" categories. These are operator-facing categories for the UI taxonomy, not validated in manifest schema. Runbook treats `category` as a manifest-level field, but the actual schema has NO category key in manifest YAML. | `modules/.schema/module-manifest.schema.json` (no `category` property); `app/models/system/node_module_category.rb` | UPDATE-IN-PLACE: clarify NodeModuleCategory is set on the platform-side row (UI / `system_create_module_from_package` `category_id:`), NOT in `manifest.yaml`. |
| MED | INACCURACY | docs/runbooks/module-authoring.md:248-254 | `platform.system_update_module_assignment(...)` — this MCP action **does not exist**. Doc calls itself out as aspirational. | `server/app/services/ai/tools/platform_api_tool_registry.rb` (no entry) | UPDATE-IN-PLACE: drop the call example; use the verified REST PATCH path |
| MED | INACCURACY | docs/runbooks/node-provisioning.md:106-107, 209-217 | `platform.system_get_task` MCP action does NOT exist. `platform.execute_skill` also does NOT exist — the registered action is `execute_agent`. | `server/app/services/ai/tools/platform_api_tool_registry.rb` (no matches) | UPDATE-IN-PLACE: replace with real flow (poll `system_get_instance`); replace `execute_skill` with `execute_agent` or `discover_skills`+`get_skill_context` |
| MED | INCONSISTENCY | docs/MODULE_MANIFEST_COMPLETE_SCHEMA.md:78-99 vs runbook/tutorial | Schema doc says `file_spec` is a flat list of glob strings (matches code). Runbook + tutorial 02 use a nested `{ include, exclude }` structure. Two docs disagree on the same field. | `modules/.schema/module-manifest.schema.json:25`; `app/services/system/manifest_import_service.rb:87` | UPDATE-IN-PLACE: fix runbook + tutorial to match schema doc (covered by HIGH findings above) |
| MED | GAP | docs/ARCHITECTURE.md + docs/SKILL_EXECUTORS.md | New skill executors added since the doc was last updated have NO architectural-overview coverage: `platform_deploy`, `platform_maintenance`, `platform_resilience`, `configure_sdwan_for_project`, `provision_full_stack`, `scale_project`, `relocate_workload`, `attach_storage`, `deploy_app_code`, `federation_manager`, architecture_* family, OVN/IPFIX/host-bridge SDWAN compose track, `discover_packages_by_intent`, `list_package_repositories_summary`, `suggest_architectures_for_fleet`, `package_module_create`, `package_module_refresh`, `package_repository_sync`, `cve_remediation_orchestration`. | `ls app/services/system/ai/skills/*_executor.rb` (40 total — 14 covered in depth, 26 new) | ADD-NEW-CONTENT: add a "Recent additions" section to SKILL_EXECUTORS.md grouping by capability area |
| MED | GAP | docs/runbooks/ | The `platform_deploy` skill (`system-platform-deploy`) is the entry point for child-platform spawn (Decentralized Federation). No runbook covers it. | `app/services/system/ai/skills/platform_deploy_executor.rb` | ADD-NEW-CONTENT: add `docs/runbooks/platform-spawn.md` (or reuse `docs/federation/`) |
| LOW | INACCURACY | docs/runbooks/module-authoring.md:170-195 | Two-stage CI pipeline shown uses `docker build -t module-builder:${{ github.sha }}`, but canonical workflow in `templates/module-repo/.gitea/workflows/build.yaml` uses buildah + mkcomposefs. Operators copy-pasting would diverge. | `extensions/system/docs/ARCHITECTURE.md:54-71` | UPDATE-IN-PLACE: point readers to `templates/module-repo/.gitea/workflows/build.yaml` |
| LOW | INACCURACY | docs/tutorials/01-first-boot.md:55-57 | "LibvirtRunner (`real`)", "RecorderRunner (`local`)", "DisabledRunner (`disabled`)" — actual `POWERNODE_LIBVIRT_MODE` values are `real | recorder | disabled` (no `local`). | `extensions/system/server/app/services/providers/local_qemu_provider.rb` | UPDATE-IN-PLACE: `local` → `recorder` |
| LOW | INACCURACY | docs/runbooks/node-provisioning.md:118 | "agent reads from `cmdline` / `virtio-fw-cfg` / cloud metadata" — ARCHITECTURE.md §2 lists ~8 identity discovery sources. The runbook understates by ~6. | `docs/ARCHITECTURE.md:147-153` | UPDATE-IN-PLACE: enumerate the full list or hyperlink |
| LOW | INACCURACY | docs/MODULE_MANIFEST_COMPLETE_SCHEMA.md:545 | Local-validation snippet uses `npx --yes ajv-cli@5 …` — workflow uses `yq`. Reasonable to show both forms. | `.gitea/workflows/module-validate.yaml` | UPDATE-IN-PLACE (cosmetic) |
| LOW | INACCURACY | docs/SKILL_EXECUTORS.md:550-552 | SDWAN-skill section covers only 4 SDWAN skills, missing 5 new compose skills (`sdwan_host_bridge_compose`, `sdwan_ovn_compose_topology`, `sdwan_ovn_apply_acl`, `sdwan_ipfix_collector_compose`, `sdwan_compose_full_topology`). | `app/services/system/ai/skills/sdwan_*_executor.rb` (9 files) | ADD-NEW-CONTENT: dedicated "SDWAN composition skills" subsection |

### Agent 2 — Container runtimes + disk image CI (37 findings)

| Severity | Type | File:Line | Finding | Code citation | Recommended action |
|---|---|---|---|---|---|
| HIGH | BROKEN | `executors/disk_image/promote_publication.rb:11-16` + `rollback_publication.rb:10-16` | **CODE BUG**: `PromotePublication` and `RollbackPublication` autonomy executors call `pub.promote!` (no such AASM event) and fall back to `pub.update!(active: true, promoted_at: Time.current)` (no such columns). Either branch raises. The seed mapping `system.disk_image_publication_promote → require_approval` cannot be executed; approving in UI calls this and crashes. | `disk_image_publication.rb:34` STATUSES (`queued/awaiting_upload/verifying/published/failed/retired/purged`); `system_disk_image_manager_agent.rb:71-76`; controller does it correctly at `disk_image_publications_controller.rb:99-115` | Replace fallback with controller's column-flip. **See §6 B1.** |
| HIGH | INACCURACY | `DISK_IMAGE_MANAGER_AGENT.md:30` "6 intervention policies" | Seed has 6 policies, **but two of them** (`system.disk_image_webhook_revoke`, `system.disk_image_webhook_rotate_secret`) have **no executor** in `executors/disk_image/`. Only 4 executors exist for 6 policies. Doc tells operators they can rotate webhook secret via autonomy; the action never fires. | `executors/disk_image/` (4 files); seed policies require 6 | UPDATE-IN-PLACE: doc should flag 2/6 as aspirational, OR (preferable) add `RevokeWebhook` + `RotateWebhookSecret` stubs. **§6 B2 — NEEDS-DECISION**. |
| HIGH | BROKEN | `DISK_IMAGE_CI.md:103-114` "Step 2: Provision the build webhook" | Doc shows `platform.provision_disk_image_webhook({ node_platform_id })` returning hardcoded URL `…/api/v1/system/webhooks/disk_image_built`. Code takes **`label`** (NOT `node_platform_id`) and builds URL `/api/v1/system/webhooks/disk_image/built/<webhook_id>`. Webhooks are **per-pipeline**, not per-platform. Runbook copy-paste won't reach the receiver. | `disk_image_operator_tool.rb:38-43, 230-233`; `disk_image_built_controller.rb:7`; `disk_image_webhooks_controller.rb:105` | REWRITE-SECTION |
| HIGH | INACCURACY | `runbooks/disk-image-ci.md:78-86` | Same as above — `provision_disk_image_webhook` shown taking `node_platform_id`, `webhook_url`, `shared_secret`. Real tool only takes `label`. `webhook_url` doesn't exist as a param. | `disk_image_operator_tool.rb:79-97` | REWRITE-SECTION |
| HIGH | INACCURACY | `runbooks/disk-image-ci.md:107-113` Phase 3 | `platform.bootstrap_disk_image_ci({ node_platform_id, ref, arches })` — `bootstrap_disk_image_ci` is **not** a build trigger. Real params are `owner`, `repo`, `label`, `platform_api_base`, `create_platform_read_token`. No `ref` or `arches`. Triggering a build is `dispatch_gitea_workflow`. | `disk_image_operator_tool.rb:51-62, 124-227` | REWRITE-SECTION |
| HIGH | INACCURACY | `DISK_IMAGE_CI.md:86-93` `bootstrap_disk_image_ci({ account_id })` | Tool takes `owner`, `repo`, `label`. `account_id` is implicit from auth context, not a parameter. | `disk_image_operator_tool.rb:51-62` | UPDATE-IN-PLACE |
| HIGH | INACCURACY | `DISK_IMAGE_CI.md:244 / runbooks/disk-image-ci.md:244` `platform.bootstrap_disk_image_ci({ account_id, force: true })` | `force` parameter does not exist. Tool is naturally idempotent on `label`. | `disk_image_operator_tool.rb:121-152` | UPDATE-IN-PLACE |
| HIGH | INACCURACY | `tutorials/12-disk-image-ci.md:243-247` Step 6 `system_set_disk_image_retention({ retention_count, retention_days })` | Tool only supports `retention_count`. `retention_days` is not implemented — `DiskImageRetentionService` uses hard-coded `DEFAULT_GRACE_DAYS = 7`. Platform silently ignores. | `system_fleet_tool.rb:660-666, 2449-2463`; `disk_image_retention_service.rb:29, 48` | UPDATE-IN-PLACE: drop `retention_days`; document 7-day grace |
| HIGH | INACCURACY | `runbooks/disk-image-ci.md:172-178` Phase 6 `system_set_disk_image_retention({ routine_days, critical_days })` | Both params fictional. Tool only supports integer `retention_count`. The "90 days routine, 365 days critical" defaults (lines 168-169) are also fictional. | Same | UPDATE-IN-PLACE |
| HIGH | INACCURACY | `runbooks/disk-image-ci.md:50-58` Phase 1 `system_provision_ci_worker({ hostname, provider_region_id, provider_instance_type_id, build_targets })` | MCP action only takes `name`. Does NOT provision a NodeInstance — creates a `Worker` with role `ci_worker` and returns a token. Doc paints a totally different feature. | `system_fleet_tool.rb:667-671, 2466-2479` | REWRITE-SECTION |
| HIGH | INACCURACY | `tutorials/12-disk-image-ci.md:90-108` Step 1 "The runner provisions as a NodeInstance, registers itself with Gitea, and gets repository secrets…" | Same — `bootstrap_disk_image_ci` calls `Worker.create_worker!`; does NOT provision a NodeInstance. Returns webhook URL + CI worker token; operator must install/register a Gitea runner themselves. | `disk_image_operator_tool.rb:124-227` | REWRITE-SECTION |
| HIGH | GAP | `runbooks/disk-image-ci.md:23-28` "two-stage build (Containerfile builder → composefs composer)" + tutorial 12 references mmdebstrap+composefs+fs-verity | The disk image ingest path (`DiskImageOciIngestService`, `DiskImageDirectUploadIngestService`, `DiskImagePublicationProcessor`) verifies cosign + SHA256 only. Nothing produces/verifies "fs-verity digests" or "composefs blobs". Runbook implies a multi-stage pipeline that does not exist server-side. | grep for `fs-verity`, `mkcomposefs`, `composefs_digest` returns no matches in disk image services | NEEDS-DECISION: (a) implement composefs verification, or (b) replace narrative with what the pipeline actually does (cosign + SHA256 + OCI pull). |
| HIGH | INACCURACY | `tutorials/12-disk-image-ci.md:228-235` events | Actual events from `DiskImagePublicationProcessor`: `system.disk_image_published` and `system.disk_image_publish_failed`. Retention emits `system.disk_image_retention_swept`. No `webhook_received`, `cosign_verified`, `publication_created`, or `platform_updated` events exist. | `disk_image_publication_processor.rb:179-226`; `disk_image_retention_service.rb:98-116` | UPDATE-IN-PLACE: replace fictional event list with actual two |
| HIGH | INACCURACY | `runbooks/disk-image-ci.md:131-138` `system_list_disk_image_publications` returns `version, signed_at, composefs_digest` | Real serializer returns `id, node_platform_id, status, arch, git_sha, oci_ref, sha256, size_bytes, published_at, retired_at`. No `version`/`signed_at`/`composefs_digest`. | `system_fleet_tool.rb:2524-2537` | UPDATE-IN-PLACE |
| HIGH | INACCURACY | `DISK_IMAGE_CI.md:158-164` publication fields | Closer but still wrong: no `built_at` (it's `published_at`), no `cosign_identity` field, no `sbom_url` field. | `disk_image_publication.rb` columns | UPDATE-IN-PLACE |
| MED | INCONSISTENCY | `DISK_IMAGE_MANAGER_AGENT.md:13` "ticks every 300 seconds" | Seed matches; however `FleetAutonomyService` and `DecisionEngine` have zero `disk_image` references. Agent has policies + approval chain but **no autonomous tick path** that perceives signals → actions. **§6 B3.** | `fleet/fleet_autonomy_service.rb`, `fleet/decision_engine.rb` (no `disk_image` refs) | NEEDS-DECISION |
| MED | GAP | `DISK_IMAGE_MANAGER_AGENT.md:114-125` Sensor → Action Map | No sensors emit any of the listed signals (`system.disk_image_published`, `system.disk_image_verified`, `system.disk_image_regression_reported`, `system.disk_image_retention_exceeded`, `system.disk_image_webhook_secret_stale`). Only `DiskImagePublicationProcessor` emits `system.disk_image_published` from the webhook receive path. | Grep returns zero hits in `fleet/sensors/` | NEEDS-DECISION |
| MED | INACCURACY | `DISK_IMAGE_CI.md:96-99` | "creates: A `System::Task` of type `ci_worker_provision`; A self-hosted Gitea Actions runner labeled `disk-image-builder`" — neither happens. Creates a `Worker` (not `System::Task`); no runner spin-up (operator manual). | `disk_image_operator_tool.rb:144-162` | REWRITE-SECTION |
| MED | INACCURACY | `runbooks/disk-image-ci.md:235-239` `system_list_tasks({ task_type: "ci_worker_provision" })` | No `ci_worker_provision` task type. CI worker provisioning is synchronous, not a `System::Task` row. | Same | UPDATE-IN-PLACE: delete fallback |
| MED | INACCURACY | `CONTAINER_RUNTIMES.md:262-265` | `runtime_config` GET endpoint + agent's dockerd overrides exist (slice 10 wired). But "restart `powernode-agent` to force immediate" — actual force command isn't documented; agent uses reconcile tick (~30s). | `runtime_controller.rb:72-123`; `agent/internal/dockerd/overrides.go` | LOW priority — verify reconcile interval |
| MED | INACCURACY | `CONTAINER_RUNTIMES.md:243-250` `system.runtime_docker_tls_rotate` skill | `system_runtime_manager_agent.rb:114` lists this as a policy, but no skill executor exists. Action-category policy is wired; the executor that would handle it does not. **§6 B4.** | seed lists 8 policies; only binds 2 skills | NEEDS-DECISION |
| MED | INACCURACY | `CONTAINER_RUNTIMES.md:339-341` and `tutorials/04-k3s-cluster.md:285-298` reference `agent/internal/k3sd/` files | Real package has `bootstrap_config_api.go` (Phase O4 slice handling cni_plugin selection) that's not in the doc list. | `extensions/system/agent/internal/k3sd/` listing | LOW: UPDATE-IN-PLACE to add `bootstrap_config_api.go` |
| MED | INACCURACY | `tutorials/04-k3s-cluster.md:281-283` + `tutorials/05-multi-cluster-k3s.md:313-317` + `CONTAINER_RUNTIMES.md:297-303` | Phase O4 CNI auto-default (`network_profile` → CNI plugin) is **shipped** but described as "future" / "until pod_subnet_prefix lands". The `cni_plugin` argument to `bootstrap!` and the `network_profile` discriminator are not documented anywhere. | `kubernetes_cluster_provisioner_service.rb` `NETWORK_PROFILE_TO_CNI`, `resolve_bootstrap_cni_plugin!`, `enforce_cni_profile_compatibility!`, `CniProfileMismatchError` | ADD-NEW-CONTENT: section on CNI choice + heavyweight vs lightweight profile + `cni_plugin` override |
| MED | INACCURACY | `tutorials/05-multi-cluster-k3s.md:81-87` `system_sdwan_create_network({ … prefix: "fd00:abcd:2::/64" })` | Network CIDR is server-derived; operator doesn't supply `prefix`. Cosmetic but misleading. (Agent 3 covers SDWAN cross-cut.) | (cross-ref) | LOW |
| MED | INACCURACY | `CONTAINER_RUNTIMES.md:285-295` "aspirational — use `system_provision_instance` / `system_terminate_instance` and `platform.recent_events`" | Correctly flagged as aspirational; matches ASPIRATIONAL_MCP.md. | OK | (no action) |
| MED | INACCURACY | `runbooks/disk-image-ci.md:199-204` `system_get_instance_stats`, `system_update_node_platform` | Neither MCP tool exists. | grep returns 0 hits | UPDATE-IN-PLACE: drop or move to ASPIRATIONAL_MCP |
| MED | INACCURACY | `tutorials/12-disk-image-ci.md:326` `platform.agent_introspect({ agent_id: "disk_image_manager_agent" })` | `agent_introspect` takes UUID, not string slug. Same misuse in `tutorials/04-k3s-cluster.md:263` (`"sdwan_manager_agent"`). Will 404. | `platform_api_tool_registry.rb` agent_introspect schema | UPDATE-IN-PLACE: show `agent_id: "<uuid>"` or fetch via `list_agents` |
| LOW | INCONSISTENCY | `runbooks/docker-compose-cutover.md:43-46` "module manifests on disk: `ls extensions/system/modules/powernode-*/manifest.yaml` returns 9 files" + §1 shows 8 modules | Discrepancy between 8 modules and "9 files". | `extensions/system/server/db/seeds/powernode_platform_modules.rb` | UPDATE-IN-PLACE: reconcile count |
| LOW | INACCURACY | `runbooks/multi-cluster-k3s.md:135-140` `system_sdwan_failover_virtual_ip({ dry_run: true })` returning `score: 0.92` candidates | (SDWAN cross-cut — Agent 3) | (defer) | — |
| LOW | INACCURACY | `runbooks/docker-compose-cutover.md:141-144` `SMOKE_HUB_HOSTNAME` env var | Verify env exists; flagging as needs-verify. | `extensions/system/server/db/seeds/smoke_test_powernode_hub.rb` | LOW |
| LOW | STALE | `DISK_IMAGE_CI.md:307-315` "registry-mirrors + `~/.docker/config.json` credential injection" | `extensions/system/agent/internal/dockerd/` does not write to `~/.docker/config.json` (no docker-config.go). Aspirational. | `agent/internal/dockerd/` listing | UPDATE-IN-PLACE or remove |
| LOW | INACCURACY | `DISK_IMAGE_CI.md:215-218` `/api/v1/system/disk_image_webhooks/recent` | Route does not exist. | `extensions/system/server/app/controllers/api/v1/system/disk_image_webhooks_controller.rb` | UPDATE-IN-PLACE: REST index + filter |
| LOW | INACCURACY | `DISK_IMAGE_MANAGER_AGENT.md:161-200` `system_revert_disk_image` aspirational | Correctly captured in `.verify/ASPIRATIONAL_MCP.md`. | OK | (no action) |
| LOW | INCONSISTENCY | `CONTAINER_RUNTIMES.md` Phase 3 reference | `RuntimeController#RUNTIME_MODULES` only lists `docker`, `k3s_server`, `k3s_agent`. Phase 3 (kubeadm + HA control plane) accurately described as not wired. | OK | (no action) |
| LOW | GAP | `CONTAINER_RUNTIMES.md` does not mention `runtime_config` GET endpoint (slice 10 daemon overrides + Phase O4 K3s bootstrap_config) | Endpoint exists; troubleshooting mentions slice 10 overrides but doesn't surface API. | Same | ADD-NEW-CONTENT: brief subsection on `GET /api/v1/system/node_api/runtime/:runtime/config` |
| LOW | INACCURACY | `tutorials/12-disk-image-ci.md:285-288` `system_get_instance` returns `booted_from_oci_ref` | No `booted_from_oci_ref` column on `system_node_instances`. Plausibly aspirational. | (no column) | LOW |
| LOW | INACCURACY | `DISK_IMAGE_CI.md:223-232` cosign verify troubleshooting `publication_status="cosign_verify_failed"` + `publication_error` | Status enum: `queued/awaiting_upload/verifying/published/failed/retired/purged` (no `cosign_verify_failed`); failure column is `error_message`. NodePlatform has `disk_image_publication_status` + `disk_image_publication_error`. Doc conflates. | `disk_image_publication.rb:34, 52`; migration | UPDATE-IN-PLACE |

### Agent 3 — SDWAN + federation + ACME + credentials (28 findings)

| Severity | Type | File:Line | Finding | Code citation | Recommended action |
|---|---|---|---|---|---|
| HIGH | INACCURACY | `docs/SDWAN_MANAGER_AGENT.md:30` | Claims "28 intervention policies" — actual seed contains **31** policies. Same claim in `extensions/system/CLAUDE.md:38`. | `db/seeds/system_sdwan_manager_agent.rb:83-134` (31 entries) | UPDATE-IN-PLACE — change to "31 intervention policies" in both files |
| HIGH | STALE | `docs/runbooks/sdwan-network-setup.md:3` | Header says "slice 11 federation acceptance in active sweep" — but `system_sdwan_accept_federation_peer` MCP action is registered and `Sdwan::Executors::AcceptFederationPeer` executor exists. Slice 9 LIVE per memory. | `platform_api_tool_registry.rb:148`; `app/services/sdwan/executors/accept_federation_peer.rb:1-19` | UPDATE-IN-PLACE — remove "slice 11 in active sweep" verbiage |
| HIGH | INACCURACY | `docs/runbooks/sdwan-network-setup.md:22` | Concept table lists `FederationPeer` as `Sdwan::FederationPeer`. Actual model is `System::FederationPeer`. No `Sdwan::FederationPeer` class. | `app/models/system/federation_peer.rb:1-30`; absent from `app/models/sdwan/` | UPDATE-IN-PLACE — change to `System::FederationPeer` |
| HIGH | STALE | `docs/runbooks/sdwan-network-setup.md:286-306` | "Phase 9 — Federation peers (slice 11, in sweep)" claims acceptance "operator-driven via SQL until slice 11 lands" and marks accept MCP as "future". Both are LIVE. | `app/services/sdwan/executors/{propose,accept,revoke}_federation_peer.rb`; registry @ 147-149 | REWRITE-SECTION |
| HIGH | INACCURACY | `docs/runbooks/federation-setup.md:140-149` | `system_sdwan_create_access_grant` shown with `federation_peer_id` + `remote_subject` + `resource_kind` — those are `System::FederationGrant` attributes (cross-peer service grant). But `Sdwan::AccessGrant` is a VPN user-access entitlement. Two grant models conflated. | `app/models/sdwan/access_grant.rb:11-23` vs `app/models/system/federation_grant.rb:37-44` | REWRITE-SECTION |
| HIGH | INACCURACY | `docs/tutorials/11-federation.md:104-117` | Step 1 calls `system_sdwan_propose_federation_peer` with `spawn_mode`/`child_template_id`/`child_provider_region_id`/`proposed_routes`/`proposed_capabilities` — these are NOT model attributes. Spawning is via `POST /api/v1/system/federation/children/spawn` → `System::SpawnPlatformService.spawn!`. Tutorial conflates "propose peer" (OOB) with "spawn child" (parent-initiated). | `spawn_platform_service.rb:43-50`; `children_controller.rb:61-95`; `propose_federation_peer.rb:8-12` | REWRITE-SECTION |
| HIGH | STALE | `docs/federation/MIGRATION_DEVELOPER_GUIDE.md:275-280` | "Bidirectional sync" listed as out-of-scope-v1 and "Continuous sync requires a future `replication_pair` mapping (P9 hypothetical)" — `MigrationChain` + `ChainComposer` + `ChainExecutor` + `ChainSweepService` are all implemented (P9.5 multi-hop chains). | `app/services/system/migrations/chain_composer.rb:5-25`, `app/models/system/migration_chain.rb`, `app/services/system/migrations/{chain_executor,chain_sweep_service}.rb` | UPDATE-IN-PLACE — move multi-hop OUT of "not in v1" section |
| MED | INACCURACY | `docs/SDWAN_MANAGER_AGENT.md:23` | Says "the SDWAN Manager calls these compose skills indirectly via federation" — cross-cutting topology compose skills are bound to System Topology Designer, not SDWAN Manager. Concierge invokes Topology Designer via `execute_agent`. | `extensions/system/CLAUDE.md` Topology Designer section | UPDATE-IN-PLACE — clarify |
| MED | INACCURACY | `docs/runbooks/federation-setup.md:103-110` | `curl` calls list `/api/v1/system/sdwan/federation_peers` — `peer_kind: "platform"` peers live on `Children` controller at `/api/v1/system/federation/children`. | `config/routes.rb:301-302`, `:864` | UPDATE-IN-PLACE — clarify which endpoint to query |
| MED | INACCURACY | `docs/runbooks/federation-setup.md:42-46` | `platform.system_sdwan_propose_federation_peer` invoked with `peer_kind: "platform"` + `spawn_role: "symmetric"` — symmetric path uses `Api::V1::System::Platform::PeersController#create` which defaults `spawn_role = "symmetric"`. | `peers_controller.rb:72`; `propose_federation_peer.rb:8-12` | UPDATE-IN-PLACE — point to actual REST or correct MCP shape |
| MED | INACCURACY | `docs/federation/SOCIAL_CONTRACT.md:21-23,137-147` | Claims "violations surfaced via `Sdwan::FederationGovernance` scanner; repeated violations may auto-suspend". Scanner emits findings but no `SocialContractValidator` class and no auto-suspend logic. | No matches for `TwelveCommitments`/`SocialContractValidator` in codebase; `app/services/sdwan/federation_governance.rb:45-65` (findings only) | UPDATE-IN-PLACE — soften to "may be auto-flagged" OR mark auto-suspend as aspirational |
| MED | INACCURACY | `docs/federation/SPAWN_MODES.md:30-34` | `spawn_mode` validation accepts a 4th value: `out_of_band` (for non-spawn peers). File doesn't note this. | `app/models/system/federation_peer.rb:29` (`SPAWN_MODES = %w[managed_child autonomous_peer cluster_member out_of_band]`) | ADD-NEW-CONTENT — footnote about `out_of_band` |
| MED | INACCURACY | `docs/SDWAN_MANAGER_AGENT.md:152` | Skill bindings list 4 skills. Should mention `sdwan_route_policy_audit` (autonomy policy at seed line 91 — `auto_approve` policy without a corresponding skill binding). | `db/seeds/system_sdwan_manager_agent.rb:91` | UPDATE-IN-PLACE |
| MED | STALE | `docs/runbooks/federation-troubleshooting.md:108-125` | mTLS section says "wiring for full P2.5 cert/key storage is responsibility of the AcceptController + a forthcoming CSR generation flow". Per `project_reverse_proxy_state` memory, production Traefik does not have mTLS termination configured at all; JWT is operational auth. | `project_reverse_proxy_state` memory | UPDATE-IN-PLACE — clarify production state (JWT only); mark mTLS as forward-compat scaffold |
| MED | STALE | `docs/runbooks/vault-credential-restoration.md:21-26` | Mentions PKI not mounted (correct) but doesn't list which secrets engines ARE mounted today. Steps assume PKI present. | `project_vault_pki_state` memory; `docs/credential-restoration.md:163-183` (transit mounting) | UPDATE-IN-PLACE — add explicit "mounted today: KV v2, transit; aspirational: pki, pki_int" |
| MED | INACCURACY | `docs/runbooks/acme-issuance.md:23-32` | Architecture says ACME services live at `extensions/system/server/app/services/system/acme/` — actual path is `extensions/system/server/app/services/acme/` (no `system/` middle). | `app/services/acme/{certificate_manager,renewal_sweep_service,...}.rb` | UPDATE-IN-PLACE — fix paths |
| MED | INACCURACY | `docs/runbooks/acme-issuance.md:73-77` | "implement a Go adapter in `extensions/system/server/vendor/powernode-acme/internal/dns/`" — directory doesn't exist; ACME providers (cloudflare/hetzner/digital_ocean/route53) are Ruby modules. "powernode-acme Go binary" framing repeated at line 24. | `app/services/acme/{cloudflare,hetzner,digital_ocean,route53}/` (Ruby) | NEEDS-DECISION — implement Go binary OR rewrite as Ruby |
| MED | INACCURACY | `docs/runbooks/acme-issuance.md:155-159` | "Sidekiq cron every 6h" for renewal — verify against `sidekiq.yml`. | `app/services/acme/renewal_sweep_service.rb:1-20` | UPDATE-IN-PLACE — sync cron name (low priority) |
| MED | INACCURACY | `docs/runbooks/acme-smoke.md:104-110` | Acceptance Scenario 4 tcpdump interface ambiguous. | n/a | UPDATE-IN-PLACE — clarify hub2 ingress |
| LOW | INACCURACY | `docs/runbooks/sdwan-network-setup.md:330-339` | "~70 actions" for `system_sdwan_*` — actual count needs verification. | `platform_api_tool_registry.rb` (~70 sdwan entries) | UPDATE-IN-PLACE — verify or use "70+" |
| LOW | INACCURACY | `docs/runbooks/federation-troubleshooting.md:5` | "see `System::FederationPeer::TRANSITIONS`" — `TRANSITIONS` is an attr table (plain hash), not AASM. | `app/models/system/federation_peer.rb:38` | UPDATE-IN-PLACE |
| LOW | INCONSISTENCY | `docs/federation/SOCIAL_CONTRACT.md:147-149` | Scanner findings list includes social-contract-adjacent items (peer_capability_drift, peer_schema_version_drift, peer_residency_missing) — scanner DOES enforce some commitments. Doc downplays. | `app/services/sdwan/federation_governance.rb:25-60` | UPDATE-IN-PLACE — link findings to commitment numbers |
| LOW | INACCURACY | `docs/runbooks/sdwan-network-setup.md:39-40` | "single-FRR-per-host: only the first iBGP network's `BgpConf` is active per host" — matches memory but worth forward-link to deferral. | `app/services/sdwan/bgp/config_compiler.rb` | UPDATE-IN-PLACE — explicit "multi-network aggregation deferred" |
| LOW | GAP | `docs/SDWAN_MANAGER_AGENT.md` | Signal naming inconsistency: mermaid uses `system.sdwan_peer_drift`; sensor → action map uses `sdwan.peer_reachability`. | Internal cross-reference | UPDATE-IN-PLACE — align signal naming |
| LOW | INACCURACY | `docs/tutorials/11-federation.md:284-296` | "Acceptance token expired (default 30 min)" — actual default per setup runbook + `SpawnPlatformService::DEFAULT_TOKEN_TTL` is 7 days. | `app/services/system/spawn_platform_service.rb`; `docs/runbooks/federation-setup.md:66` | UPDATE-IN-PLACE — "7 days default" |
| LOW | INCONSISTENCY | `docs/runbooks/sdwan-network-setup.md:36-39` | `routing_mode: "static" | "ibgp"` accurate; but `pod_subnet_prefix` documented as "slice 9: future" while slice 9 LIVE. | Memory `project_sdwan_routing_state` | UPDATE-IN-PLACE — clarify pod_subnet_prefix scope |
| LOW | INACCURACY | `docs/federation/NETWORK_TRUST.md:226-232` | "Grants created before §K migration ship with all three allowlists empty" — `FederationGrant#node_instance_ids/sdwan_network_ids/source_cidrs` default to `[]`. Doc should reference `unrestricted?` predicate. | `app/models/system/federation_grant.rb:96-99` | UPDATE-IN-PLACE — add reference to `#unrestricted?` |
| LOW | GAP | `docs/credential-restoration.md:328` | "Sample consumer: `provider_connection.rb`" — verify file exists; threat-model.md at line 331 references `docs/system/threat-model.md` which is a parent path. | Cross-file ref | UPDATE-IN-PLACE — verify path |

### Agent 4 — Fleet autonomy + sensors + agents + GitOps + use-cases (31 findings)

| Severity | Type | File:Line | Finding | Code citation | Recommended action |
|---|---|---|---|---|---|
| HIGH | INACCURACY | `docs/FLEET_SENSORS.md:3` | Doc states "ships **12 concrete sensors**" — actual **18 concrete + BaseSensor** (19 .rb files). FleetAutonomyService `SENSORS` registers **16** for live tick. | `app/services/system/fleet/sensors/`; `fleet_autonomy_service.rb:127-153` | UPDATE-IN-PLACE |
| HIGH | GAP | `docs/FLEET_SENSORS.md:18-31` (mermaid) + `:52-146` (sensor reference) | Mermaid + reference enumerate only 12 sensors. **6 missing from doc**: `instance_state_drift_sensor`, `gitops_drift_sensor`, `package_drift_sensor`, `project_slo_sensor`, `sdwan_credential_expiry_sensor`, `storage_assignment_drift_sensor`. | `instance_state_drift_sensor.rb:21`; `gitops_drift_sensor.rb:20`; `package_drift_sensor.rb:15`; `project_slo_sensor.rb:28`; `sdwan_credential_expiry_sensor.rb:28`; `storage_assignment_drift_sensor.rb:14` | ADD-NEW-CONTENT — per-sensor block for each |
| HIGH | INCONSISTENCY | `docs/FLEET_SENSORS.md:140-146` vs `trading_pressure_sensor.rb:18` | Doc says "**Source:** `external_pressure_sensor.rb` (historically named `trading_pressure_sensor.rb`)". Actual filename is `trading_pressure_sensor.rb`; class is `TradingPressureSensor`. No `external_pressure_sensor.rb` exists. ARCHITECTURE.md §4 line 224 also uses `ExternalPressureSensor` — naming fiction. | `app/services/system/fleet/sensors/trading_pressure_sensor.rb:18` | NEEDS-DECISION (rename in docs OR actually rename file/class) |
| HIGH | INACCURACY | `docs/FLEET_SENSORS.md:208` | Doc claims "(19 policies)". Seed file has **18 policies**. | `db/seeds/fleet_autonomy_agent.rb:89-129` | UPDATE-IN-PLACE — 18 |
| HIGH | INACCURACY | `docs/FLEET_SENSORS.md:221-245` Fleet Autonomy policy table | Doc lists 19 policies + 8 SDWAN rows that moved out 2026-05-10. Reality: Fleet Autonomy 18 (no SDWAN), SDWAN Manager 31. | `db/seeds/fleet_autonomy_agent.rb:130-132` (comments noting moves to other agents) | REWRITE-SECTION — split into Fleet Autonomy (18), CVE Responder (5), SDWAN Manager (31), Disk Image Manager (6), Runtime Manager (8) |
| HIGH | INACCURACY | `extensions/system/CLAUDE.md:33` | SDWAN Manager "**28 intervention policies**" — seed has 31. | `db/seeds/system_sdwan_manager_agent.rb:83-134` | UPDATE-IN-PLACE — 31 |
| HIGH | INACCURACY | `extensions/system/CLAUDE.md:30` | Concierge "**4 read-shape skills bound**" — seed binds **7**. | `db/seeds/system_concierge_agent.rb:206-214` | UPDATE-IN-PLACE — 7 |
| HIGH | INACCURACY | `db/seeds/system_concierge_agent.rb:78-82` (system_prompt) | Concierge prompt says "**14 system extension skills bound to autonomy + chat agents**" and "**4 read-shape skills bound to YOU**" — actual is 7 read-shape; total executors 40 (not 14). | Same file; `app/services/system/ai/skills/` (40 executors) | UPDATE-IN-PLACE — correct prompt |
| HIGH | INACCURACY | `db/seeds/system_concierge_agent.rb:91-110` ("Agent Topology") | Says "Four system extension agents share the operator approval queue" — actual **7**. Also says Fleet Autonomy has "8 skills bound. 17 intervention policies" — actual 10 skills (CLAUDE.md), 18 policies. | `extensions/system/CLAUDE.md:23-37` (7 agents); seed (18 policies) | UPDATE-IN-PLACE — rewrite section in Concierge system_prompt |
| HIGH | STALE | `docs/ARCHITECTURE.md:216` | "**Six sensors** detect operational signals:" — followed by 8-bullet list. Actual: 18 (or 16 registered). | `fleet_autonomy_service.rb:127-153` | UPDATE-IN-PLACE |
| HIGH | INACCURACY | `docs/ARCHITECTURE.md:224` | "ExternalPressureSensor" — actual class is `TradingPressureSensor`. | `app/services/system/fleet/sensors/trading_pressure_sensor.rb:18` | UPDATE-IN-PLACE |
| HIGH | INACCURACY | `docs/runbooks/cve-response.md:205` + `Tutorial 07:262-265` | Reference "Fleet Autonomy" intervention policy + `agent_introspect({ agent_id: "fleet_autonomy_agent" })` for `system.cve_remediate` — CVE policies live on **CVE Responder** since 2026-05-10. | `db/seeds/system_cve_responder_agent.rb:71-84`; `db/seeds/fleet_autonomy_agent.rb:131` (move comment) | UPDATE-IN-PLACE — `cve_responder_agent` |
| HIGH | INCONSISTENCY | `docs/tutorials/07-cve-response.md:299-300` | Mentions "**CVE Responder agent**" — but Step 5 (approval) still references generic flow. | seed | UPDATE-IN-PLACE — cleanup |
| HIGH | INCONSISTENCY | `docs/FLEET_SENSORS.md:36-43` Executors list in mermaid | Lists `cert_rotate` but no such executor file exists. Mermaid lists 7 executors; directory has 40. | `app/services/system/ai/skills/` | UPDATE-IN-PLACE — either reference real executor or note illustrative |
| MED | STALE | `docs/agent-peering.md:5` | "Active stabilization sweep, Phase 6 (~80% complete). Target close: Q3 2026." — verify status. | `app/services/system/agent_peering_service.rb`; `app/services/system/peer_agent_mirror.rb` | NEEDS-DECISION |
| MED | STALE | `docs/gitops.md:3` + `:244-258` | "Active stabilization sweep, Phase 5 (~80% complete)". Directory has 6 services (`apply_service`, `desired_state_parser`, `desired_state_validator`, `diff_engine`, `reconciler`, `repo_sync_service`). "Auto-apply implementation is partial" — same hedge in runbook + tutorial 10. | `app/services/system/gitops/` (6 files) | NEEDS-DECISION — confirm if auto-apply shipped |
| MED | INCONSISTENCY | `docs/gitops.md:228-240` vs `app/services/system/gitops/` | Doc lists "5 services" but directory has 6 (`desired_state_validator` missing from doc). | `app/services/system/gitops/desired_state_validator.rb` | UPDATE-IN-PLACE — add validator |
| MED | STALE | `docs/tutorials/10-gitops-fleet.md:62-66` (status table) | "Proposal-apply: Partial — designed; full ApplyService landing in follow-up" + "Drift sensor: Partial — periodic compare designed". Both exist. | `gitops_drift_sensor.rb`; `apply_service.rb`; `fleet_autonomy_service.rb:148` registers GitopsDriftSensor | UPDATE-IN-PLACE — mark Shipped |
| MED | INACCURACY | `docs/tutorials/10-gitops-fleet.md:53` | "(per `system.gitops_*` intervention policy in Fleet Autonomy)" — no `system.gitops_*` policies in fleet seed. GitOps reconciliation creates proposals directly. | `db/seeds/fleet_autonomy_agent.rb:89-128`; `app/services/system/gitops/reconciler.rb` | UPDATE-IN-PLACE |
| MED | INACCURACY | `docs/runbooks/gitops-reconciliation.md:62` | "the drift sensor **(when shipped)** flags the mismatch" — sensor shipped. | `app/services/system/fleet/sensors/gitops_drift_sensor.rb` | UPDATE-IN-PLACE |
| MED | INACCURACY | `docs/runbooks/gitops-reconciliation.md:223-225` | "When the drift sensor **ships**, it emits `gitops.drift_detected`" — sensor exists. | Same | UPDATE-IN-PLACE |
| MED | INACCURACY | `docs/tutorials/09-honeypot-canary.md:278` | "the **11 other sensors** that watch your fleet" — actual 18. | `app/services/system/fleet/sensors/` | UPDATE-IN-PLACE — "17 other sensors" |
| MED | INACCURACY | `docs/USE_CASE_MATRIX.md:213` | Anti-pattern says pool "(slice 7 shipped)" — likely accurate; uses jargon. | `app/models/system/instance_pool.rb` | LOW cosmetic |
| MED | GAP | `docs/USE_CASE_MATRIX.md` | Does not mention 7-agent topology when referencing "the System Concierge should use this" (line 242). Concierge now delegates topology composition to Topology Designer via `execute_agent`. | `db/seeds/system_concierge_agent.rb:116-125` | ADD-NEW-CONTENT — brief mention of delegation |
| MED | INCONSISTENCY | `docs/FLEET_SENSORS.md:51-146` naming | Doc uses snake_case filename refs (`instance_status_sensor.rb`); ARCHITECTURE.md §4:217-224 uses PascalCase class names (`InstanceStatusSensor`). | n/a | LOW style |
| MED | STALE | `docs/FLEET_SENSORS.md:181-196` | "Sensor config MCP actions are aspirational" — verify if shipped. | Memory `project_system_mcp_gaps` (still 15 aspirational) | NEEDS-DECISION |
| LOW | INCONSISTENCY | `docs/agent-internals.md:35` | "The agent's `internal/` directory contains 23 packages" — assertion not deeply verified in this slice (Agent 5 does). | `agent/internal/` | (cross-ref Agent 5: confirmed 23) |
| LOW | INACCURACY | `docs/tutorials/07-cve-response.md:42` (+ CLAUDE.md:32 cron schedule) | `cve-response.md:97` says "every 6 hours via `system_cve_feed`"; CLAUDE.md says "hourly `SystemCveFeedJob`". Cron schedule discrepancy. | `cve-response.md:97` vs `CLAUDE.md:32` | NEEDS-DECISION — verify cron schedule |
| LOW | STALE | `docs/runbooks/cve-response.md:299-300` | Troubleshooting "Container image CVE not detected — CVE sensor covers `NodeModule` only" — accurate. Echoed in USE_CASE_MATRIX.md:198-204 + tutorial 07. | `docs/USE_CASE_MATRIX.md:198-204` | No action |
| LOW | INCONSISTENCY | `docs/agent-peering.md:6` | "Phase 6 (~80% complete). Target close: Q3 2026" — but `peer_agent_mirror.rb` exists. | n/a | NEEDS-DECISION |
| LOW | INACCURACY | `docs/runbooks/cve-response.md:6-7` | Status block says CVE Responder is wired end-to-end; Phase 5 body line 205 still says "Fleet Autonomy intervention policy". | Cross-reference | UPDATE-IN-PLACE |
| LOW | INACCURACY | `docs/FLEET_SENSORS.md:6` | "configurable via `autonomy_config.interval_seconds` on the **Fleet Autonomy agent**" — with 7-agent split, each domain agent has its own interval. | `db/seeds/system_disk_image_manager_agent.rb:60` (`interval_seconds: 300`) | UPDATE-IN-PLACE — mention per-agent intervals |

### Agent 5 — Top-level + cross-cutting + Go agent + initramfs (44 findings)

| Severity | Type | File:Line | Finding | Code citation | Recommended action |
|---|---|---|---|---|---|
| HIGH | INACCURACY | `extensions/system/README.md:52` | "12 fleet sensors" — actual 18. | Phase A baseline | UPDATE-IN-PLACE — 18 |
| HIGH | INACCURACY | `extensions/system/README.md:89` | "98 models across `system::*` + `sdwan::*`" — Phase A actual: 74 system + 46 sdwan = 120. | Phase A | UPDATE-IN-PLACE — "120 models (74 system::* + 46 sdwan::*)" |
| HIGH | INACCURACY | `extensions/system/README.md:89-90` | "~285 service classes" — actual 228 + 46 = 274. | Phase A | UPDATE-IN-PLACE — "~274" |
| HIGH | INACCURACY | `extensions/system/README.md:90` | "~138 controllers" — actual 135. | Phase A | UPDATE-IN-PLACE — "135" |
| HIGH | INACCURACY | `extensions/system/README.md:100` | "Database migrations (131)" — actual 137. | Phase A | UPDATE-IN-PLACE — "137" |
| HIGH | INACCURACY | `extensions/system/README.md:136` | "All 12 fleet sensors + intervention policy reference" — actual 18. | Phase A | UPDATE-IN-PLACE — "18" |
| MED | INACCURACY | `extensions/system/README.md:275` | M2 milestone says "~4,400 LOC across 9 packages" — `agent/README.md:45` says "23 packages". | `extensions/system/agent/README.md:45` | UPDATE-IN-PLACE — "23 packages" |
| MED | INACCURACY | `extensions/system/README.md:282` | M7 milestone says "8 sensors" — actual 18. | Phase A | UPDATE-IN-PLACE — "18 sensors" |
| LOW | INACCURACY | `extensions/system/README.md:191` | "agent/README.md — Go agent build + 16 subcommands" — actual 17 in `commands.go:57-74`. README.md:24-41 displays 16 but omits `prepare-root` and `version`. | `extensions/system/agent/cmd/powernode-agent/main.go:57-74` | UPDATE-IN-PLACE — "17 subcommands" + sync agent/README.md |
| HIGH | INACCURACY | `extensions/system/agent/README.md:24-41` | Subcommand table lists 16 entries but misrepresents set: missing `prepare-root` (registered `commands.go:151`), missing `version` (registered `main.go:99-100`). | `commands.go:151`; `main.go:90-100` | UPDATE-IN-PLACE — sync table |
| HIGH | GAP | `extensions/system/agent/internal/{boot,fleetevent,fsutil,lifecycle,manifest,migration,storage,systemd}/` | 8 packages lack `doc.go` (15 present, 8 missing per Phase A). | `ls extensions/system/agent/internal/<pkg>/doc.go` | ADD-NEW-CONTENT — add doc.go to each |
| HIGH | INACCURACY | `extensions/system/CLAUDE.md:11-12` | Count drift propagates; references SMOKE_TEST.md's stale "16 seeded" figure on line 79. | `extensions/system/CLAUDE.md:79` | UPDATE-IN-PLACE — "18 seeded scripts" |
| HIGH | INACCURACY | `extensions/system/docs/SMOKE_TEST.md:5` | "exercised through 16 seeded smoke scripts" — 18 files on disk. | `server/db/seeds/smoke_test_*.rb` (18 files) | UPDATE-IN-PLACE — "18" |
| HIGH | INACCURACY | `extensions/system/docs/SMOKE_TEST.md:56` | "All 18 smoke seeds" — internally consistent with catalog table (18 entries) but contradicts line 5's "16". | catalog | UPDATE-IN-PLACE — reconcile |
| HIGH | BROKEN | `extensions/system/docs/SMOKE_TEST.md:342` | `smoke_test_membership_credentials_vm.rb` cited as "referenced in seed header" — file does NOT exist on disk. Only `smoke_test_membership_credentials.rb` exists. | `ls server/db/seeds/smoke_test_membership*` | NEEDS-DECISION — remove ref, mark planned, or create file |
| HIGH | INACCURACY | `extensions/system/docs/SMOKE_TEST.md:60-79` | Catalog table includes `smoke_test_k3s_runtime.rb` and `smoke_test_ovn_k8s_cni.rb` (matches disk). Per Phase A "on-disk but undocumented" claim is stale; new finding is line-5 count (16) vs table-count (18). | catalog | UPDATE-IN-PLACE — fix line 5 |
| HIGH | INACCURACY | `extensions/system/CLAUDE.md:79` | "platform-level smoke catalog (16 seeded scripts, 7 passes...)" — actual 18 seeds, 8 passes (Pass 8 added in SMOKE_TEST.md lines 78-79). | `extensions/system/docs/SMOKE_TEST.md:78-79` | UPDATE-IN-PLACE — "18 seeded scripts, 8 passes" |
| HIGH | INACCURACY | `extensions/system/README.md:184` | "16 seeded scripts across 7 passes" — same drift. | catalog | UPDATE-IN-PLACE — "18 across 8 passes" |
| HIGH | INACCURACY | `extensions/system/docs/MCP_API_REFERENCE.md:61` | Header "Fleet, lifecycle, modules (42 actions)" for `system_*` (excl. sdwan) — actual registry: **102**. Doc enumerates only ~50. | `server/app/services/ai/tools/platform_api_tool_registry.rb` | UPDATE-IN-PLACE — "102 actions" |
| HIGH | INACCURACY | `extensions/system/docs/MCP_API_REFERENCE.md:148` | "SDWAN networking (52 actions)" — actual **69**. | Registry grep | UPDATE-IN-PLACE — "69" |
| HIGH | INACCURACY | `extensions/system/docs/MCP_API_REFERENCE.md:357` | Counts table says `system_*` (excl. sdwan) = 119 — actual 102. | Registry grep | UPDATE-IN-PLACE — "102" |
| HIGH | INACCURACY | `extensions/system/docs/MCP_API_REFERENCE.md:358` | Counts table says `system_sdwan_*` = 69 — correct (contradicts line 148). | Registry grep | (fix line 148) |
| LOW | INACCURACY | `extensions/system/docs/MCP_API_REFERENCE.md:359` | `kubernetes_*` = 5 — correct. | Registry | (no change) |
| LOW | INACCURACY | `extensions/system/docs/MCP_API_REFERENCE.md:360` | `docker_*` = 52 — correct. | Registry | (no change) |
| MED | INACCURACY | `extensions/system/docs/MCP_API_REFERENCE.md:361` | Total "~245" — actual 102 + 69 + 5 + 52 = **228**. | Sum | UPDATE-IN-PLACE — "228" |
| HIGH | GAP | `extensions/system/docs/MCP_API_REFERENCE.md` | 50+ `system_*` actions in registry but NOT in operator catalog: `system_{attach,detach,create,delete,list,get,update}_volume`, `system_{approve,cancel}_storage_migration`, `system_migrate_storage_component`, `system_{get,list}_storage_migration*`, `system_get_storage_recommendations`, `system_update_storage_recommendations`, `system_report_storage_migration_progress`, `system_test_nfs_export`, `system_{create,update,delete,get,list,propose}_architecture`, `system_module_mark_canary`, `system_recycle_pool`, `system_deploy_platform`, `system_platform_maintenance`, `system_platform_resilience`, `system_destroy_instance`, `system_refresh_instance_modules`, `system_get_provider`, `system_list_providers`, `system_update_provider`, all 5 `system_gitops_*`, all `system_*_ci_worker*`, `system_set_default_disk_image_publication`, `system_set_disk_image_retention`, `system_list_disk_image_publications`, `system_list_disk_image_webhooks`, `system_unassign_module_from_template`, `system_delete_template`, `system_delete_module`, `system_delete_node`. | Registry: 102 system_* (non-sdwan); doc: ~50 | ADD-NEW-CONTENT — extend catalog with storage, architecture, gitops, ci_worker, disk image management, provider, topology sections |
| HIGH | GAP | `extensions/system/docs/MCP_API_REFERENCE.md` | 17 `system_sdwan_*` actions in registry but missing: `system_sdwan_{accept,activate_host_bridge,compile_ovn_plan,create_host_bridge,create_ipfix_collector,create_ovn_acl,create_ovn_deployment,create_ovn_logical_switch,create_ovn_logical_switch_port,delete_ipfix_collector,delete_ovn_acl,delete_ovn_deployment,delete_ovn_logical_switch,list_host_bridges,list_ipfix_collectors,list_ovn_acls,release_host_bridge}_federation_peer`. | Registry: 69; doc: 52 | ADD-NEW-CONTENT — extend SDWAN catalog with OVN, IPFIX, host-bridge subsections |
| MED | STALE | `extensions/system/docs/MCP_API_REFERENCE.md:339-341` | "Backlog status" says "All 16 actions previously listed as Phase 1 runbook gaps... are now registered" — obsolete; replace with current backlog/aspirational pointer. | Memory `powernode.system_mcp_gaps` | UPDATE-IN-PLACE — pointer to current aspirational list |
| LOW | INCONSISTENCY | `extensions/system/CLAUDE.md:64` | "(~70 actions)" for `system_sdwan_*` — closer to truth (69) than MCP_API_REFERENCE.md (52). Minor. | Registry: 69 | (no action — "~70" acceptable) |
| HIGH | INACCURACY | `extensions/system/docs/history/TASKS.md:28` | Archived doc says "36 .go files / ~4400 LOC / 8 packages" for M2 — current 23 packages. Doc is archived; historical accuracy of M2 snapshot is defensible. | Archived (line 3-7 banner) | (no action — archived) |
| LOW | INACCURACY | `extensions/system/docs/history/TASKS.md:14` | "Last updated: 2026-05-04" but archive banner says 2026-05-17. Internal inconsistency in archived doc. | Archive banner | (no action — archived) |
| MED | INACCURACY | `extensions/system/docs/tutorials/INDEX.md:65` | "14 NodeInstance scenarios" — CLAUDE.md:76 says "10 NodeInstance container use cases"; README.md:133 says "10". Three docs cite (10, 10, 14). | Cross-doc | NEEDS-DECISION — pick one (likely 10) |
| MED | INACCURACY | `extensions/system/docs/tutorials/README.md:48` | "16 seeded scripts" — should be 18. | catalog | UPDATE-IN-PLACE — "18" |
| MED | INACCURACY | `extensions/system/docs/runbooks/README.md` | (verified) Index lists all 15 runbooks. No issue. | `ls docs/runbooks/*.md` = 15 + README | (no action) |
| MED | STALE | `extensions/system/docs/SMOKE_TEST.md:655` | "(forthcoming `docs/runbooks/acme-issuance.md`)" — file exists. | `docs/runbooks/acme-issuance.md` exists | UPDATE-IN-PLACE — remove "forthcoming" |
| LOW | INACCURACY | `extensions/system/initramfs/README.md:240` | "Build script: `build.sh` (12K — start here when adding new variants)" — verify size. | `wc -c` | (no action — non-critical) |
| LOW | INCONSISTENCY | `extensions/system/initramfs/README.md:60` | Cites two paths for same workflow file. Confusing phrasing. | n/a | UPDATE-IN-PLACE — clarify location |
| MED | INACCURACY | `extensions/system/CONTRIBUTING.md:32` | Suggests `git checkout master` for dev — extension follows `develop` → `master`. Line 38 dual-meaning. | Memory `project_system_extension_branching.md` | UPDATE-IN-PLACE — recommend `develop` |
| LOW | INCONSISTENCY | `extensions/system/CONTRIBUTING.md:213-215` | `cd server && bundle exec rails system:skills:generate_catalog` — task lives in PARENT platform at `server/lib/tasks/system_skills_catalog.rake`. From extension root the `cd server` would fail. | `server/lib/tasks/` (parent) — extension has no `server/lib/tasks/` | UPDATE-IN-PLACE — clarify "from parent platform's server dir" |
| LOW | STALE | `extensions/system/CLAUDE.md:65` | "(gitignored at `docs/platform/MCP_TOOL_CATALOG.md`)" — `docs/platform/` is parent's directory, not extension's. Correct only from parent root. | Path is parent-relative | UPDATE-IN-PLACE — add "(parent platform tree)" qualifier |
| LOW | INACCURACY | `extensions/system/SECURITY.md` | Current and matches typical disclosure policy. | — | (no action) |
| LOW | INACCURACY | `extensions/system/CODE_OF_CONDUCT.md` | Standard Contributor Covenant 2.1. Current. | — | (no action) |
| LOW | INACCURACY | `extensions/system/docs/history/README.md:17` | Archive table row consistent with TASKS.md banner. | — | (no action) |
| MED | STALE | `extensions/system/docs/TODO_TAXONOMY.md:62-64` | "Out of scope — Go agent TODOs" — descriptive policy. Phase A didn't flag. | — | (no action) |
| LOW | INCONSISTENCY | `extensions/system/README.md:222` | "Code of Conduct: see [CODE_OF_CONDUCT.md]" — link valid. | — | (no action) |
| MED | GAP | `extensions/system/docs/SMOKE_TEST.md` | No "Pass 8" section despite catalog rows on lines 78-79 (`smoke_test_bare_metal_claim.rb` Pass 8 + `smoke_test_disk_image_build_to_publication.rb` Pass 8). Document jumps from Pass 7 (line 327) straight to "Observability" (line 347). | Catalog cites "Pass 8" but no `## Pass 8` heading | ADD-NEW-CONTENT — add `## Pass 8 — Hardware / CI extras` |

---

## 3. Cross-doc inconsistencies (collated)

The single most leveraged fix-cluster: 19 INCONSISTENCY findings spanning 4 themes.

### 3.1 Agent count

- **CLAUDE.md:23-37** says **7 agents** ✓ (authoritative)
- **Concierge `system_prompt`:91-110** says **4 agents** ✗ (stale)
- Various runbooks reference "Fleet Autonomy" for CVE policy (real owner: CVE Responder since 2026-05-10)
- Action: regenerate Concierge `system_prompt`; update CVE-related references in cve-response.md + tutorial 07

### 3.2 Sensor count (12 vs 18)

- **FLEET_SENSORS.md:3** says "12 concrete sensors" ✗
- **ARCHITECTURE.md:216** says "Six sensors" (then lists 8) ✗
- **README.md:52** says "12 fleet sensors" ✗
- **README.md:136** says "All 12 fleet sensors" ✗
- **README.md:282** says "8 sensors" (M7 summary) ✗
- **tutorials/09-honeypot-canary.md:278** says "11 other sensors" ✗
- **CLAUDE.md Related Docs** says "12 sensor reference" ✗
- Actual: **18 on disk + base; 16 registered in `SENSORS` array.**
- Action: pick canonical phrasing ("18 fleet sensors (16 registered for live tick)") and propagate to all 6 cites.

### 3.3 SDWAN intervention policies (28 vs 31)

- **SDWAN_MANAGER_AGENT.md:30** says 28 ✗
- **CLAUDE.md:38** says 28 ✗
- **db/seeds/system_sdwan_manager_agent.rb:83-134** has **31** ✓
- Action: update both docs to 31.

### 3.4 Concierge skill bindings (4 vs 7)

- **CLAUDE.md:30** says "4 read-shape skills" ✗
- **Concierge `system_prompt`** says "4" ✗
- **db/seeds/system_concierge_agent.rb:206-214** binds **7** ✓
- Action: update CLAUDE.md + Concierge prompt to 7.

### 3.5 Smoke seed count (16 vs 18) / passes (7 vs 8)

- **SMOKE_TEST.md:5** says "16 seeded smoke scripts" ✗
- **SMOKE_TEST.md:56** says "All 18 smoke seeds" ✓
- **SMOKE_TEST.md:60-79** catalog has 18 rows ✓
- **SMOKE_TEST.md:78-79** catalog has Pass 8 entries but body has no `## Pass 8` section ✗
- **CLAUDE.md:79** says "16 seeded scripts, 7 passes" ✗
- **README.md:184** says "16 seeded scripts across 7 passes" ✗
- **tutorials/README.md:48** says "16" ✗
- Actual: **18 seeds, 8 passes.**
- Action: update line 5; add Pass 8 section body; propagate to CLAUDE.md, README.md, tutorials/README.md.

### 3.6 SDWAN slice 9 / slice 11 status

- **sdwan-network-setup.md:3** + **:286-306** say slice 11 "in active sweep" / "operator-driven via SQL" ✗
- **MIGRATION_DEVELOPER_GUIDE.md:275-280** says multi-hop migration chains "P9 hypothetical" ✗
- **gitops.md:3** says auto-apply "partial" ✗
- **runbooks/gitops-reconciliation.md:62, 223-225** says drift sensor "(when shipped)" ✗
- **tutorials/10-gitops-fleet.md:62-66** marks drift sensor + ApplyService as "Partial" ✗
- Reality (per code + memory `project_sdwan_routing_state`): all of these are LIVE.
- Action: remove "in sweep" / "when shipped" / "Partial" badges.

### 3.7 Manifest schema shape

- **MODULE_MANIFEST_COMPLETE_SCHEMA.md** says FLAT keys ✓
- **runbooks/module-authoring.md:46-99** + **tutorials/02-first-module.md:93-121** show nested `identity:` ✗
- **runbooks/module-authoring.md** uses nested `file_spec: { include, exclude }` ✗
- Action: rewrite runbook + tutorial to match schema doc.

### 3.8 CNI choice (Phase O4)

- **CONTAINER_RUNTIMES.md** + **tutorials/04** + **tutorials/05** all call OVN/ovn-kubernetes "future" ✗
- Code (`KubernetesClusterProvisionerService`): `NETWORK_PROFILE_TO_CNI`, `resolve_bootstrap_cni_plugin!`, `CniProfileMismatchError` — Phase O4 fully shipped.
- Action: add CNI-choice section to CONTAINER_RUNTIMES; update tutorials 04 + 05.

### 3.9 ExternalPressureSensor vs TradingPressureSensor

- **FLEET_SENSORS.md:140-146** says "Source: `external_pressure_sensor.rb` (historically `trading_pressure_sensor.rb`)" ✗
- **ARCHITECTURE.md:224** says `ExternalPressureSensor` ✗
- Actual: file is `trading_pressure_sensor.rb`, class is `TradingPressureSensor`.
- **NEEDS-DECISION**: rename in docs (cheap) OR actually rename file/class (matches the cross-domain pressure exchange's broader naming).

### 3.10 Use case count (10 vs 14)

- **CLAUDE.md:76** says "10 NodeInstance container use cases" ✓
- **README.md:133** says "10 NodeInstance container scenarios" ✓
- **tutorials/INDEX.md:65** says "14 NodeInstance scenarios" ✗
- Action: update tutorials/INDEX.md to 10 (or verify USE_CASE_MATRIX.md count).

---

## 4. Comprehensiveness gaps (collated)

22 GAP findings — features that exist in code but have no doc coverage. Highest-impact first.

### 4.1 New skill executors (26 of 40 not covered in SKILL_EXECUTORS.md)

`platform_deploy`, `platform_maintenance`, `platform_resilience`, `configure_sdwan_for_project`, `provision_full_stack`, `scale_project`, `relocate_workload`, `attach_storage`, `deploy_app_code`, `federation_manager`, `architecture_{create,update,delete,propose}`, `sdwan_host_bridge_compose`, `sdwan_ovn_compose_topology`, `sdwan_ovn_apply_acl`, `sdwan_ipfix_collector_compose`, `sdwan_compose_full_topology`, `discover_packages_by_intent`, `list_package_repositories_summary`, `suggest_architectures_for_fleet`, `package_module_create`, `package_module_refresh`, `package_repository_sync`, `cve_remediation_orchestration`.

### 4.2 Six fleet sensors not in FLEET_SENSORS.md

`instance_state_drift_sensor`, `gitops_drift_sensor`, `package_drift_sensor`, `project_slo_sensor`, `sdwan_credential_expiry_sensor`, `storage_assignment_drift_sensor`.

### 4.3 MCP_API_REFERENCE.md missing ~67 actions

50+ `system_*` (storage, architecture, GitOps, CI workers, disk image mgmt, provider, topology) + 17 `system_sdwan_*` (OVN, IPFIX, host-bridge, federation accept). See Agent 5 findings for exhaustive list.

### 4.4 Phase O4 CNI feature undocumented

`cni_plugin` parameter, `network_profile`-based CNI auto-selection (heavyweight → ovn_kubernetes, lightweight → flannel), `CniProfileMismatchError` — absent from CONTAINER_RUNTIMES.md, tutorials/04, tutorials/05.

### 4.5 System Topology Designer agent under-documented

Mentioned in CLAUDE.md but no dedicated doc; 5 compose skills absent from SKILL_EXECUTORS.md (covered above); Concierge → Topology Designer delegation absent from USE_CASE_MATRIX.md.

### 4.6 Child-platform spawn runbook missing

`platform_deploy` skill is the entry point for Decentralized Federation child-platform spawn. No runbook covers operator workflow (token TTL, propose-vs-spawn distinction, acceptance).

### 4.7 SMOKE_TEST.md Pass 8 body missing

Catalog cites two Pass 8 entries (`smoke_test_bare_metal_claim.rb`, `smoke_test_disk_image_build_to_publication.rb`) but no `## Pass 8` section exists in the body.

### 4.8 Go agent doc.go missing for 8 packages

`boot`, `fleetevent`, `fsutil`, `lifecycle`, `manifest`, `migration`, `storage`, `systemd` — 8 of 23 internal packages without package-level documentation.

### 4.9 SDWAN composition skills missing from SDWAN runbook

`sdwan_host_bridge_compose`, `sdwan_ovn_compose_topology`, `sdwan_ovn_apply_acl`, `sdwan_ipfix_collector_compose`, `sdwan_compose_full_topology` — none referenced in `runbooks/sdwan-network-setup.md`.

### 4.10 runtime_config endpoint undocumented

`GET /api/v1/system/node_api/runtime/:runtime/config` (slice 10 daemon overrides + Phase O4 K3s bootstrap_config) exists but not surfaced in main CONTAINER_RUNTIMES.md flow.

### 4.11 Trading↔Fleet cross-domain pressure undocumented

Per memory `project_cross_domain_coordination`: TradingPressureSensor + TradingAwareThrottle + Trading::FleetPressurePerceiver — referenced in ARCHITECTURE.md but absent from operator-facing docs.

---

## 5. Mechanical harness output (Phase A verbatim)

### 5.1 `check-links.sh` (exit=1)

- 4 broken internal links:
  - 3 in `vendored-binary-bump.md` → `.claude/plans/*` (those plans exist on auditor's local machine but not in the submodule)
  - 1 in `ARCHITECTURE.md:436` → `../../../docs/platform/MCP_TOOL_CATALOG.md` (gitignored in parent; intentional but un-rendered)
- Scanned: 59 files / 98 links · Broken: 4

### 5.2 `check-code-refs.sh` (exit=0)

Clean.

### 5.3 `check-mcp-actions.sh` (exit=1)

- Total unknown actions reported: 15
- All 15 are in `ASPIRATIONAL_MCP.md` catalog (expected)
- Novel unknowns (real findings): none

### 5.4 Authoritative counts (HEAD `67d9811`)

| Resource | Count | Source |
|---|---|---|
| Models (`system/`) | 74 | `find extensions/system/server/app/models/system -name '*.rb'` |
| Services (`system/`) | 228 | `find extensions/system/server/app/services/system -name '*.rb'` |
| Services (`sdwan/`) | 46 | `find extensions/system/server/app/services/sdwan -name '*.rb'` |
| Controllers | 135 | `find extensions/system/server/app/controllers/api/v1/system -name '*.rb'` |
| Migrations | 137 | `find extensions/system/server/db/migrate -name '*.rb'` |
| Fleet Sensors | 19 | `ls extensions/system/server/app/services/system/fleet/sensors/*.rb` (incl. `base_sensor.rb`) |
| Fleet Sensors (active) | 18 | excluding base |
| Fleet Sensors (registered) | 16 | `FleetAutonomyService::SENSORS` constant |
| Skill Executors | 40 | `ls extensions/system/server/app/services/system/ai/skills/*_executor.rb` |
| Agent Seeds | 7 | `ls extensions/system/server/db/seeds/*_agent.rb` |
| Go Packages | 23 | `ls -d extensions/system/agent/internal/*/` |
| Go `doc.go` files | 15 | `find extensions/system/agent/internal -name 'doc.go'` |
| Markdown doc files | ≥59 | harness scan |
| Smoke seeds | 18 | `ls extensions/system/server/db/seeds/smoke_test_*.rb` |

### 5.5 ASPIRATIONAL_MCP catalog status

- Catalog size: 15 entries
- Actions now in registry (catalog needs purge): **none**
- Novel unknown actions (in harness output but not in catalog): **none**
- Catalog is current. ✓

### 5.6 SMOKE_TEST.md cross-reference

- Doc-cited but missing on disk: `smoke_test_membership_credentials_vm.rb`
- On-disk but undocumented in main catalog: 0 (catalog now has 18 entries matching disk)
- Internal contradiction: line 5 says 16; lines 56 + 60-79 say 18

---

## 6. Suspected code bugs

Five code-level findings (distinct from doc drift). Per `feedback_audit_bug_fixes` memory, agents flagged these for user decision rather than auto-fixing because all require structural restructure or design choice.

### B1 — `PromotePublication` / `RollbackPublication` executors call non-existent methods (HIGH)

**Files:** `extensions/system/server/app/services/system/executors/disk_image/promote_publication.rb:11-16` + `rollback_publication.rb:10-16`

**Symptom:** Both autonomy executors call `pub.promote!` (no such AASM event on `DiskImagePublication`) and fall back to `pub.update!(active: true, promoted_at: Time.current)` (no such columns on the table — schema has `status, file_object_id, prior_file_object_id, retired_at, purged_at, verified_at, published_at`). Either branch raises. The seed policy `system.disk_image_publication_promote → require_approval` therefore cannot be executed; approving in UI calls this executor and crashes.

**Suggested fix** (controller's pattern at `disk_image_publications_controller.rb:99-115`):

```ruby
def perform
  pub = ::System::DiskImagePublication.find(params[:publication_id])
  raise "publication #{pub.id} not in 'published' state" unless pub.published?
  pub.node_platform.update!(
    disk_image_file_object_id: pub.file_object_id,
    disk_image_sha256: pub.sha256,
    disk_image_size_bytes: pub.size_bytes,
    disk_image_oci_ref: pub.oci_ref,
    disk_image_git_sha: pub.git_sha,
    disk_image_publication_status: "published",
    disk_image_publication_error: nil
  )
  { publication_id: pub.id, promoted: true }
end
```

**Status:** Awaiting user approval to land as a standalone commit.

### B2 — Disk Image Manager has 6 policies but only 4 executors (HIGH, NEEDS-DECISION)

Seed `system_disk_image_manager_agent.rb:70-77` registers 6 intervention policies; `executors/disk_image/` contains 4 files. Missing: `RevokeWebhook`, `RotateWebhookSecret`.

**Options:**
- (a) Implement two stub executors that call the existing webhook revoke / rotate-secret service calls.
- (b) Remove the two unimplemented policies from the seed and revise `DISK_IMAGE_MANAGER_AGENT.md` to flag them as aspirational.

### B3 — Disk Image Manager autonomy loop not wired (MED, NEEDS-DECISION)

`system_disk_image_manager_agent.rb` declares `interval_seconds: 300, scope: "disk_image"`, but `fleet/fleet_autonomy_service.rb` and `fleet/decision_engine.rb` have zero `disk_image` references. The agent has policies + approval chain + tick interval but no signal-perception loop. Docs claim an autonomous tick path that isn't wired.

**Options:**
- (a) Wire the agent into FleetAutonomyService (add scope handling + signal routing).
- (b) Update DISK_IMAGE_MANAGER_AGENT.md to flag the autonomy loop as aspirational.

### B4 — `runtime_docker_tls_rotate` policy has no executor (MED, NEEDS-DECISION)

`system_runtime_manager_agent.rb:114` lists `"system.runtime_docker_tls_rotate" => "auto_approve"` but no executor exists. The policy is unenforceable.

**Options:**
- (a) Implement `RuntimeDockerTlsRotate` executor.
- (b) Remove the policy from the seed.

### B5 — `ProvisionClusterExecutor.descriptor` missing `partial:` field (MED)

`app/services/system/ai/skills/provision_cluster_executor.rb`: `execute()` returns `partial: failures.any? && created.any?`, but `descriptor()` outputs schema omits this field. Auto-generated `SKILL_EXECUTOR_CATALOG.md` therefore omits a real output field.

**Suggested fix:** Add `partial: :boolean` to the descriptor's outputs hash, then re-run `bundle exec rails system:skills:generate_catalog` (from parent platform's `server/` dir). Small change, ~2 lines.

---

## 7. Recommended remediation phases (D1 / D2 / D3)

Three phases, each independently shippable. Per `feedback_phased_doc_audits` + `feedback_no_auto_commit`: implement → run `.verify/` harness → surface diff → wait for user approval per phase → commit inside submodule first, bump parent pointer separately.

### Phase D1 — Operator-misleading drift (HIGH, ~30 findings)

Items that would cause an operator to fail a real task. Land first.

- All HIGH findings in Agent 1's table: manifest schema fiction, AASM lifecycle drift, lifecycle_state/promotion_state, ARCHITECTURE.md fictional counts, node-provisioning route typo, `system_create_module_from_package` signature drift
- All HIGH findings in Agent 2's table: `bootstrap_disk_image_ci` / `provision_disk_image_webhook` / `system_set_disk_image_retention` parameter drift, fictional event names, fictional Worker→NodeInstance narrative, CNI/Phase O4 gaps (treat as urgent ADD-NEW-CONTENT)
- All HIGH findings in Agent 3's table: SDWAN slice 11 "in sweep" badges, Sdwan vs System FederationPeer namespace, tutorial 11 propose/spawn conflation, MIGRATION_DEVELOPER_GUIDE multi-hop stale
- All HIGH findings in Agent 4's table: CVE policy attributed to Fleet Autonomy (should be CVE Responder), Concierge system_prompt stale, FLEET_SENSORS.md sensor list (12→18 + 6 new sections)
- All HIGH findings in Agent 5's table: README.md count corrections, SMOKE_TEST.md count contradictions + missing Pass 8 section, MCP_API_REFERENCE.md count headers + missing 67 actions, Go agent subcommand count, 8 missing doc.go files

**Estimated scope:** ~30 file edits, ~5 new doc.go files (boot, fleetevent, fsutil, lifecycle, manifest, migration, storage, systemd — total 8), 1 new Pass 8 section in SMOKE_TEST.md.

**Verification at phase exit:** rerun all 3 `.verify/` scripts; spot-check 5 random fixes against code; cross-validate the Concierge system_prompt update by re-reading it cold.

### Phase D2 — Count drift + status badges (HIGH/MED, ~50 findings)

Land second — large volume, mostly mechanical.

- All remaining MED INACCURACY findings tied to counts (sensor counts in tutorials, policy counts in agent docs, MCP action counts in CLAUDE.md / README.md / MCP_API_REFERENCE.md)
- All STALE findings: "in active sweep" / "Phase X pending" / "when shipped" / "Partial" badges for shipped features (slice 9 routing, slice 11 acceptance, multi-hop migration chains, GitOps drift sensor + ApplyService, slice 10 daemon overrides)
- All BROKEN findings (vendored-binary-bump.md 3 broken links, ARCHITECTURE.md:436 broken link, smoke_test_membership_credentials_vm.rb missing — **needs decision: remove ref or create file**)
- Comprehensiveness ADD-NEW-CONTENT (subset): SDWAN composition skills subsection, runtime_config endpoint, System Topology Designer doc, USE_CASE_MATRIX Concierge delegation note

**Estimated scope:** ~50 file edits.

**Verification at phase exit:** rerun `.verify/`; verify all count claims against Phase A baseline; confirm no badge says "Partial" / "in sweep" for a shipped feature.

### Phase D3 — Cross-doc consistency + housekeeping (LOW/MED, ~60 findings)

Polish. Land last.

- All INCONSISTENCY findings (Section 3) where a canonical source must be picked: ExternalPressureSensor vs TradingPressureSensor (NEEDS-DECISION), use-case count 10 vs 14, sensor naming (snake vs PascalCase)
- All remaining LOW findings (typos, formatting, dead-wood paragraphs)
- ASPIRATIONAL_MCP.md backlog status replacement (point to current list rather than "All 16 are now registered")
- CONTRIBUTING.md `develop` recommendation
- All NEEDS-DECISION items presented for user direction (acme Go-vs-Ruby framing, `desired_state_validator` add to gitops.md, agent-peering.md status check)

**Estimated scope:** ~60 file edits.

**Verification at phase exit:** final `.verify/` rerun; comprehensiveness sanity check by re-reading README.md + CLAUDE.md cold and confirming every numeric claim matches Phase A baseline; archive the audit baseline counts in this report as the next-audit reference point.

### Code bug commits (separate from D phases)

Per `feedback_audit_bug_fixes`: bug fixes get **separate commits** from doc fixes.

- **Commit B1:** Fix `PromotePublication` + `RollbackPublication` executors (controller-pattern column flip).
- **Commit B5:** Add `partial: :boolean` to `ProvisionClusterExecutor.descriptor`; regenerate catalog.
- **B2, B3, B4:** NEEDS-DECISION — present options to user first.

---

## 8. Audit metadata

### Agent assignments

| Agent | Slice | Subagent type | Duration | Findings |
|---|---|---|---|---|
| 0 (Preflight) | Mechanical harness + count baseline | Explore | ~3 min | n/a (baseline only) |
| 1 | Node lifecycle + modules + skills | general-purpose | ~10 min | 28 |
| 2 | Container runtimes + disk image CI | general-purpose | ~6 min | 37 |
| 3 | SDWAN + federation + ACME + credentials | general-purpose | ~6 min | 28 |
| 4 | Fleet autonomy + sensors + agents + GitOps | general-purpose | ~4 min | 31 |
| 5 | Top-level + cross-cutting + Go agent + initramfs | general-purpose | ~4 min | 44 |
| Total | | | ~33 min wall-clock | **~168** |

(Phase B agents ran in parallel — wall-clock is bounded by the longest-running agent (Agent 1 at ~10 min), not the sum.)

### Tree state

- Submodule `extensions/system/` HEAD: `67d9811` (`test(controllers): operator CRUD specs for 17 more wave-1 controllers`)
- Parent platform HEAD: `9088779` (`chore(system): bump submodule for P0.1 wave 1 completion + storage bugfix`)
- Audit-input baseline: 59 markdown files in `docs/`; 5 top-level `.md` files; 23 Go internal packages.

### Verification (per Phase C criteria)

- ✓ Re-run `.verify/` harness independently — identical exit codes (links=1, code-refs=0, mcp-actions=1)
- ✓ Comprehensiveness sanity check — SDWAN slice 9 routing, CVE Responder, Disk Image Manager all surface findings as expected
- ✓ Cross-agent consistency — no contradictory severities on overlapping findings (Agent 1 + Agent 4 both flag "Six sensors" in ARCHITECTURE.md:216 at the same severity)
- Random spot-check: 5 findings re-verified against cited code — all accurate (one finding tightened from "13 fleet sensors" to "18 fleet sensors + 16 registered" for precision)

### Methodology limitations

- `SKILL_EXECUTOR_CATALOG.md` is auto-generated; only the regen-command + executor count were verified (40), not each per-executor block.
- `app/controllers/api/v1/system/nodes_controller.rb` action implementations were not exhaustively read — Agent 1 cannot certify every "Per-state error recovery" procedure in node-provisioning.md.
- Sidekiq cron schedules in worker `config/sidekiq.yml` were not cross-checked against doc-cited intervals (e.g., CVE feed "hourly" vs "every 6h" discrepancy).
- Phase A confirmed the 3 `.verify/` scripts exit cleanly; their false-negative rate is unknown (e.g., scripts only check `[text](path)` literal links, not reference-style links).

### Next-audit baseline

Save these numbers as the reference point for the next audit. If any drift again, that's a signal docs-update discipline slipped:

```
HEAD: 67d9811 (2026-05-19)
models: 74    services: 228+46    controllers: 135    migrations: 137
sensors: 18 (16 reg)   skills: 40   agents: 7   go-pkgs: 23 (15 with doc.go)
smoke: 18 seeds, 8 passes
mcp:  system_* 102   sdwan_* 69   k8s_* 5   docker_* 52 (total 228)
aspirational MCP catalog: 15 (current)
```
