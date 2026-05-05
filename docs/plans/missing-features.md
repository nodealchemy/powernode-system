# Missing Features Implementation Plan

**Context:** Gap remediation slices 1+2+3+5 (2026-05-04) shipped 18 of 24 MCP actions identified in `project_system_mcp_gaps` memory. The remaining **6 MCP actions are blocked on 3 underlying features** that aren't yet complete:

| Feature | Blocked MCP actions | Operator UX it unblocks |
|---|---|---|
| **GitOps reconciler completion** (M-D2-3, in active sweep) | 4 — `system_gitops_register_repository`, `system_gitops_sync_repository`, `system_gitops_get_sync_run`, `system_gitops_get_drift_report` | `runbooks/gitops.md` + Example 10 (gitops-fleet) end-to-end |
| **SDWAN federation acceptance** (slice 11, in active sweep) | 1 — `system_sdwan_accept_federation_peer` | Example 09 (multi-region-federation) end-to-end |
| **Vault credential restoration** (CredentialRestorationService) | 1 — `system_rotate_vault_transit_pepper` | `runbooks/vault-credential-restoration.md` Phase 5 (key rotation) |

This plan covers what's needed to ship each feature. Investigation (2026-05-04) revealed each has substantial scaffolding already — the remaining work is targeted glue logic, not foundational subsystems.

**Audience:** engineers picking up implementation; project lead estimating effort; reviewers gating Vault DR for security sign-off.

---

## Feature 1 — GitOps reconciler completion

### Current state (existing code)

Already shipped:

| Component | Path | Function |
|---|---|---|
| `GitopsRepository` model | `app/models/system/gitops_repository.rb` | git remote + branch tracking; `STATUSES = pending\|success\|failed\|partial` |
| `GitopsSyncRun` model | `app/models/system/gitops_sync_run.rb` | per-sync record with `diff_count`, `proposal_ids`, status |
| `DesiredStateParser` | `app/services/system/gitops/desired_state_parser.rb` | parses `fleet.yaml` into typed hashes |
| `DiffEngine.diff!` | `app/services/system/gitops/diff_engine.rb` | compares desired vs live (templates, modules, assignments, provider configs) |
| `Reconciler.reconcile!` | `app/services/system/gitops/reconciler.rb` | walks the diff; **opens a `Proposal` per change** rather than auto-applying |
| `RepoSyncService` | `app/services/system/gitops/repo_sync_service.rb` | git fetch + clone management |
| `GitopsRepositoriesController` | `app/controllers/api/v1/system/gitops_repositories_controller.rb` | operator CRUD |
| `worker_api/GitopsController` | `app/controllers/api/v1/system/worker_api/gitops_controller.rb` | sync trigger from worker |
| Specs | `spec/services/system/gitops/` | exists |

### What's missing

**Critical insight:** the reconciler already runs end-to-end and opens proposals. The 4 MCP actions can be implemented today against existing code — they don't need to wait for any foundational work. The actual M-D2-3 polish work is *separate from the MCP surface*.

Genuinely missing:

1. **Proposal-apply path** — converting an *approved* `Proposal` row into actual DB changes (creating Templates, Modules, Assignments per the desired state in the proposal payload). The reconciler creates proposals; nothing yet *applies* them post-approval.
2. **Drift sensor** — periodic comparison of git desired-state vs DB reality, emitting `gitops.drift_detected` FleetEvents when they diverge.
3. **Operator UI for diff review** — list of pending GitopsSyncRun proposals + per-proposal accept/reject + apply progress. The `Ai::ApprovalRequest` UI already exists for approval queue rendering, but needs a GitOps-specific drill-in panel.
4. **End-to-end smoke test seed** mirroring `smoke_test_docker_runtime.rb` — `smoke_test_gitops_reconciler.rb`.

### Scope by phase

#### Phase 6a — MCP action surface (read + trigger)

Implementable today against the existing reconciler. Lowest-risk slice.

