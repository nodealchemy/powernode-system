# GitOps Reconciliation

> Status: active

The full read + write path is shipped: the `gitops_drift_sensor` runs each fleet
tick, `RepoSyncService` + `DesiredStateParser` + `DiffEngine` produce diffs, and
every diff opens an `Ai::AgentProposal`. By default proposals wait for operator
review. When `repository.auto_apply` is set, the reconciler auto-approves +
applies **non-destructive** (create / update) diffs without operator review —
gated by the platform kill-switch and the per-tick cap, with the audit proposal
always created first (see "Auto-apply mode"). One conservative carve-out remains
(see "Known limitations"): `ApplyService` template/module **destroy** raises
`UnsupportedDiffError`, and destroys NEVER auto-apply (they always stay
`pending_review` for manual approval — even assignment destroys, which
`ApplyService` would otherwise allow on operator approval). Implementation lives
in `extensions/system/server/app/services/system/gitops/` (6 services:
`apply_service.rb`, `desired_state_parser.rb`, `desired_state_validator.rb`,
`diff_engine.rb`, `reconciler.rb`, `repo_sync_service.rb`).

This document describes the GitOps reconciler — the system that lets
operators declare desired fleet state in a git repository and continuously
reconciles it against live state via `Ai::AgentProposal` rows.

---

## TL;DR

```yaml
# fleet.yaml at the root of your repo
templates:
  web-server:
    name: web-server
    description: Standard nginx node
    node_platform_id: <platform-uuid>

modules:
  nginx-public:
    name: nginx-public
    priority: 50
    variety: config
    config:
      nginx_workers: 4

assignments:
  app-01:nginx-public:
    enabled: true
    priority: 50
  app-02:nginx-public:
    enabled: true
    priority: 50
  app-03:nginx-public:
    enabled: false   # disabled on app-03 without detaching
```

Push the file. The reconciler ticks every 5 minutes; diffs against live
state become `Ai::AgentProposal` rows for operator review.

---

## Architecture

```mermaid
flowchart TD
    Cron[SystemGitopsSyncJob<br/>cron */5 * * * *]
    Endpoint[POST /api/v1/system/worker_api/<br/>gitops/reconcile]
    Loop[Iterate GitopsRepository<br/>.due_for_sync]
    Recon[Reconciler.reconcile!<br/>repository: repo]
    Sync[RepoSyncService.sync!<br/>clones/pulls into<br/>tmp/gitops/&lt;account&gt;/&lt;repo&gt;/]
    Parse[DesiredStateParser.parse!<br/>fleet.yaml → DesiredState]
    Diff[DiffEngine.diff!<br/>parsed vs live DB rows]
    Prop[For each diff:<br/>Ai::AgentProposal]
    Run[(GitopsSyncRun<br/>status: success/failed/partial)]

    Cron --> Endpoint --> Loop --> Recon
    Recon --> Sync --> Parse --> Diff --> Prop
    Prop --> Run
    Recon -.records.-> Run
```

## Proposal Flow (with auto-apply branch)

The audit proposal is **always** created first (so every change has a record),
then the reconciler branches on `repository.auto_apply`. Auto-apply applies a
proposal only when it passes all four safety gates (see "Auto-apply mode"); a
destroy, a halted account, or `auto_apply: false` all route the proposal to the
operator review queue instead.

```mermaid
flowchart TD
    Diff[DiffEngine output] --> Cap{per-tick<br/>proposal cap?<br/>default 25}
    Cap -->|under cap| OpenAll[Open all as<br/>Ai::AgentProposal]
    Cap -->|over cap| OpenSome[Open first 25,<br/>mark run partial]
    OpenAll --> Gate{auto_apply AND<br/>non-destructive AND<br/>not halted?}
    OpenSome --> Gate
    Gate -->|no| Queue[Proposal queue<br/>operator reviews]
    Gate -->|yes| AutoApply[Reconciler auto-approves<br/>+ applies via ApplyService]
    Queue --> Op{Operator<br/>decision}
    Op -->|approve| Apply[ApplyService applies]
    Op -->|reject| Retain[Live state retained<br/>diff re-detected next tick]
    Op -->|ignore| Retain
    Apply --> Sync2[Live DB updated]
    AutoApply -->|success| Sync2
    AutoApply -.stale conflict / validation.-> Revert[Revert to pending_review<br/>operator investigates]
    Sync2 --> Audit[Audit trail:<br/>GitopsSyncRun<br/>+ FleetEvent]
```

