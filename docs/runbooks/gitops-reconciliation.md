# GitOps Reconciliation — Operator Runbook

> Status: active

Operator-facing companion to design-level [`docs/gitops.md`](../gitops.md).
Covers the day-2 workflow for managing fleet state via git: when to use
GitOps vs operator-UI changes, authoring `fleet.yaml`, registering
repositories, triggering syncs, reviewing proposals, applying changes,
and recovering from common failure modes.

**Audience:** SREs adopting GitOps for fleet config, multi-engineer teams
needing PR-based change control.

**Apply maturity (v1):** parser, diff engine, reconciler, the drift sensor,
and `ApplyService` all ship today. Approving the `Ai::AgentProposal` says the
diff is wanted; the `system.gitops_apply_proposal` gate says an agent may write
it — `system_gitops_apply_proposal` is approval-gated under that category
(`require_approval` by default, IMP-0b4f18ae4384), so an agent's call answers
`pending: true` with a SECOND approval request, and `ApplyService` runs only
when that is approved (or the row is tuned to `auto_approve`).
**Reconciler-driven auto-apply is wired** — on an `auto_apply` repo the
every-5-min reconciler auto-approves + applies non-destructive diffs without an
operator step (see "Step 4 — Apply"). Two carve-outs remain v1-conservative:

- **Destroys never auto-apply.** A `destroy` diff ALWAYS stays
  `pending_review` for manual approval, even on an `auto_apply` repo — and even
  an **assignment** destroy, which `ApplyService` would otherwise allow on
  operator approval. A stray `fleet.yaml` edit can never delete fleet resources
  unattended.
- **Template/module destroy via GitOps is intentionally blocked.** Removing
  a `templates:`/`modules:` entry from `fleet.yaml` returns
  `UnsupportedDiffError` (destructive ops require manual confirmation).
  Only **assignment** destroy (removing a `<node>:<module>` line) applies
  through GitOps, and only on explicit operator approval. Template/module
  create + update apply normally.

## End-to-end flow

```mermaid
sequenceDiagram
    actor Op as Operator
    participant Git as Git remote<br/>(Gitea / GitHub)
    participant Cron as SystemGitops<br/>SyncJob
    participant Sync as RepoSyncService
    participant Parse as DesiredStateParser
    participant Diff as DiffEngine
    participant Prop as Ai::AgentProposal
    participant Op2 as Operator (reviewer)
    participant Apply as ApplyService
    participant DB as Platform DB

    Op->>Git: git push fleet.yaml
    Cron->>Sync: every 5 min<br/>(or sync_now trigger)
    Sync->>Git: git pull
    Sync->>Parse: fleet.yaml → DesiredState
    Parse->>Diff: compare vs live DB
    Diff->>Prop: open one proposal per change<br/>(capped at POWERNODE_GITOPS_<br/>MAX_PROPOSALS_PER_TICK)
    Prop-->>Op2: appear in /app/approvals
    Op2->>Apply: approve →<br/>system_gitops_apply_proposal<br/>(parks under the system.gitops_apply_proposal<br/>gate until that approval is granted too)
    Apply->>DB: apply this proposal's diff<br/>(template/module/assignment/pool/platform)
    DB-->>Apply: success / stale conflict / unsupported
    Apply->>Prop: mark proposal implemented
```

## When to use GitOps (vs operator UI)

**Use GitOps when:**

- Multiple operators / teams change fleet config; you need PR review as the gate
- You want git history as the audit trail
- You want declarative drift detection (reality drifts from intent → alert)
- Onboarding new environments where copying YAML beats clicking through the UI

**Use the operator UI instead when:**

- You're making one-off exploratory changes (test a new module on a single instance)
- You're responding to an incident where speed beats audit
- You're working in a single-operator environment with no PR review process

You can mix — most teams declare the steady-state in `fleet.yaml` and
let operators make one-off tactical changes via UI. The `GitopsDriftSensor`
(registered in the Fleet Autonomy sensor set) flags the mismatch so
operators can either commit it back to git or revert.

## Authoring `fleet.yaml`

The file lives at the root of your registered repo (or under `path_prefix`).

### Minimal example

```yaml
version: 1
account: "<account-id>"

templates:
  web-server:
    name: web-server
    description: Standard nginx node
    node_platform_id: "<node-platform-uuid>"

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
    enabled: false      # disabled on app-02 without detaching the module
```

### Full schema (4 top-level kinds)

| Kind | Maps to platform model | Keying |
|------|-------------------------|--------|
| `templates` | `System::NodeTemplate` | hash keyed by template name |
| `modules` | `System::NodeModule` | hash keyed by module name |
| `assignments` | `System::NodeModuleAssignment` | hash keyed by `<node-name>:<module-name>` |
| `provider_configs` | `System::ProviderConnection` | informational only — credentials NEVER rotated via GitOps (use Vault directly) |