| Action | Backing |
|---|---|
| `system_gitops_register_repository` | `GitopsRepository.create!` with name, repo_url, branch, ssh_credential_id |
| `system_gitops_sync_repository` | dispatch to `Reconciler.reconcile!(repository:, sync_run:)` (already exists) |
| `system_gitops_get_sync_run` | fetch `GitopsSyncRun` by id; serialize diff_summary, proposal_ids, status |
| `system_gitops_get_drift_report` | run `DiffEngine.diff!(account:, desired_state: parser.parse(repository))` without opening proposals; return diff summary |

Plus: 4 ACTION_PERMISSIONS entries, 4 action_definitions entries, 4 case dispatches, 4 specs, 4 registry entries.

**Estimated effort:** ~2 days (1 engineer, including specs + parent registry update + submodule pointer bump).

#### Phase 6b — Apply path

The hard work. Need a new service:

```
System::Gitops::ApplyService
  .apply!(proposal:, sync_run:)
    → walks proposal.payload.changes
    → for each change: create/update/delete the target row
    → atomic transaction with rollback on partial failure
    → records actions taken on sync_run.applied_actions
    → marks proposal.status = "applied" or "failed"
```

Plus a worker job (`SystemGitopsApplyJob`) that picks up approved proposals and dispatches to ApplyService. The existing `Ai::InterventionPolicy` infra handles the gating; the worker just needs to consume "approved" proposals.

Conflicts: what if reality changed between proposal-creation and apply-time (operator manually edited via standard MCP)? Two strategies:

- **Refuse-on-conflict** (recommended): re-diff at apply time; if any change in the proposal would override post-proposal manual edits, mark proposal `stale` and require re-sync.
- **Force-apply** (fallback): respect the proposal as-written; manual edits get overwritten. Operator opt-in.

**Estimated effort:** ~3-5 days. Stretches to 5 if conflict semantics need cross-team buy-in.

#### Phase 6c — Drift sensor + UI + smoke

| Sub-task | Effort |
|---|---|
| `GitopsDriftSensor` (60s tick, runs DiffEngine, emits FleetEvent) | 1-2 days |
| Frontend GitOps dashboard panel (sync run list + diff view + apply approval) | 2-3 days |
| `smoke_test_gitops_reconciler.rb` end-to-end seed | 1 day |
| Update `gitops.md` runbook + Example 10 from "markdown only — gated" → "shipped" | <1 day |

**Estimated effort:** ~5 days total.

### GitOps total

~10 days for full GitOps. Phase 6a alone (~2 days) unblocks the 4 MCP actions and the runbook narrative; Phase 6b is the real apply semantics; Phase 6c is polish.

---

## Feature 2 — SDWAN federation acceptance (slice 11)

### Current state

Already shipped:

| Component | Path | Function |
|---|---|---|
| `Sdwan::FederationPeer` model | `app/models/sdwan/federation_peer.rb` | full state machine: `STATUSES = proposed\|accepted\|active\|suspended\|revoked` |
| Transition matrix | same | `proposed → accepted/revoked`, `accepted → suspended/revoked`, etc. |
| `Sdwan::FederationGovernance` | `app/services/sdwan/federation_governance.rb` | scanner with findings: `proposed_long_unanswered`, `stale_accepted_without_handshake`, `cross_ca_handshake_pending`, etc. |
| `revoke!(reason:)` method | model | sets status=revoked, persists |
| 5 MCP actions | system_sdwan_propose_federation_peer + list/get/revoke/scan | shipped |
| Frontend | unknown — needs check | — |

### What's missing