---

## Resource kinds

| Kind | Maps to | Diff scope |
|------|---------|------------|
| `templates` | `System::NodeTemplate` | name + description + node_platform_id |
| `modules` | `System::NodeModule` | name + priority + variety + config |
| `assignments` | `System::NodeModuleAssignment` (keyed by `node-name:module-name`) | enabled + priority + config |
| `provider_configs` | `System::ProviderConnection` | informational only — credentials NEVER rotated via GitOps |

---

## Operator workflow

### 1. Register a repository

```bash
curl -X POST http://localhost:3000/api/v1/system/gitops_repositories \
  -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  -d '{
    "gitops_repository": {
      "name": "fleet-config",
      "repo_url": "git@gitea.example.com:org/fleet.git",
      "branch": "main",
      "vault_credential_path": "secret/data/powernode/gitops/fleet-deploy-key",
      "path_prefix": "",
      "enabled": true,
      "auto_apply": false
    }
  }'
```

Permission: `system.gitops.write`.

### 2. Trigger an off-schedule sync

```bash
curl -X POST http://localhost:3000/api/v1/system/gitops_repositories/<id>/sync_now \
  -H "Authorization: Bearer $JWT"
```

Permission: `system.gitops.sync`. Returns the sync run + any proposals
opened.

### 3. Review the proposal queue

The standard `Ai::AgentProposal` flow surfaces GitOps diffs in the
operator UI. Each proposal shows:
- Resource kind + name
- Change type (`create` / `update` / `destroy`)
- Full diff (current vs. desired)
- Source repo + commit SHA

Approve to apply; reject to retain live state.

### 4. Auto-apply mode

`auto_apply: true` lets the reconciler apply diffs without operator approval,
for fully-trusted repositories where git itself is the change-control gate.
Default is `false` (every diff waits for operator review).

The audit `Ai::AgentProposal` is **always created first**, then auto-approved
(`reviewed_by` nil; `impact_assessment.auto_applied = true`,
`approved_by = "gitops_auto_apply"`) and applied via `ApplyService`. A proposal
is auto-applied only when **all four** safety gates hold:

1. **`repository.auto_apply == true`.**
2. **The diff is non-destructive** — `change` is `create` or `update`. A
   `destroy` ALWAYS stays `pending_review` for manual approval, even an
   **assignment** destroy (which `ApplyService` would otherwise allow on
   operator approval).
3. **The account is not halted** — the platform kill-switch / emergency-halt
   (`account.ai_suspended?`, via `Ai::Autonomy::KillSwitchService`) must be
   clear. If halted, auto-apply is skipped and the proposal stays
   `pending_review`.
4. **Only the per-tick-capped diff set is eligible** (the same `create` /
   `update` diffs that would have become proposals this tick).

If `ApplyService` fails (stale conflict, validation), the proposal is reverted
to `pending_review` with the failure reason stashed in `impact_assessment`, and
the reconcile continues — one failure never aborts the rest of the tick.

---

## Authentication

| URL scheme | Auth via `vault_credential_path` |
|------------|----------------------------------|
| `https://...` (anonymous OK) | optional |
| `https://...` (private repo) | `{ username: "...", password: "..." }` in Vault KV |
| `git@...` / `ssh://...` | `{ ssh_key: "----BEGIN..." }` in Vault KV |

**Important**: URLs with embedded credentials (e.g.,
`https://user:pass@host/repo`) are rejected at validation time — they
leak credentials into git history and shell logs. Always use Vault.

---

## Safety mechanisms

### Per-tick proposal cap

`POWERNODE_GITOPS_MAX_PROPOSALS_PER_TICK` (default 25) caps the number of
proposals opened per reconcile run. When a repository is rewritten in one
commit, the first 25 diffs become proposals; the run is marked `partial`
with an error message indicating remaining diffs. Subsequent ticks pick
up the rest as the operator approves the first batch.

### URL sanitization

`GitopsRepository` validation rejects URLs containing inline credentials
(`https://user:pass@...`).

### Path prefix sanitization

`path_prefix` must be a relative path without `..` traversal — a
malicious repo can't read files outside its own working tree.

### File size cap

`fleet.yaml` is rejected if it exceeds 1 MiB. Larger files indicate
unintended bloat (or attempts to use the parser as an exfiltration
channel via OOM).

### YAML safe_load

The parser uses `YAML.safe_load` with a small allowlist of permitted
classes (`Symbol`, `Date`, `Time`). Untrusted YAML can't deserialize
into arbitrary Ruby objects.

