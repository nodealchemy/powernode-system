# Example 10 — GitOps-managed fleet via fleet.yaml (M-D2-3, in active sweep)

End-to-end walkthrough: declare a fleet's desired state in `fleet.yaml`, commit to git, observe the GitOps reconciler diff against current state, approve the diff, apply. **Markdown-only example** — gated on M-D2-3 polish which is in active sweep as of 2026-05-04 per `docs/TASKS.md`.

**Status:** ◐ Prototype — desired-state parser + diff engine implemented; reconciler partially wired; approval flow + UI in active sweep.

**Goal:** demonstrate declarative fleet management with git as the source of truth, replacing imperative MCP calls.

**Audience:** SREs adopting GitOps, multi-engineer teams needing PR-based change control on fleet config.

## When this works (and doesn't)

| Capability | Status |
|---|---|
| Parse `fleet.yaml` from a git repo | ✅ Works (`DesiredStateParser`) |
| Compute diff against current platform state | ✅ Works (`DiffEngine`) |
| Sync desired state via the reconciler | ◐ Partial (`GitopsReconciler` — operator approval flow incomplete) |
| Auto-apply approved diffs | ❌ Not yet (M-D2-3 finalization pending) |
| Drift detection (alert when reality drifts from git) | ❌ Not yet |
| Multi-account / multi-environment GitOps | ❌ Not yet |

For now, GitOps is best treated as **read-and-diff** — the source-of-truth comparison is useful for audit + PR review even before full apply.

## Prerequisites

- A Gitea repo (or any git remote) for the fleet config
- Operator with `system.gitops.read` + `system.gitops.write` permissions
- A running Powernode platform with at least one Account configured

## Step 1 — Author `fleet.yaml`

```yaml
# fleet.yaml
version: 1
account: "<account-id>"

templates:
  - name: edge-base
    node_platform: ubuntu-24.04-amd64
    architecture: amd64
    modules:
      - system-base
      - security-hardening
      - chrony

  - name: edge-cdn
    extends: edge-base
    modules:
      - nginx               # adds to inherited
    metadata:
      purpose: "edge-cdn"

nodes:
  - hostname: edge-tokyo-01
    template: edge-cdn
    region: ap-tokyo-1
    instance_type: t3-medium
    lifecycle_class: persistent

  - hostname: edge-tokyo-02
    template: edge-cdn
    region: ap-tokyo-1
    instance_type: t3-medium
    lifecycle_class: persistent

  - hostname: edge-london-01
    template: edge-cdn
    region: eu-west-2
    instance_type: t3-medium
    lifecycle_class: persistent

sdwan:
  networks:
    - name: edge-fabric
      routing_mode: ibgp
      peers:
        - host: edge-tokyo-01
          publicly_reachable: true
        - host: edge-tokyo-02
        - host: edge-london-01
          publicly_reachable: true
      virtual_ips:
        - name: cdn-frontend
          primary_holder: edge-tokyo-01
          failover_holders: [edge-tokyo-02, edge-london-01]
```

## Step 2 — Register the GitOps repo

```javascript
platform.create_gitea_repository({                      // standard MCP tool
  owner: "<account>",
  repo: "fleet-config",
  private: true
})

// Push fleet.yaml to the repo via git
```

```javascript
platform.system_gitops_register_repository({          // ⚠️ skill-level MCP gap
  repo_url: "git@git.ipnode.org:<account>/fleet-config.git",
  branch: "main",
  ssh_credential_id: "<vault-cred-id>",
  reconcile_interval_seconds: 300                     // optional; default 60s
})
// → { repository: { id: "gitops-repo-1", status: "syncing", ... } }
```

## Step 3 — Trigger a sync

```javascript
platform.system_gitops_sync_repository({              // ⚠️ aspirational
  repository_id: "gitops-repo-1"
})
// → { sync_run: { id, status: "in_progress", ... } }
```

The reconciler:
1. Pulls latest from `main`
2. Parses `fleet.yaml` via `DesiredStateParser`
3. Loads current platform state (templates + nodes + sdwan)
4. Runs `DiffEngine` to compute the delta
5. Returns diff via `system_gitops_get_sync_run`

## Step 4 — Review the diff

```javascript
platform.system_gitops_get_sync_run({                 // ⚠️ aspirational
  sync_run_id: "<run-id>"
})
// → {
//      diff: {
//        templates: { add: ["edge-cdn"], update: [], delete: [] },
//        nodes:     { add: ["edge-tokyo-01", "edge-tokyo-02", "edge-london-01"], update: [], delete: [] },
//        sdwan: {
//          networks:    { add: ["edge-fabric"], ... },
//          peers:       { add: [...] },
//          virtual_ips: { add: ["cdn-frontend"] }
//        }
//      },
//      requires_approval: true,
//      approval_request_id: "<id>"
//    }
```

## Step 5 — Approve the diff

Per Fleet Autonomy intervention policy, GitOps applies are `require_approval`. Operator opens the approval UI:

1. Reviews the diff (PR-style summary)
2. Optionally edits parts of the plan (e.g., comments out one node before apply)
3. Click **Approve**

The reconciler executes the approved actions in dependency order:
- Templates first (referenced by nodes)
- Nodes + provision_instances next
- SDWAN networks before peer attaches
- VIPs after peers exist

## Step 6 — Verify convergence

```javascript
platform.system_gitops_get_sync_run({ sync_run_id })
// → {
//      status: "applied",
//      applied_actions: [...],
//      failed_actions: [],
//      drift_after_apply: { /* should be empty */ }
//    }
```

Subsequent reconcile ticks (every 5 min by default) verify no drift; alerts if reality diverges from git.

## Step 7 — Operate via PRs from now on

To make changes:

1. Operator clones the fleet-config repo
2. Edits `fleet.yaml` (e.g., adds a new node)
3. Opens a PR
4. Team reviews; PR is approved + merged
5. Reconciler picks up the change on next tick; produces a diff; awaits operator approval in Powernode UI
6. Operator approves; changes apply

## What to watch

- **Drift between git and reality** is expected during transitions; the reconciler surfaces it as a warning. Investigate via `system_gitops_get_drift_report`.
- **Conflicts when multiple operators edit `fleet.yaml`** — git's merge mechanics handle these; resolve in PRs before they reach the reconciler
- **Module versions** in `fleet.yaml` should pin to specific lifecycle states (`blessed`, `live`) to prevent surprise upgrades when a new version lands
- **Until M-D2-3 ships:** GitOps is read-only — diff is useful for audit but apply must be done via standard MCP actions

## Related

- [`gitops.md`](../gitops.md) — GitOps reconciler design (in sweep)
- [`runbooks/`](../runbooks/) — runbooks for individual operations the GitOps reconciler eventually composes
- `extensions/system/server/app/services/system/gitops/` — DesiredStateParser, DiffEngine, GitopsReconciler sources
- `docs/TASKS.md` — M-D2-3 tracking