1. **`accept!` model method + MCP action surface** (`system_sdwan_accept_federation_peer`) — at minimum, transitions `proposed → accepted` + sets `signed_at`. Implementable today for **same-account drill mode**.
2. **Cross-account auth handshake** — Account B needs to verify that Account A actually proposed this peering (vs. an attacker forging a proposal). Options:
   - **Option I (cheapest)**: pre-shared bootstrap secret. Account A generates a proposal token; operator copies it out-of-band to Account B; B's accept call requires the matching token. Works for trust-on-first-use.
   - **Option II (medium)**: each account has a public signing key. Proposal is signed by A's key; B verifies via known-pubkey list (manually pre-loaded by operator). Equivalent to TOFU after one-time pubkey share.
   - **Option III (heaviest)**: SPIFFE-style external attestation server. Both accounts trust the same root.
3. **Cross-CA bridging** — once accepted, peers across accounts need certs validatable by both CAs. The `cross_ca_handshake_pending` finding in `FederationGovernance` suggests this protocol is envisioned but not yet implemented:
   - **Option a**: each account's CA cross-signs the other's intermediate. Manual operator workflow.
   - **Option b**: a federation-level CA chained to both account CAs.
   - **Option c**: SPIFFE federation trust bundle exchange.
4. **Acceptance UI** in SDWAN frontend — list of incoming proposals on each Account; accept/reject buttons + token-paste field for Option I.
5. **Slice 11 smoke test seed**.

### Scope by phase

#### Phase 11a — MCP action + same-account drill (~2 days)

Implement `system_sdwan_accept_federation_peer`:
- Looks up the FederationPeer by id
- Verifies `status == "proposed"`
- Transitions to `accepted`; sets `signed_at = Time.current`, `accepted_by_user_id = @user.id`
- Returns the peer

This **does NOT solve cross-account auth** but unblocks Example 09's drill narrative + lets operators dogfood the flow with single-account testing.

Permission: `system.sdwan.federation.accept` (new — needs migration).

#### Phase 11b — Cross-account auth handshake (~5-7 days)

Recommend **Option I** (pre-shared bootstrap secret) for v1:

1. Migration: add `acceptance_token_digest` (string, indexed) + `acceptance_token_expires_at` (datetime) to `sdwan_federation_peers`.
2. `FederationProposalService.propose!`:
   - generates 32-byte token; SHA-256 hash stored in `acceptance_token_digest`
   - returns plaintext token to Account A operator (one-time-shown, like CI worker tokens)
3. Operator A copies token out-of-band → Account B operator pastes into UI
4. Account B's `accept!` verifies the token hash matches; bumps to `accepted` if so
5. Audit log every step

This avoids the design overhead of Options II/III while still being reasonably secure (token is high-entropy + time-bounded).

#### Phase 11c — Cross-CA bridging (~5-7 days)

Recommend **Option a** (cross-signing) for v1:

1. On `accept!`, both accounts' `InternalCaService` exchange intermediate cert chains via the platform-to-platform federation channel
2. Each side cross-signs the other's intermediate; result stored in a `cross_signed_chain` JSONB column on the FederationPeer row
3. Peer cert issuance (subsequent peer joins on either side) automatically includes the cross-signed chain
4. Verification: `transport.Mtls` accepts certs validatable against either local CA OR the cross-signed chain

This requires careful key management but uses existing primitives.

#### Phase 11d — Frontend UI + smoke (~3-5 days)

| Sub-task | Effort |
|---|---|
| Federation peers panel on `/app/system/sdwan/federation` (lists proposed/accepted/etc.) | 1-2 days |
| Token-paste accept dialog + revoke confirmation | 1 day |
| `smoke_test_federation_acceptance.rb` end-to-end seed | 1 day |
| Update Example 09 + sdwan-network-setup.md runbook (Phase 9) | <1 day |

### Federation total

~13-19 days for full federation. Phase 11a alone (~2 days) unblocks the MCP action for drill mode; cross-account auth + cert bridging are the substantial work.

---

## Feature 3 — Vault credential restoration

### Current state

Substantial scaffolding already exists in the **parent platform** (NOT the extension):