### Per-account isolation

Each repository is bound to one account; diffs only compare against
that account's state. Cross-tenant leakage requires a deliberate
operator action (manual sync of someone else's repo URL).

---

## Audit trail

`System::GitopsSyncRun` records every reconcile attempt:

- Started/completed timestamps
- Diff count
- Proposal IDs opened
- Status (`running` | `success` | `failed` | `partial`)
- Synced revision (commit SHA)
- Error message (if failed)
- Diff summary (counts per resource kind)

Sync runs are retained 90 days routine / 365 days for `failed` /
`partial` (mirrors `FleetEvent` retention). The `GitopsPage` UI surfaces
recent runs per repository.

---

## Implementation files

| Concern | File |
|---|---|
| Worker job | `extensions/system/worker/app/jobs/system_gitops_sync_job.rb` |
| Worker_API endpoint | `extensions/system/server/app/controllers/api/v1/system/worker_api/gitops_controller.rb` |
| Operator API | `extensions/system/server/app/controllers/api/v1/system/gitops_repositories_controller.rb` |
| Reconciler orchestrator | `extensions/system/server/app/services/system/gitops/reconciler.rb` |
| Repo clone/pull | `extensions/system/server/app/services/system/gitops/repo_sync_service.rb` |
| YAML parsing | `extensions/system/server/app/services/system/gitops/desired_state_parser.rb` |
| Desired-state validation | `extensions/system/server/app/services/system/gitops/desired_state_validator.rb` |
| Live-vs-desired diff | `extensions/system/server/app/services/system/gitops/diff_engine.rb` |
| Apply (create/update; destroy for assignments only) | `extensions/system/server/app/services/system/gitops/apply_service.rb` |
| Models | `extensions/system/server/app/models/system/gitops_repository.rb`, `gitops_sync_run.rb` |
| Migrations | `db/migrate/20260503040300_create_system_gitops_repositories.rb`, `_040400_*sync_runs.rb`, `_040500_seed_gitops_permissions.rb` |
| Permissions seed | `system.gitops.read`, `.write`, `.sync`, `.reconcile` |
| Cron entry | `extensions/system/worker/config/sidekiq_system.yml` (`system_gitops_sync` every 5 min) |

---

## Known limitations

- **Auto-apply never applies destroys** — when `repository.auto_apply` is set,
  the reconciler auto-approves + applies `create` / `update` diffs (proposal →
  approve → `ApplyService`), but `destroy` diffs ALWAYS stay `pending_review`
  for manual approval (even assignment destroys, which `ApplyService` would
  otherwise allow on operator approval). This is a deliberate safety gate, not
  a gap — a stray `fleet.yaml` edit can never delete fleet resources
  unattended.
- **Template / module destroy unimplemented** — `ApplyService` applies
  `create` / `update` for all kinds and `destroy` for **assignments**, but a
  `destroy` diff for a `template` or `module` raises `UnsupportedDiffError`
  (v1-conservative: destructive template/module ops require manual
  confirmation; expected in Phase 6c). Assignment destroy works on operator
  approval (but, per the gate above, never via auto-apply).
- **No multi-document YAML** — `fleet.yaml` is a single document. To
  manage many concerns, use `path_prefix` with multiple repositories
  pointing at different roots.
- **No drift back-pressure** — if you apply a diff via the operator UI
  and then revert it manually in the DB, the next reconcile will re-open
  the same proposal. On an `auto_apply` repo the reconciler re-applies the
  non-destructive correction automatically on the next tick; a manual
  destroy still re-opens a `pending_review` proposal for an operator.
- **No webhook trigger** — diffs only get detected on the 5-minute cron
  or via manual `sync_now`. A future enhancement would accept Gitea /
  GitHub webhooks to trigger immediate reconciliation on push.

---

## Reference

- **Operator runbook**: [`runbooks/gitops-reconciliation.md`](./runbooks/gitops-reconciliation.md) — day-2 procedure (register, sync, review, apply, DR scenarios)
- **Tutorial**: [`tutorials/10-gitops-fleet.md`](./tutorials/10-gitops-fleet.md) — first-time walkthrough
- Module system: [`ARCHITECTURE.md`](./ARCHITECTURE.md)
- Threat model: [`threat-model-2026-04.md`](../../../docs/history/audits/threat-model-2026-04.md) (parent platform; STRIDE analysis incl. worker API + internal CA)

---

_Last verified: 2026-06-04_
