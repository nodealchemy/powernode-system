# Tutorial 10 — GitOps-managed fleet via fleet.yaml

> Status: active

> **What you'll learn:** Declare your fleet's desired state in `fleet.yaml`,
> commit to git, let the GitOps reconciler compute the diff against
> reality, approve through the standard intervention policy, apply.
> Replaces ad-hoc MCP calls with PR-based change control.
>
> **Time:** ~45 min (mostly diff review)
>
> **Builds on:** [Tutorial 02](./02-first-module.md) (you've authored a module
> and understand the lifecycle promotion model) and
> [Tutorial 06](./06-rolling-upgrade.md) (you understand the approval gate on a
> fleet change, and that a module upgrade is fleet-atomic once applied).
>
> **Sets you up for:** [Tutorial 11 — Multi-region federation](./11-federation.md) —
> federation peers are enrolled with the `system_sdwan_*` actions on nodes
> the pools declared here materialise; `fleet.yaml` itself has no `sdwan`
> kind.

## What you're building

```mermaid
flowchart TD
    Repo[(fleet-config git repo)]
    Op[Operator] -- "git commit + push" --> Repo
    Repo -- "5min cron OR<br/>manual sync trigger" --> RS[RepoSyncService]
    RS --> DSP[DesiredStateParser]
    DSP --> DE[DiffEngine]
    DE -- "vs current platform state" --> Diff[Diff payload:<br/>add / update / delete<br/>across templates / modules /<br/>assignments / pools / platforms]
    Diff --> AR[ApprovalRequest<br/>per Fleet Autonomy policy]
    AR --> Op2{Operator<br/>approves?}
    Op2 -->|yes| App[ApplyService<br/>walks diff in dependency order]
    App --> Done[Resources<br/>materialized in DB<br/>+ instances reconcile]
    App --> SR[SyncRun status:<br/>success / partial / failed]
    Op2 -->|edit| Edit[Adjust YAML +<br/>re-trigger sync]
    Edit --> RS
    Drift[Drift sensor<br/>every 60s] -- "reality drifts" --> Repo
```

By the end you'll have your fleet's desired state codified in git, with
PR review as the gating mechanism for fleet changes.

## Concept refresher

**`fleet.yaml`** declares the desired state for an Account:

- **Templates** — the node templates, each bound to a node platform
- **Modules** — the modules, with their variety and priority
- **Assignments** — which modules compose each template
- **Pools** — what should exist: warm instance pools bound to a template,
  with sizes, lifecycle class and status (this is the *only* way
  `fleet.yaml` says "N nodes of template X" — there is no `node` kind)
- **Platforms** — `PlatformDeployment` replica targets per service role
- **Provider configs** — informational only; credentials are never rotated
  via GitOps

Nodes and the SDWAN overlay (networks, peers, VIPs) are **not** in this
file — see the schema notes under Step 1.

The reconciler walks this and computes the delta against current
platform state. Each delta becomes an `Ai::AgentProposal` (with
`proposed_changes.source = "gitops"`). By default it requires operator
approval; on an `auto_apply` repo the reconciler auto-approves + applies
non-destructive (create / update) diffs itself (see "Auto-apply" below). The
reconciler opens these proposals **directly** — there is no
`system.gitops_*` intervention policy; approval flows through the
standard proposal review queue, not a per-action autonomy policy.

**Implementation status (honest, as of 2026-06-03):**

| Capability | Status |
|---|---|
| Parse `fleet.yaml` from a git repo | Shipped (`DesiredStateParser`) |
| Compute diff against current state | Shipped (`DiffEngine`) |
| Reconciler opens proposals per change | Shipped (`Reconciler`) |
| MCP actions: list_repositories / get_repository / register / sync / get_sync_run / get_drift_report / apply_proposal | Shipped (gap remediation slices closed; the two reads under IMP-f07be27ba0b0) |
| Proposal-apply path (post-approval execution) | Shipped for `template` / `module` / `assignment` / `pool` / `platform` create+update via `system_gitops_apply_proposal`; **destroy + provider_config remain follow-ups** |
| Reconciler-driven auto-apply (`repository.auto_apply`) | Shipped — auto-approves + applies non-destructive (create / update) diffs, gated by the kill-switch + per-tick cap; destroys always stay manual |
| Drift sensor (alert when reality drifts from git) | Shipped (`GitopsDriftSensor`, registered in `FleetAutonomyService::SENSORS`; emits `system.gitops.drift_detected`) |
| Operator UI for diff review + approval | Partial — generic `ApprovalRequest` UI works; GitOps-specific drill-in panel forthcoming |