### Conventions that save grief

- **Pin module versions** explicitly (`- nginx@1.26.0`, not just `- nginx`) — unpinned references use the latest `live`-state version, which may shift surprisingly when a new version promotes
- **One concern per repo** — separate repos for different parts of the
  fleet (network config in `fleet-sdwan`, container hosts in
  `fleet-runtime`) reduce blast radius of bad PRs
- **Use `path_prefix`** to host multiple environments in one repo
  (`environments/prod/fleet.yaml` + `environments/staging/fleet.yaml`),
  each registered as a separate `GitopsRepository`

## Step 1 — Register the repository

Create the repo first:

```bash
# If using Gitea:
curl -X POST http://localhost:3000/api/v1/integrations/gitea/repositories \
  -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  -d '{ "owner": "<account>", "repo": "fleet-config", "private": true }'
```

Then register the repo with the reconciler:

```bash
curl -X POST http://localhost:3000/api/v1/system/gitops_repositories \
  -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  -d '{
    "gitops_repository": {
      "name": "fleet-config",
      "repo_url": "git@gitea.example.com:<account>/fleet-config.git",
      "branch": "main",
      "vault_credential_path": "secret/data/powernode/gitops/fleet-deploy-key",
      "path_prefix": "",
      "enabled": true,
      "auto_apply": false
    }
  }'
```

Permission: `system.gitops.write`.

### Vault credential layout

The `vault_credential_path` points at a Vault KV v2 secret with one of:

| URL scheme | Vault payload |
|------------|---------------|
| `https://...` anonymous | (omit `vault_credential_path` entirely) |
| `https://...` private | `{ "username": "...", "password": "..." }` |
| `git@...` / `ssh://...` | `{ "ssh_key": "----BEGIN OPENSSH PRIVATE KEY----..." }` |

**Important:** URLs with embedded credentials (`https://user:pass@host/repo`)
are rejected at validation time — they leak into git history and shell
logs.

## Step 2 — Trigger an off-schedule sync

```bash
curl -X POST http://localhost:3000/api/v1/system/gitops_repositories/<id>/sync_now \
  -H "Authorization: Bearer $JWT"
```

Permission: `system.gitops.sync`. On success returns the `GitopsSyncRun` + any
proposals opened. A FAILED reconcile answers **422** (reason in `error`, the
same payload under `details`) and a standby control plane answers **409**
`standby_control_plane` with no run minted — branch on the HTTP status, not on
the run's own fields (SWEEP-2026-09-03).

Or wait — the cron runs every 5 min by default.

## Step 3 — Review proposals

Each diff becomes an `Ai::AgentProposal`. Standard approval UI surfaces:

- Resource kind + name
- Change type (`create` / `update` / `destroy`)
- Full diff (current vs. desired)
- Source repo + commit SHA

Approve to apply; reject to retain live state. Reject doesn't suppress
re-detection — the next sync re-opens the same proposal until you either
approve or change the source.

## Step 4 — Apply (auto vs gated)

**`auto_apply: false`** (default) — every diff requires operator approval.
Approving the `Ai::AgentProposal` says the diff is wanted; the
`system.gitops_apply_proposal` gate says an agent may write it.
`system_gitops_apply_proposal` parks with `pending: true` under that category
(`require_approval` by default) and `ApplyService` runs on that second
approval — an operator who approves the proposal and then sees `pending: true`
has one more approval to grant, not a failed apply.
Recommended until your team's PR review process is mature enough that git
itself is trusted as the source of truth.

**`auto_apply: true`** — the reconciler auto-approves + applies each eligible
diff with no operator step. The audit `Ai::AgentProposal` is still created
first (so every change has a record), then auto-approved (`reviewed_by` nil,
`impact_assessment.auto_applied = true`) and applied. A diff is auto-applied
only when **all four** gates hold:

1. `repository.auto_apply` is `true`.
2. The diff is **non-destructive** (`create` / `update`). Destroys always stay
   `pending_review` for manual approval.
3. The account is **not halted** — the platform kill-switch / emergency-halt
   (`account.ai_suspended?`) must be clear. If halted, the proposal stays
   `pending_review` until you resume and the next tick re-applies it.
4. The diff is within the per-tick cap.

On a stale conflict or validation failure the proposal is reverted to
`pending_review` (with the failure reason in `impact_assessment`) and the
reconcile continues. Restrict `auto_apply: true` to repos where:

- The repo's branch protection requires multi-reviewer PRs
- All committers are trusted operators
- The change history is otherwise audited (compliance requirement)

### What happens when ApplyService runs