| Component | Path | Function |
|---|---|---|
| `Security::VaultTransitClient` | `server/app/services/security/vault_transit_client.rb` | `encrypt`, `decrypt`, **`rotate_key`**, `key_metadata` |
| `Security::VaultCredentialProvider` | `server/app/services/security/vault_credential_provider.rb` | `get/store/delete/rotate_credential` per-account |
| `VaultCredential` concern | `server/app/models/concerns/vault_credential.rb` | mixed into Ai::Provider, Devops::DockerHost, etc. |
| Vault transit spec | `server/spec/services/security/vault_transit_client_spec.rb` | exists |

### What's missing

The transit-engine primitive exists. What's missing is the **orchestration**:

1. **Account-level transit_key_version tracking** — column doesn't exist on the Account model yet. Without this, the platform can't tell which Accounts are using the latest pepper version vs. older versions.
2. **CredentialRestorationService** — the orchestrator that walks all Accounts, decrypts with old pepper version, re-encrypts with new pepper version, atomically swaps, updates `transit_key_version`.
3. **Worker job** for online re-encryption (millions of credentials per Account in production scenarios).
4. **MCP action `system_rotate_vault_transit_pepper`** wrapping the service.
5. **Audit logging integration** — every key operation must log to the existing audit infrastructure (`Trading::AuditLog` table per the runbook).
6. **External security review** — cryptographic key-rotation logic requires sign-off from a security-reviewer outside Claude Code.

### Scope by phase

#### Phase Vault DR-1 — Migration + tracking (~1-2 days)

1. Migration: add `transit_key_version` (string, default current pepper version) + `transit_key_rotated_at` (datetime, nullable) to `accounts`.
2. Backfill existing rows with the current pepper version (read from `VaultTransitClient.key_metadata`).
3. Add scope: `Account.needing_pepper_rotation(latest_version)`.

#### Phase Vault DR-2 — CredentialRestorationService (~3-5 days)

```ruby
module Security
  class CredentialRestorationService
    def self.rotate_transit_pepper!(scheme: "v2", reencrypt_existing: true)
      latest = bump_pepper!  # calls VaultTransitClient.rotate_key
      stats = { rotated: 0, skipped: 0, failed: 0 }

      Account.needing_pepper_rotation(latest).find_each do |account|
        begin
          rotate_account!(account, latest)
          stats[:rotated] += 1
        rescue => e
          Rails.logger.error("[Pepper rotation] account=#{account.id} #{e.message}")
          stats[:failed] += 1
        end
      end

      stats
    end

    private

    def self.rotate_account!(account, latest)
      provider = VaultCredentialProvider.new(account_id: account.id)
      account.transaction do
        # walk all credentials with this account's namespace
        # decrypt with old pepper version, re-encrypt with new
        # atomic swap on success
        provider.rewrap_all_credentials!
        account.update!(transit_key_version: latest, transit_key_rotated_at: Time.current)
      end
    end
  end
end
```

Extend `VaultCredentialProvider` with `rewrap_all_credentials!` method (walks namespace, decrypts/re-encrypts each).

Worker job `SystemVaultPepperRotationJob` for batched async execution.