GitOps applies the **create/update** path for `template`, `module`,
`assignment`, `pool` and `platform` — either once an operator approves the proposal, or
automatically on an `auto_apply` repo (see "Auto-apply"). The
**conservative v1 gap** is deliberate: resource **destroy** and
`provider_config` changes are never auto-applied — review the drift and
remove resources manually so a stray `fleet.yaml` edit can never delete
fleet infrastructure unattended.

### Auto-apply

Set `auto_apply: true` on the repository to let the reconciler apply diffs
without an operator step. The audit `Ai::AgentProposal` is still created
first, then auto-approved (`impact_assessment.auto_applied = true`) and
applied via `ApplyService`. A diff auto-applies only when **all** of: the
repo opts in, the change is non-destructive (`create` / `update` — never
`destroy`), the account is not halted (platform kill-switch /
`account.ai_suspended?`), and it's within the per-tick cap. On a stale
conflict or validation failure the proposal reverts to `pending_review` for
an operator. Restrict `auto_apply: true` to repos whose git history is the
trusted change-control gate (multi-reviewer PRs, trusted committers).

**Why GitOps:** git history is the audit trail; PR review is the change
control; reconciler convergence catches drift. Replaces "operator runs
imperative commands and hopes the snapshot reflects intent."

## Prerequisites

| Requirement | How |
|---|---|
| A Gitea repo (or any git remote) for the fleet config | `platform.create_gitea_repository` |
| Permissions: `system.modules.read` / `system.modules.update` for the module-shaped `platform.*` calls; `system.gitops.read` for the repository reads that carry the credential contract (REST `index`/`show`/`sync_runs` and the `system_gitops_get_repository` / `system_gitops_list_repositories` MCP verbs); `system.gitops.write` for the REST `create`/`update`/`destroy`; `system.gitops.sync` for the REST `sync_now`. The other `system_gitops_*` MCP verbs stay on `system.modules.read` / `.update` | Both families are registered in the `system` catalog (`server/lib/powernode_system/engine.rb`). `admin` holds `system.modules.*`, `system.gitops.read` (since IMP-b1191457a091) and — since IMP-e313a4a72309 — `system.gitops.write` and `system.gitops.sync`, so a plain admin can drive the whole REST surface. Only `system.gitops.reconcile` stays worker-only; it gates the worker tick, not an operator action. A grant added to the catalog reaches an ALREADY-INSTALLED deployment at its next boot, when `Permissions::RoleGrantReconciler` runs — not at deploy time. That reconcile is invoked from the `powernode-hub-backend` module's `rails-start.sh:356-357`, the only invocation site there is, so a Rails install started by any other path never gets it |
| A running Powernode platform with at least one Account configured | Default |
| (Optional) Tutorial 02 module authoring done | Helps you understand the templates section of fleet.yaml |

## Step 1 — Author `fleet.yaml`