```mermaid
flowchart TD
    Approve[Operator approves proposal<br/>→ system_gitops_apply_proposal<br/>parks under the system.gitops_apply_proposal<br/>gate until approved<br/>OR reconciler auto-apply<br/>on an auto_apply repo] --> Apply[ApplyService.apply!<br/>for that proposal]
    Apply --> TXN{atomic transaction<br/>per resource}
    TXN -->|success| Mark[proposal.status = implemented<br/>+ FleetEvent]
    TXN -->|stale conflict| Stale[Reject as stale<br/>operator re-syncs for a fresh proposal]
    TXN -->|unsupported diff| Unsup[Return error<br/>e.g. template/module destroy]
    TXN -->|validation failure| Fail[Return validation error<br/>operator investigates]
```

## Step 5 — Verify convergence

```bash
curl http://localhost:3000/api/v1/system/gitops_sync_runs/<run-id> \
  -H "Authorization: Bearer $JWT" | jq
# → { status: "applied", applied_actions: [...], failed_actions: [], ... }
```

Subsequent reconcile ticks verify no drift. The `GitopsDriftSensor`
(registered in the Fleet Autonomy sensor set) emits a
`system.gitops.drift_detected` signal per repo with unresolved drift, so
observability tooling can surface divergence.

## DR scenarios

### Repo lost (Gitea outage, deleted by accident, migrated)

1. Reconciler tick logs `RepoSyncService` failures (`Failed to clone`)
2. Existing fleet state is unaffected — nothing in the DB depends on the
   repo being reachable
3. Restore the repo (from backup, or rebuild `fleet.yaml` from current DB
   state by hand — there is no `fleet.yaml` export action yet, so manual
   composition is the path today)
4. Re-register if the URL changed

### Account moved (operator migration to a new account)

`fleet.yaml`'s `account:` field is the binding key. Edit the file to
point at the new account, push, sync — diffs will show "destroy in old
account, create in new" if the resources also moved. Otherwise the new
account will just create from scratch.

### Partial sync recovery

`POWERNODE_GITOPS_MAX_PROPOSALS_PER_TICK` (default 25) caps proposals
per run. A repo rewrite that spawns 100+ diffs only gets the first 25 in
proposals; the run is marked `partial`. To complete:

1. Approve the first batch of proposals (or reject some intentionally)
2. Wait for the next 5-min tick — it picks up the next 25
3. Repeat until the run reports `status: success` with 0 remaining diffs

For very large initial imports, temporarily raise the cap via env var,
restart the worker, do the import, then lower it back to 25.

## Common failure modes

**"YAML safe_load: undefined class Date"** — `fleet.yaml` uses a type
outside the safe-load allowlist (Symbol / Date / Time). Either rewrite
in plain strings or extend the parser's allowlist (requires a code change).

**`fleet.yaml` rejected at 1 MiB limit** — file is too big. Almost always
unintended (someone committed binary data). Inspect with
`du -h fleet.yaml` and `git log -p fleet.yaml` to find the inflation.

**Repository keeps clone-erroring** — usually a Vault credential issue:

```bash
# Verify the credential exists
vault kv get secret/data/powernode/gitops/fleet-deploy-key

# Verify the SSH key has read access to the repo
ssh -T -i <key-path> git@gitea.example.com
```

**Reconciler ticks succeed but no proposals open** — `DiffEngine` is
returning empty. Either:

- `fleet.yaml` matches live state exactly (no diff)
- The `account:` field doesn't match the operator's account (cross-account leak protection)
- `path_prefix` points to a non-existent subdirectory

**"Resource constraint: account_id mismatch"** — `fleet.yaml`'s `account:`
key doesn't match the `GitopsRepository.account_id`. Cross-account drift
is explicitly rejected.

**Operator changed fleet via UI; reconciler keeps re-opening proposals to
revert** — expected behavior. Either commit the UI change back to git
(treats operator change as authoritative) or accept the reversion (treats
git as authoritative).

**Assignment apply fails "template/module not found"** — `ApplyService`
resolves an assignment's template + module by name at apply time and
returns a stale-conflict if either is missing. Apply the
template/module-create proposals first, then the assignment that depends
on them (apply is per-proposal, so ordering is operator-driven, not an
automatic topological batch). Re-sync if the names drifted.

## Cross-references

- [`../gitops.md`](../gitops.md) — design-level reference (reconciler architecture, safety mechanisms, audit trail)
- [`../tutorials/10-gitops-fleet.md`](../tutorials/10-gitops-fleet.md) — first-time tutorial walking through registering a repo + seeing proposals
- [`../history/plans/missing-features.md`](../history/plans/missing-features.md) — historical M-D2-3 implementation plan (archived; some items now shipped)
- `extensions/system/server/app/services/system/gitops/` — source code (DesiredStateParser, DiffEngine, Reconciler, RepoSyncService, ApplyService)

_Last verified: 2026-06-04_
