# Disk Image CI Runbook

Operator companion to [`DISK_IMAGE_CI.md`](../DISK_IMAGE_CI.md) (which covers architecture). This runbook focuses on hands-on setup, day-2 operations, and troubleshooting for the disk image CI pipeline that produces the netboot images (`kernel + initramfs + raw + qcow2 + ISO + iPXE + OCI`) that NodeInstances boot from.

**Audience:** operators bootstrapping a new platform install; SREs investigating CI failures; platform admins tuning retention.

## Pipeline at a glance

```
NodePlatform (e.g. ubuntu-24.04-amd64)
       │
       ▼
Operator: provision a CI worker NodeInstance
(provisions Gitea Actions runner with Docker socket access)
       │
       ▼
Push to platform's image-build repo (or trigger via webhook)
       │
       ▼
.gitea/workflows/build.yaml runs:
  - Stage 1: Containerfile builder (mmdebstrap → Debian rootfs)
  - Stage 2: composefs composer (mkcomposefs → fs-verity digest)
  - Stage 3: emit 6 artifact families (kernel, initramfs, raw, qcow2, ISO, iPXE) × amd64 + arm64
       │
       ▼
Cosign keyless signing (Sigstore Fulcio, ephemeral OIDC certs)
       │
       ▼
oras push to registry.example.com/<account>/disk-images/<platform>:<version>
       │
       ▼
DiskImageWebhook fires (POST /api/v1/system/webhooks/disk_image_built)
       │
       ▼
DiskImagePublicationProcessor:
  - Verify Cosign signature against NodePlatform's cosign_identity_regexp
  - Verify fs-verity digest from artifact metadata
  - Create DiskImagePublication row (status=published)
       │
       ▼
Platform now serves netboot from this image for any NodeInstance
booting from this NodePlatform
```

## Phase 1 — Provision a CI worker ✅