Audit log: every `bump_pepper!`, every `rotate_account!`, every credential rewrap → `Trading::AuditLog` (or whatever the platform's audit table is — likely needs a security-extension audit table to exist).

#### Phase Vault DR-3 — MCP action + DR runbook live verification (~1-2 days)

`system_rotate_vault_transit_pepper` MCP action:
- Permission: `system.fleet.autonomy` (highest tier; ops + security joint approval)
- Wraps `Security::CredentialRestorationService.rotate_transit_pepper!`
- Returns rotated_count, status, task_id

Live verification: run against a test Vault cluster + verify all accounts decrypt cleanly post-rotation. This is the **DR runbook's `Phase 5 — Key rotation`** section made executable.

#### Phase Vault DR-4 — External security review (indeterminate)

**Cannot be skipped.** Cryptographic key-rotation logic is too high-stakes for self-review.

Required reviews:
- Atomicity guarantees (what if rotation crashes mid-account?)
- Old-pepper-version retention (Vault's transit `min_decryption_version` setting)
- Audit trail completeness
- Operator runbook accuracy (does executing the runbook actually work?)

Recommended: pair with a security-team reviewer **before** implementation, not after. Design review first; implementation second.

### Vault DR total

~5-7 days of engineering work + indeterminate security review time. Phase Vault DR-4 is the critical path.

---

## Cross-cutting concerns

1. **Approval gating**: Each new MCP action needs an `Ai::InterventionPolicy` entry seeded in `fleet_autonomy_agent.rb` or `system_runtime_manager_agent.rb`. Vault DR + GitOps apply should be `require_approval`; reads can be `auto_approve`.

2. **Specs first**: Each phase ships with request specs + service specs **before** the production code path is wired. Pattern from gap-remediation slices 1+2+3+5: write the spec, watch it fail, implement, watch it pass.

3. **Audit logging**: Vault DR especially. Every `bump_pepper!`, every `rotate_account!`, every credential rewrap logs via the existing audit infrastructure. If `Trading::AuditLog` is the wrong target, a `Security::AuditLog` table may need to exist first.

4. **Documentation update**: After each feature ships:
   - Update the corresponding operator runbook (mark gated → shipped)
   - Update Example 09/10/Vault to remove "(gated)" markers + add live MCP calls
   - Mark backlog items as ✅ shipped in `project_system_mcp_gaps` memory
   - Reinforce the relevant compound learnings via `platform.reinforce_learning`

5. **Frontend coverage**: GitOps + Federation both have meaningful UI work. The `extensions/system/frontend/` jest infrastructure is in place (per memory `project_extension_jest_infra`). New components should ship with component tests.

6. **Cross-references**: When updating runbooks, fix the dangling forward references introduced by the markdown-only Examples 09 + 10 (they currently say "in active sweep" — flip to "shipped 2026-XX-YY").

---

## Recommended execution order

By risk + leverage + sequencing:

| # | Slice | Effort | Why this order |
|---|---|---|---|
| 1 | **GitOps Phase 6a** (MCP surface) | ~2 days | Lowest risk, immediate operator UX win for `gitops.md` runbook |
| 2 | **Federation Phase 11a** (accept action, drill mode) | ~2 days | Same — unlocks Example 09 narrative for drill-mode demos |
| 3 | **Vault DR Phase 1 + design review** | 1-2 days code + indeterminate review | Start security review **early** so it doesn't gate the whole feature |
| 4 | **GitOps Phase 6b** (apply path) | ~3-5 days | Real GitOps semantics; foundation for production fleet management |
| 5 | **Vault DR Phase 2 + 3** (after security sign-off) | ~3-5 days | Critical infra; must wait for review |
| 6 | **GitOps Phase 6c** (drift sensor + UI + smoke) | ~5 days | Polish; feature complete |
| 7 | **Federation Phase 11b** (cross-account auth) | ~5-7 days | Substantial design work for production federation |
| 8 | **Federation Phase 11c** (cross-CA bridging) | ~5-7 days | Heaviest design lift; can be deferred if drill mode is acceptable for v1 |
| 9 | **Federation Phase 11d** (frontend UI + smoke) | ~3-5 days | Polish |

**Total: ~30-44 days of engineering work.** Phases 1+2+3 (the unlock-the-MCP-actions slice) can ship in **~5 days** combined and would close the operator-UX gap on all three runbooks for drill scenarios.

Could be parallelized across multiple engineers — GitOps + Federation + Vault DR are independent.

---

## Risk register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Cross-account auth design takes longer than estimated | Medium | Medium | Ship same-account drill mode first (Phase 11a); design + build cross-account as separate slice |
| Vault DR cryptographic review fails | Low-Medium | High | Pair with security team **before** implementation; design review first |
| GitOps apply path conflicts with manual operator changes | Medium | Medium | Refuse-on-conflict semantics by default; document operator workflow + add detection |
| Federation handshake state machine interleaves with revocation | Medium | Low | Lock proposals during acceptance via DB row lock; idempotent transitions already in model |
| Frontend coverage is thin (audit-flagged) | High | Low | Ship backend + MCP first; frontend is operator-visible polish that can lag |
| Drift sensor produces noisy alerts | Medium | Low | Tune thresholds; allow operator to suppress drift on specific resources via metadata |
| `Trading::AuditLog` is the wrong audit target for security events | Medium | Medium | If true, create `Security::AuditLog` table first; fork the audit work as a small precursor migration |

---

## What this plan does NOT include

- **Frontend test coverage expansion** (audit-flagged in Phase 1; 6 tests for 175 components). Separate slice of work.
- **Real-hardware verification** of initramfs (per `project_smoke_test_state` memory; blocked on hardware).
- **Slice 12+** (post-federation). Out of scope.
- **Auto-regenerated MCP_API_REFERENCE.md** via Rake task. Mentioned in plan-1 as future work; remains future.
- **Drift detection across non-fleet resources** (e.g., billing config in git). Out of scope.

---

## Verification per feature

| Feature | Verification commands |
|---|---|
| **GitOps Phase 6a** | `bundle exec rspec spec/services/ai/tools/system_fleet_tool_spec.rb -e gitops`; smoke test seed run; `platform.system_gitops_register_repository` end-to-end via MCP |
| **GitOps Phase 6b** | Apply service spec coverage; integration test from "git commit → reconciler tick → proposal opened → operator approves → ApplyService runs → DB state matches desired" |
| **GitOps Phase 6c** | Drift sensor unit + integration; UI Cypress / Jest tests; `smoke_test_gitops_reconciler.rb` runs to completion |
| **Federation Phase 11a** | Drill mode: propose → accept → verify peer status=accepted with signed_at populated |
| **Federation Phase 11b** | Token round-trip: propose with token → operator copies → accept with token → verifies hash; replay attack rejected |
| **Federation Phase 11c** | Cross-CA: peer in Account A presents cert to Account B; mTLS handshake succeeds via cross-signed chain |
| **Vault DR Phases 1-3** | Run on a test Vault: bump pepper → walk N accounts → verify all accounts decrypt cleanly post-rotation; audit log shows every step |
| **Vault DR Phase 4** | External security review documented sign-off |

---

## Memory updates after completion

When a feature ships:

1. Update `project_system_mcp_gaps`:
   - Mark each formerly-gated action as ✅ shipped
   - Update progress section
   - Move from "Remaining 6 (gated)" to shipped list

2. Reinforce relevant learnings:
   - `platform.reinforce_learning` on the GitOps / Federation / Vault learnings if used
   - `platform.create_learning` for any non-obvious finding from implementation (e.g., "Vault transit `min_decryption_version` must be set BEFORE rotating to avoid breaking decryption of in-flight blobs")

3. Update `project_credential_pattern` memory after Vault DR — it currently mentions CredentialRestorationService as a future capability; flip to shipped.

4. Update `project_sdwan_routing_state` memory after Federation — it currently calls slice 11 "in sweep"; flip to shipped or update to next slice.

---

## Why this plan is structured the way it is

- **Start with the smallest slice that unblocks something visible.** Phase 6a + 11a + Vault DR-1 ship together in ~5 days and close the operator-UX gap on three runbooks.
- **Defer gnarly design until after the easy wins.** Cross-account auth + cryptographic review are real engineering investments; deferring them to phase 2+ of each feature keeps momentum visible.
- **Specs first.** Per the gap-remediation pattern that consistently surfaced latent bugs (Worker#revoke! undefined; version_string vs version_number; CVE regex; Status enum mismatches): write specs against the actual schema *before* writing code. Specs are the cheapest form of source-of-truth verification.
- **Cryptographic safety is non-negotiable.** Vault DR Phase 4 (security review) is the critical path. No partial implementations that could mislead operators about key state.