`fleet.yaml` is a mapping of the resource sections GitOps knows —
`templates`, `modules`, `assignments`, `pools`, `platforms` and the
informational `provider_configs` — plus an optional `fleet:` defaults block.
Every resource section is itself a mapping of **name → attributes**: a
list-shaped `templates`, `modules`, `assignments`, `pools` or `platforms`
section is refused by the validator (`provider_configs` is the one section
with no shape rule — `DesiredStateParser#parse_section` re-keys a list there
by each item's `name`). The file below is the one the rest of this tutorial
syncs: two templates, three modules, the composition of each template, and
one warm instance pool.

```yaml
# fleet.yaml
templates:
  edge-base:
    name: edge-base
    description: Hardened Ubuntu edge baseline
    node_platform: ubuntu-24.04-amd64-uefi
  edge-cdn:
    name: edge-cdn
    description: Edge CDN node — the edge-base baseline plus nginx
    node_platform: ubuntu-24.04-amd64-uefi

modules:
  system-base:
    name: system-base
    variety: subscription
    priority: 10
    config: {}
  security-hardening:
    name: security-hardening
    variety: config
    priority: 20
    config: {}
  nginx:
    name: nginx
    variety: config
    priority: 50
    config:
      worker_processes: 4

assignments:
  edge-base:system-base:
    template: edge-base
    module: system-base
  edge-base:security-hardening:
    template: edge-base
    module: security-hardening
  edge-cdn:system-base:
    template: edge-cdn
    module: system-base
  edge-cdn:security-hardening:
    template: edge-cdn
    module: security-hardening
  edge-cdn:nginx:
    template: edge-cdn
    module: nginx

pools:
  edge-cdn-tokyo:
    name: edge-cdn-tokyo
    node_template: edge-cdn
    lifecycle_class: ephemeral
    status: active
    target_size: 2
    min_size: 1
    max_size: 3
```

What each section resolves to, and what the apply path needs from it:

| Section | Platform model | Keyed by | Apply-time requirements |
|---|---|---|---|
| `templates` | `System::NodeTemplate` | template name | `node_platform` — the **name** of a `System::NodePlatform` already in the account; `ApplyService` refuses a template create without it, and raises a stale conflict if the name resolves to nothing. `AccountBootstrapService` seeds four (`ubuntu-24.04-lts`, `ubuntu-24.04-rpi4`, `ubuntu-24.04-arm64-uefi`, `ubuntu-24.04-amd64-uefi`) — list yours before you commit the file |
| `modules` | `System::NodeModule` | module name | `variety` ∈ `System::NodeModule::VARIETIES` — `subscription` / `config` / `instance`. **The validator is looser than the model here:** `DesiredStateValidator::MODULE_VARIETIES` also accepts `role`, which `NodeModule` and the `system_node_modules_variety_check` constraint both reject, so a `variety: role` line passes the schema gate and then fails at apply with `Variety is not included in the list`. `priority` must be an integer if present, but see the convergence gaps below — it is not applied |
| `assignments` | written as `System::TemplateModule`, diffed against `System::NodeModuleAssignment` | the validator requires a `<name>:<module>` string; `DiffEngine` reads that key as `<node-name>:<module-name>` | `template` and `module` — names declared in the two sections above; `ApplyService#apply_assignment` resolves both by name and reports a stale conflict if either is missing. The two sides do not share an identity — see the convergence gaps below |
| `pools` | `System::InstancePool` | pool name | `node_template` — a template name from this file; `lifecycle_class` ∈ `ephemeral` / `spot`; `status` ∈ `active` / `paused` / `draining` / `archived`; the three sizes as integers |
| `platforms` | `System::PlatformDeployment` | deployment name | `node_template` plus a `service_role`; `target_replicas` an integer (not used above) |

Two things the file deliberately does NOT contain, because GitOps cannot
express them:

- **There is no `node` kind.** `ApplyService#apply_diff` dispatches template,
  module, assignment, pool, platform and provider_config, and raises
  `UnsupportedDiffError` for anything else; `DiffEngine` computes diffs for
  only those kinds. What *should exist* is declared as a `pools` entry — the
  instance-pool replenisher materialises the pool's members as real nodes —
  never as a list of hostnames. A Node's `lifecycle_class` is not
  GitOps-declarable at all (nor settable through any other API surface; the
  column is retired). The class lives on the `System::InstancePool`, which is
  exactly where the example above sets it. See
  [`../USE_CASE_MATRIX.md`](../USE_CASE_MATRIX.md) §"How `lifecycle_class` is
  actually set".
- **There is no `sdwan` kind.** Networks, peers and virtual IPs are still
  built with the `system_sdwan_*` actions; a `sdwan:` block in `fleet.yaml` is
  reported as an unknown top-level key and fails the whole sync.

The validator also refuses `version:` and `account:` headers — a repository
is bound to its account when it is registered (Step 2), not by a key inside
the file. Unknown top-level keys are collected, not skipped: one stray key
aborts the entire sync, so keep the file to the sections above.

**Three v1 convergence gaps.** The file above validates, parses and applies,
but `DiffEngine` and `ApplyService` do not yet agree on three fields, so those
lines re-open as a proposal on every sync. Apply is idempotent — re-approving
costs nothing and loses nothing — but do not expect a clean `diff_count: 0`
for them:

- **Assignments are diffed node-keyed and applied template-keyed.**
  `DiffEngine#diff_assignments` builds live state from
  `System::NodeModuleAssignment`, keyed `<node-name>:<module-name>`, while
  `ApplyService#apply_assignment` creates a `System::TemplateModule` from the
  entry's `template` + `module` names. A `<template>:<module>` key therefore
  never matches a live row: applying it composes the template correctly, and
  the next sync proposes the identical `create` again.
- **`modules.*.priority` and `modules.*.config` are validated and diffed but
  never written.** `apply_module` sets name / variety / category on create and
  description / variety on update — nothing else — so a non-default `priority`
  comes back as an `update` diff each pass.
- **`templates.*.node_platform` is a name going in and `node_platform_id`
  coming back.** `apply_template` resolves the name at create time;
  `diff_templates` compares the stored `node_platform_id`, which the file does
  not carry.

**Expected outcome:** the file passes `System::Gitops::DesiredStateValidator`
with no errors and `DesiredStateParser` returns `ok?: true` — this exact block
is run through both (and through `DiffEngine`) by
`server/spec/docs/gitops_fleet_yaml_tutorial_fidelity_spec.rb`, so it cannot
drift from the schema unnoticed. The authoritative schema is the validator
itself, `server/app/services/system/gitops/desired_state_validator.rb` — read
`ALLOWED_TOP_LEVEL` and the `validate_*` methods.

## Step 2 — Register the GitOps repo

```javascript
// Create the repo first
platform.create_gitea_repository({
  repo_name: "fleet-config",
  organization: "<account>",   // omit for the personal namespace
  private: true
})

// Push fleet.yaml to it via git
// ...

// Register with the platform's reconciler
platform.system_gitops_register_repository({
  name: "fleet-config",        // required; unique within the account
  repo_url: "git@registry.example.com:<account>/fleet-config.git",
  branch: "main",
  vault_credential_path: "secret/data/powernode/gitops/fleet-deploy-key"
})
// → { repository: { id: "gitops-repo-1", last_status: "pending", ... } }
```

`vault_credential_path` is a Vault KV path, not a credential id. Store
**one** of the two shapes at that path, matching your remote:
`{ ssh_key }` for `git@` / `ssh://`, or `{ username, password }` for
`https://` (and plain `http://`, which takes the same branch) —
`RepoSyncService#build_git_env` picks by URL scheme. Inline credentials in
`repo_url` (`https://user:pass@...`) are rejected at validation.

**Expected outcome:** repo registered; reconciler will pull on the platform's
fixed 5-minute tick and any time `system_gitops_sync_repository` is invoked.
The interval is **not** per-repository — `GitopsRepository.due_for_sync` is
called with a hardcoded 5-minute staleness
(`api/v1/system/worker_api/gitops_controller.rb`), so there is no registration
parameter that changes it.

## Step 3 — Trigger a sync

```javascript
platform.system_gitops_sync_repository({
  id: "gitops-repo-1"          // the GitopsRepository id
})
// → { success: true, data: { repository_id, sync_run_id, ok: true, diff_count,
//     proposal_ids, synced_revision, diff_summary, error } }
```

The reconcile runs **synchronously** inside this call — `diff_count`,
`proposal_ids` and `diff_summary` are already final when it returns, and
`sync_run_id` is the run this call finalized (Step 4 reads it back). A reconcile
that **failed** — clone/pull refused, `fleet.yaml` did not parse, the diff
raised — comes back as `{ success: false, error: "<reason>", data: { ...,
ok: false, sync_run_id } }`: branch on `success`, not on `ok` or on the shape of
`diff_summary`, and do not conclude the fleet matches the repository on that
response. On a **standby** control plane the verb refuses outright with
`refusal_code: "standby_control_plane"` (`retryable: false`) and creates no run
— the active plane owns the reconcile. The one success response that carries a
non-nil `error` is a `partial` run, where the per-tick proposal cap truncated
the proposal set (`diff_count` exceeds `proposal_ids.length`).

The reconciler:

1. Pulls latest from `main`
2. Parses `fleet.yaml` via `DesiredStateParser`
3. Loads current platform state (templates, modules, assignments, pools, platforms)
4. Runs `DiffEngine` to compute the delta
5. Opens `Ai::AgentProposal` per change

## Step 4 — Review the diff

Step 3 already handed the run id back as `data.sync_run_id` — pass it straight
to `system_gitops_get_sync_run` below. REST offers the same trigger, and is
still the only way to LIST past runs: no MCP verb enumerates them.

```bash
# Trigger + get the run id in one call (the REST twin of Step 3). Unlike the
# MCP verb, this endpoint answers 2xx for a reconcile that FAILED — branch on
# the returned run's `status`/`error_message`, not on the HTTP status — and on
# a standby control plane it creates a run and finalizes it `success` with a
# `skipped` note in `diff_summary` instead of refusing.
curl -X POST -H "Authorization: Bearer $JWT" \
  http://localhost:3000/api/v1/system/gitops_repositories/gitops-repo-1/sync_now
# → { sync_run: { id, status, error_message, ... }, ok, diff_count, proposal_ids, diff_summary }

# Or list the timeline of past runs
curl -H "Authorization: Bearer $JWT" \
  http://localhost:3000/api/v1/system/gitops_repositories/gitops-repo-1/sync_runs
# → { sync_runs: [ { id, status, error_message, diff_count, proposal_ids, ... }, ... ] }
#   newest first, 50 most recent
```

```javascript
platform.system_gitops_get_sync_run({
  sync_run_id: "<run-id>"
})
// → { sync_run: {
//      id, gitops_repository_id,
//      status,                 // running | success | failed | partial
//      started_at, completed_at, duration_seconds,
//      diff_count,
//      proposal_ids,           // ids only — fetch each proposal to see its payload
//      synced_revision,
//      diff_summary,           // per-kind counts, not a full diff
//      error_message
//    } }
```

**Expected outcome:** `diff_count` + the ids of the per-change proposals
awaiting approval. The run carries a summary, not the diff itself — read the
`Ai::AgentProposal` rows for per-change payloads, or use
`system_gitops_get_drift_report` (below) for the diff bodies.

## Step 5 — Approve the diff

Operator opens `/app/approvals` UI:

1. Reviews each proposal (PR-style summary)
2. Optionally edits parts of the plan (e.g., comments out one pool before apply)
3. Click Approve on each (or bulk-approve if `Ai::ApprovalRequest` UI supports it)

## Step 6 — Apply an approved proposal

For every applicable kind — `template`, `module`, `assignment`, `pool`,
`platform` — apply each approved proposal directly with
`system_gitops_apply_proposal`; it executes the diff against the DB:

```javascript
platform.system_gitops_apply_proposal({
  proposal_id: "prop-1"   // must be in 'approved' status with proposed_changes.source = 'gitops'
})
// → executes the create/update against the DB.
//   Errors with stale_conflict if reality drifted after the proposal was opened
//   (re-sync to regenerate a fresh proposal, then re-approve).
```

The call itself is approval-gated under the `system.gitops_apply_proposal`
autonomy category (seeded `require_approval` on the GitOps Reconciler).
When the resolved policy requires approval, the response is
`pending: true` with a `deferred_operation_id`, nothing has been written,
and the apply runs when an operator approves the request — do not retry
it. `auto_approve` and `notify_and_proceed` apply inline and answer with
the normal envelope; `block` refuses. Approving the `Ai::AgentProposal` (Step 5) says the diff is wanted;
this gate says an agent may write it.

Apply in dependency order: templates → modules → assignments → pools /
platforms (each `pool`/`platform` create resolves its `node_template` by
name, and each assignment resolves its `template` and `module`, so a
dependency applied out of order comes back as a stale conflict — re-apply
once the referenced resource exists). Individual nodes and the SDWAN
topology are never in the diff: provision those with the standard actions
(`system_create_node`, `system_sdwan_create_network`, …) outside the GitOps
loop.

**v1-conservative gap — destroy + provider_config are NOT auto-applied.**
`system_gitops_apply_proposal` supports `template` / `module` /
`assignment` / `pool` / `platform` create+update only. Resource **deletion** and
`provider_config` changes still require a deliberate manual action so a
stray `fleet.yaml` edit can never tear down fleet infrastructure
unattended:

```javascript
// Deletes proposed by the diff are review-only — remove the resource yourself:
platform.system_delete_node({ node_id: "<node-id>" })   // explicit, operator-initiated
```

You keep the audit trail + PR review benefits, and create/update converges
automatically; only destructive operations stay hands-on by design.

## Step 7 — Verify convergence

```javascript
platform.system_gitops_get_sync_run({ sync_run_id })
// → { sync_run: { status: "success", diff_count, proposal_ids, ... } }
//   "partial" means the tick hit MAX_PROPOSALS_PER_TICK, NOT that some
//   proposals are still awaiting approval — a run's status describes the
//   reconcile pass, not whether its proposals were applied.
```

The sync run does not report apply results. To confirm convergence, re-read
the drift report below: it recomputes desired-vs-live from scratch.

## Step 8 — Operate via PRs from now on

To make any fleet change:

1. Operator clones the fleet-config repo
2. Edits `fleet.yaml` (add a pool, change a template, assign a module)
3. Opens a PR
4. Team reviews; PR is approved + merged
5. Reconciler picks up the change on next tick (or manual sync)
6. Operator approves proposals in Powernode UI
7. Changes apply

## Verification

```javascript
platform.system_gitops_get_drift_report({ id: "gitops-repo-1" })
// → { repository_id, synced_revision, drift: false, diff_count: 0, diffs: [] }
//   (when reality matches git; read-only — opens no proposals)
```

`diff_count: 0` is reachable for templates (once their `node_platform_id` is
set), modules with a default `priority`, pools and platforms. The three
convergence gaps in Step 1 keep the assignment lines — and any module carrying
a `priority` or `config` — reporting drift after a successful apply; that is
an engine-side identity mismatch, not an unapplied change.

When drift exists (reality diverges from git — e.g., an operator made an
imperative change), `GitopsDriftSensor` (registered in the Fleet Autonomy
reconciler, runs every 60s) emits
<!-- signal-kind-corrections:start -->
`system.gitops.drift_detected` FleetEvents
(the kind is namespaced — filtering on a bare `gitops.drift_detected` matches
nothing; that bare form is **NOT IMPLEMENTED** and is named here only as the
mistake to avoid);
<!-- signal-kind-corrections:end -->
the operator must either commit the change back to git or reconcile it
away.

## Cleanup

```bash
# ⚠️ system_gitops_unregister_repository MCP wrapper is aspirational —
# use the REST endpoint directly:
curl -X DELETE http://localhost:3000/api/v1/system/gitops_repositories/<id> \
  -H "Authorization: Bearer $JWT"
# → repo removed from reconcile cycle; underlying git repo unaffected
```

## Troubleshooting

**`DesiredStateParser` fails with "schema validation error"** — `fleet.yaml`
doesn't match the expected schema. The error names the offending key. Read
the rules in `app/services/system/gitops/desired_state_validator.rb`
(`ALLOWED_TOP_LEVEL` + the `validate_*` methods) and the section shapes in
`app/services/system/gitops/desired_state_parser.rb`.

**Diff shows changes you didn't make** — drift between platform state and
git source-of-truth. Either:

- Commit the drift back to git (accept that imperative changes
  happened): edit `fleet.yaml` to match current state, commit, push.
- Reconcile away the drift (treat git as authoritative): approve the
  proposals that revert the imperative changes.

**Sync fails / SSH credential doesn't resolve** — the repository row carries
the latest outcome, and the sync run carries the per-run detail. Start with
the row:

```bash
curl -H "Authorization: Bearer $JWT" \
  http://localhost:3000/api/v1/system/gitops_repositories/<id>
# → { gitops_repository: { last_status: "failed", last_error: "RuntimeError: git clone failed: ...", ... },
#     recent_runs: [ ... ] }
```

`last_status`/`last_error` are written on **every** terminal path of the
reconcile — the three early returns, the success/partial tail, and the outer
`rescue` all funnel through one exit that records them — so `failed` on the
row means the most recent run failed, and a subsequent success clears
`last_error` back to null. `last_status: "pending"` now means genuinely never
run, not "failing silently". In the `partial` case `last_error` reports the
per-tick proposal cap rather than an error.

On a failure the row's `last_synced_at` / `last_synced_revision` /
`last_diff_count` are deliberately **not** overwritten — they keep describing
the last *successful* sync, so the row reads "failing now, last good was
`<sha>`".

Two notes on what the row does not cover. A **standby** control plane skips
the whole reconcile and writes nothing here, by design — the active plane owns
this row (over MCP, `system_gitops_sync_repository` refuses on standby with
`refusal_code: "standby_control_plane"` rather than reporting a skipped run as
success). And per-diff problems are not repository-level status either: a
proposal that could not be opened is only logged (on the sync run it shows up
implicitly, as `diff_count` exceeding the number of `proposal_ids`), and an
auto-apply failure is not recorded on the sync run at all — it comes back on
the sync call's own result, and on the proposal's `impact_assessment`. For the
full run history, read the runs:

```bash
curl -H "Authorization: Bearer $JWT" \
  http://localhost:3000/api/v1/system/gitops_repositories/<id>/sync_runs
# → { sync_runs: [ { status: "failed", error_message: "RuntimeError: git clone failed: ...", ... } ] }
```

> **Changed in IMP-8c1a94b8e1d6.** Before this fix the reconciler wrote
> `last_status`/`last_error` only on the success path, so a repository whose
> every run was failing kept reporting its last success — or `pending`
> forever, if it had never succeeded. Earlier revisions of this tutorial told
> you not to trust `last_error` and to read the sync run instead. That
> workaround is retired: the row is now authoritative for the latest outcome.

Two things the platform will not tell you, both worth knowing before you
read the error:

- **A Vault miss is reported as a git failure, not a Vault one.** This is the
  READ-FAILURE case specifically — an unreachable Vault, a sealed one, a path
  that does not exist, a denied policy. A path that resolves to the *wrong
  shape* is a different case and fails honestly: `require_creds!` raises
  `CredentialShapeError` naming the missing key before git runs at all.

  On a read failure, `RepoSyncService#fetch_vault_creds` rescues, logs it,
  and returns `nil`; `build_git_env` then falls through to an **anonymous**
  clone. Whatever git then says is what lands in `error_message` — for an
  `https://` remote an authentication failure, for a `git@` remote usually
  `Host key verification failed.`, because the anonymous path sets no
  `GIT_SSH_COMMAND` and git falls back to the Rails process's ambient ssh
  config. The Vault cause appears only in the log, and the two lines are at
  **different levels**, so a WARN-only or ERROR-only filter shows you half of
  it:

  ```
  WARN   [Gitops::RepoSync] Vault credential fetch failed: <reason>
  ERROR  [Gitops::RepoSync] <repository-id>: RuntimeError: git clone failed: <sanitized stderr>
  ```

  The second line reads `git fetch failed` rather than `git clone failed`
  whenever the work tree under `tmp/gitops/<account>/<repository>` already
  exists, since that path fast-forwards instead of cloning. Grep the backend
  service log for `Gitops::RepoSync` at both levels before concluding the
  deploy key is wrong.

- **Check Vault itself first — that part IS exposed.** Before suspecting the
  credential, rule out a sealed or unreachable Vault:

  ```bash
  curl -X POST -H "Authorization: Bearer $JWT" \
    http://localhost:3000/api/v1/admin_settings/vault/test
  # → { connected, sealed, initialized, version, latency_ms }
  #   or { connected: false, error: "Cannot reach Vault at <addr>" }
  ```

  `connected` is false whenever Vault is sealed, so a `sealed: true` here
  explains every credential failure at once and no per-repository digging is
  needed.

- **Then check the path, which is the other half.** A reachable, unsealed
  Vault still fails the sync if the repository points at a path that does not
  exist or holds the wrong keys. The REST read echoes the configuration back,
  so you can see what to probe without leaving the platform:

  ```bash
  curl -H "Authorization: Bearer $JWT" \
    http://localhost:3000/api/v1/system/gitops_repositories/$REPO_ID
  # → gitops_repository: { ..., vault_credential_path, required_credential_keys }
  ```

  `required_credential_keys` is derived from your remote's URL: `ssh_key` for
  `git@`/`ssh://`; `password` for an `https://` remote that already names a
  user (`https://bot@host/repo.git`); `password` **and** `username` for one
  that does not, because git then prompts for the username first and the
  askpass shim has to answer it. `[]` means an anonymous repo with no
  credential path. `null` means the opposite and is worth acting on: the
  repository HAS a credential path but its URL scheme matches neither auth
  branch, so the sync clones anonymously and ignores the path entirely.

  The `required_credential_keys` value is the same set `RepoSyncService`
  enforces — `build_git_env` passes it straight to `require_creds!` — so the
  advertised contract cannot drift from the enforced one.

  The same read is on the MCP surface (IMP-f07be27ba0b0 — before it,
  `serialize_gitops_repository`'s only call site was
  `system_gitops_register_repository`, so over MCP you saw these fields only on
  a repository you had just created yourself):

  ```javascript
  platform.system_gitops_list_repositories({})
  platform.system_gitops_get_repository({ id: "gitops-repo-1" })
  ```

  Both MCP verbs return the one projection, so the credential contract cannot
  drift between them. It is *not* byte-identical to the REST body above: the
  MCP projection omits `metadata` and `updated_at` and renders timestamps as
  ISO-8601 strings. Every field this section is about — `vault_credential_path`,
  `required_credential_keys` — is on both.

  The **probe below is REST-only, deliberately** — it is not mirrored onto MCP.
  Naming an arbitrary Vault KV path is a different exposure for an agent
  principal than for an operator in the admin UI, so the read tells you which
  path a repository uses and the probe stays a human action. Feed the two
  fields you just read into it:

  ```bash
  curl -X POST -H "Authorization: Bearer $JWT" -H 'Content-Type: application/json' \
    -d '{"path":"secret/data/powernode/gitops/fleet-deploy-key","required_keys":["ssh_key"]}' \
    http://localhost:3000/api/v1/admin_settings/vault/test
  # → { connected, sealed, ..., credential_path, path_present,
  #     credential_keys, required_keys, missing_keys, shape_ok }
  ```

  Read it as: `path_present: false` — nothing at that path. `shape_ok: false`
  with `missing_keys: ["ssh_key"]` — the path resolves but not to what this
  remote needs; `credential_keys` lists what it *does* hold. `path_present:
  null` with a `path_error` — the read itself failed (a denied policy, say),
  which is deliberately not reported as an absent path. `shape_ok: null` —
  you sent no `required_keys`, so the key names are reported but the shape was
  not judged; that is a declined verdict, not a pass. A blank value counts as
  missing, matching the sync path.

  A successful probe also invalidates that path's entry in the Vault read
  cache, so the next sync reads what the probe just saw rather than re-serving
  a stale five-minute-old hit. Probe after fixing a payload and the next sync
  agrees with you.

  Three limits worth knowing. The probe reports **key names only, never
  values** — by design, and nothing should change that. It requires
  `admin.settings.security`, not the `admin.settings.read` that the plain
  connectivity check above needs, because naming an arbitrary KV path
  discloses what lives there. And it deliberately does not participate in the
  Vault circuit breaker, so repeated probes of an unreadable path cannot trip
  Vault offline for the rest of the platform. For the values themselves, read
  out of band as
  [`../runbooks/gitops-reconciliation.md`](../runbooks/gitops-reconciliation.md)
  describes:

  ```bash
  vault kv get secret/data/powernode/gitops/fleet-deploy-key
  ```

**Module versions cannot be pinned in `fleet.yaml` yet** — the `modules`
section carries `variety`, `priority` and `config` and nothing else; there is
no version field in `DesiredStateValidator`, `DiffEngine` or `ApplyService`
(`apply_service.rb:33` books versions and `file_spec` as a later slice). A
node therefore runs whatever version is `live` for the module, which can shift
under you. Pin with `system_promote_module_version` / the module's own
promotion controls until GitOps grows the field.

**Conflicting concurrent PRs** — git's merge mechanics handle these;
resolve in PRs before they reach the reconciler. Don't let two operators
push competing fleet.yaml versions and expect the reconciler to pick
the right one.

## What's next

- **[Tutorial 11 — Multi-region federation](./11-federation.md)** — the SDWAN
  and federation topology, built with the `system_sdwan_*` actions. It is
  **not** expressible in `fleet.yaml`: there is no `sdwan` kind, so the two
  surfaces stay separate.
- **[`../runbooks/gitops-reconciliation.md`](../runbooks/gitops-reconciliation.md)** —
  operator runbook: advanced patterns and DR scenarios. Its schema section is
  older than this page (it still shows a `version:` / `account:` header and
  lists four kinds) — trust `desired_state_validator.rb` over it.
- **[`../gitops.md`](../gitops.md)** — current GitOps reconciler design reference.
- **[`SMOKE_TEST.md`](../SMOKE_TEST.md)** — once `smoke_test_gitops_reconciler.rb`
  lands, it'll exercise this flow at the platform layer.

_Last verified: 2026-08-30_