The CI worker is a `Worker` row (role `ci_worker`) — **not** a NodeInstance. The platform issues a registration token; the operator installs and registers a Gitea Actions runner against it on a host of their choosing (any docker-capable Linux box; doesn't have to be a Powernode-managed node).

```javascript
platform.system_provision_ci_worker({
  name: "image-builder-1"   // operator-chosen identifier; this is the ONLY parameter
})
// → { worker: { id, name, role: "ci_worker", token: "<one-time-displayed>" }, ... }
```

Earlier doc revisions implied the action took `hostname`, `provider_region_id`, `provider_instance_type_id`, and `build_targets` and provisioned a managed NodeInstance — none of that is correct. The action is synchronous and just mints a `Worker` row + token.

**Install + register the runner manually** (per Gitea Actions docs) using the returned token:

```bash
# On the operator's chosen host
mkdir -p /opt/gitea-runner && cd /opt/gitea-runner
curl -LO https://gitea.com/.../act_runner
./act_runner register --instance https://gitea.example.org --token "<the-token>" \
  --labels "amd64,arm64,disk-image-builder"
./act_runner daemon &
```

**Verify the runner is registered:**

```javascript
platform.system_list_ci_workers()
// → { workers: [{ id, name, role: "ci_worker", status: "online", ... }] }
```

For multi-arch builds, you can either use one runner with multi-arch QEMU emulation (cross-build amd64 from arm64 via binfmt) or two runners (faster but more setup). Recommend: one for low-volume; two for daily builds.

## Phase 2 — Provision the disk image webhook ✅

The webhook is how the platform learns about new published images. Webhooks are **per-pipeline** (the URL embeds the webhook UUID), not per-NodePlatform.

```javascript
platform.provision_disk_image_webhook({
  label: "ubuntu-2404-amd64-builder"
  // platform_api_base optional; defaults to POWERNODE_PUBLIC_URL
})
// → {
//     webhook_id: "<uuid>",
//     webhook_url: "https://platform.example.org/api/v1/system/webhooks/disk_image/built/<webhook_id>",
//     webhook_secret: "<one-time-displayed-secret>"
//   }
```

The action does **not** accept `node_platform_id`, `webhook_url`, or `shared_secret`: the URL is built server-side from `POWERNODE_PUBLIC_URL` + the issued webhook id, and the secret is mint-once.

Configure the returned webhook URL + secret as repository secrets in the Gitea repo's Actions settings (`POWERNODE_WEBHOOK_URL` + `POWERNODE_WEBHOOK_SECRET`). The CI workflow's last step posts to this URL on successful publication.

**Tip:** if you ran `bootstrap_disk_image_ci` above, the webhook was already provisioned + the secrets were already set in the repo. Use this standalone action only to attach additional pipelines.

**Verify the webhook is registered:**

```javascript
platform.system_list_disk_image_webhooks()
// → { webhooks: [{ id, label, last_delivery_at, ... }] }
```

## Phase 3 — Trigger a build ✅

```bash
# From a working tree of the platform's image-build repo:
git tag v0.3.0
git push origin v0.3.0
# → Gitea Actions kicks off the workflow
```

Or via the workflow-dispatch MCP action (`bootstrap_disk_image_ci` is NOT a build trigger — it's a one-shot setup action; the trigger is `dispatch_gitea_workflow`):

```javascript
platform.dispatch_gitea_workflow({
  owner: "<account>",
  repo: "disk-images",
  workflow: "build-disk-image.yml",
  ref: "v0.3.0",
  inputs: { platform_slug: "ubuntu-2404-base", arch: "amd64" }
})
// → { run_id: "<gitea-run-id>", status: "queued" }
```

## Phase 4 — Watch the build ✅

```javascript
platform.get_gitea_workflow_run({ run_id: "<run-id>" })
// → { status: "in_progress", started_at, jobs: [{ name, status, conclusion }, ...] }

// Stream job logs
platform.get_gitea_job_logs({ run_id: "<run-id>", job_name: "build-amd64" })
// → { logs: "..." }
```

A typical build takes 15–25 minutes (mmdebstrap is the slow stage; cached after first run).

## Phase 5 — Verify publication ✅

After the workflow completes successfully, the webhook fires and the platform creates a `DiskImagePublication` row:

```javascript
platform.system_list_disk_image_publications({ node_platform_id: "<platform-id>" })
// → { publications: [
//      { id, node_platform_id, status: "published", arch: "amd64", git_sha,
//        oci_ref, sha256, size_bytes, published_at, retired_at, error_message }
//    ] }
```

`status: "published"` means the publication passed cosign signature + SHA256 verification. The publication's status enum is `queued/awaiting_upload/verifying/published/failed/retired/purged`. NodeInstances booting from this `NodePlatform` will use this image on next netboot. (Earlier doc revisions referenced `version`, `composefs_digest`, and `signed_at` fields — those don't exist on the row today; composefs verification is a future addition.)

**Promote the publication as the "default" for new instances:**

```javascript
platform.system_set_default_disk_image_publication({
  node_platform_id: "<platform-id>",
  publication_id: "<pub-id>"
})
```

### Rollback to a previous publication

If a newly-promoted publication regresses, swap the default back to a
prior known-good publication using the same action — pass the previous
`publication_id`:

```javascript
platform.system_set_default_disk_image_publication({
  node_platform_id: "<platform-id>",
  publication_id: "<previous-pub-id>"
})
```

For the agent-driven path (sensor `system.disk_image_regression_reported`
→ approval-gated rollback), see [`DISK_IMAGE_MANAGER_AGENT.md` →
Rollback / Revert Workflow](../DISK_IMAGE_MANAGER_AGENT.md#rollback--revert-workflow).

## Phase 6 — Retention tuning ✅

Retention is **count-based**, not time-based. The `NodePlatform.disk_image_retention_count` column controls how many publications are kept per platform (default: 3). The `DiskImageRetentionService` runs daily (Sidekiq cron) and prunes publications past the count, with a fixed 7-day grace window (`DiskImageRetentionService::DEFAULT_GRACE_DAYS`) before the OCI blob is purged from the registry.

```javascript
platform.system_set_disk_image_retention({
  node_platform_id: "<platform-id>",
  retention_count: 5      // keep the 5 most recent publications
})
```

The action accepts only `retention_count` — there is no `routine_days` / `critical_days` / publication-criticality framing today. Pruning is conservative: never deletes the publication currently set as default for a NodePlatform.

## Phase 7 — Decommission a CI worker ⚠️

```javascript
platform.system_terminate_ci_worker({ id: "<worker-id>" })
// → { task_id, status: "terminating" }
```

Triggers:
- Gitea API call to deregister the runner
- Cancel any in-flight jobs (operator gets notification)
- Standard NodeInstance termination cascade (provider VM destroyed, etc.)

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Build fails at "mmdebstrap" stage | Network issue to debian.org mirror, or out-of-disk on builder | SSH the host running the Gitea Actions runner; check disk + network. Resizing is operator-managed (the CI worker is not a managed NodeInstance — see Phase 1) |
| Build succeeds but webhook doesn't fire | `.gitea/workflows/build.yaml` last step missing or webhook secret mismatch | Verify the workflow's "Post to platform" step; rotate secret by re-running `bootstrap_disk_image_ci` with the same `label` (idempotent — rotates secrets) |
| Webhook fires but `DiskImagePublication` not created | Cosign signature verification failed | Use `platform.recent_events({ kind_prefix: "system.disk_image_publish_failed" })` to find the failure; common cause is OIDC issuer mismatch |
| Cosign signature mismatch | NodePlatform's `cosign_identity_regexp` doesn't match the CI runner's OIDC URL | Edit the NodePlatform row via the operator UI or `PATCH /api/v1/system/node_platforms/<id>` (no dedicated `system_update_node_platform` MCP wrapper yet); or update the CI workflow to use the right OIDC scope |
| fs-verity digest mismatch | Artifact corrupted in transit (rare; oras has retry built-in) | Re-trigger the build; the deduper detects identical artifacts and skips redundant ingestion |
| CI worker offline | gitea-runner systemd unit failed | SSH (if SDWAN attached) → `journalctl -u gitea-runner.service`; common: token expired, network |
| Reproducibility check fails | Same source produces different output (timestamp leakage, locale, dpkg state) | Use SOURCE_DATE_EPOCH everywhere in build scripts; pin tool versions in Containerfile |
| Retention deletes still-needed image | Was set as default after retention threshold passed | Mark `critical: true` on important publications; or extend retention window |

## How the System Concierge should use this

When an operator chats "build a new disk image" / "publish v0.3.0" / "tune image retention":

1. For build trigger: surface `bootstrap_disk_image_ci` with required inputs
2. For status check: chain `get_gitea_workflow_run` → `system_list_disk_image_publications`
3. For retention tune: surface `system_set_disk_image_retention` and remind about default values
4. For decommission of CI worker: use `request_confirmation` (destructive)

## Related docs

- [`DISK_IMAGE_CI.md`](../DISK_IMAGE_CI.md) — architecture reference (this runbook complements it)
- [`runbooks/module-authoring.md`](./module-authoring.md) — companion authoring flow for **modules** (vs disk images)
- [`initramfs/README.md`](../../initramfs/README.md) — local multi-arch builder for initramfs (no CI required for testing)
- [`SKILL_EXECUTORS.md`](../SKILL_EXECUTORS.md) — `cve_runbook_generate` if a published image has a CVE
- [`runbooks/node-provisioning.md`](./node-provisioning.md) — NodeInstances boot from these published images
