# Disk Image CI Runbook

> Status: active

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
  - Stage 2: erofs composer (mkfs.erofs → erofs blob)
  - Stage 3: emit 6 artifact families (kernel, initramfs, raw, qcow2, ISO, iPXE) × amd64 + arm64
       │
       ▼
Cosign keyless signing (Sigstore Fulcio, ephemeral OIDC certs)
       │
       ▼
oras push to registry.example.com/<account>/disk-images/<platform>:<version>
       │
       ▼
DiskImageWebhook fires (POST /api/v1/system/webhooks/disk_image/built/<webhook_id>)
       │
       ▼
DiskImagePublicationProcessor:
  - Verify Cosign signature against NodePlatform's cosign_identity_regexp
  - Verify SHA-256 of the pulled artifact against publication.sha256
    (no server-side erofs/fs-verity verification — the erofs blob
     is produced in CI but the server trusts the cosign+sha256 envelope)
  - Create DiskImagePublication row (status=published)
       │
       ▼
Platform now serves netboot from this image for any NodeInstance
booting from this NodePlatform
```

## Phase 1 — Provision a CI worker ✅

The CI worker is a `Worker` row (role `ci_worker`) — **not** a NodeInstance. The platform mints a token for it; the operator installs and registers a Gitea Actions runner on a host of their choosing (any docker-capable Linux box; doesn't have to be a Powernode-managed node).

```javascript
platform.system_provision_ci_worker({
  name: "image-builder-1"   // operator-chosen identifier; this is the ONLY parameter
})
// → { success: true, data: { ci_worker: { id, name, roles: ["ci_worker"], status, ... },
//                            token_delivery: "...", note: "..." } }
```

Earlier doc revisions implied the action took `hostname`, `provider_region_id`, `provider_instance_type_id`, and `build_targets` and provisioned a managed NodeInstance — none of that is correct. The action is synchronous and just mints a `Worker` row.

**The MCP action does NOT return the plaintext token** (IMP-27cc7dceb97b). An MCP tool result is truncated into `ai_messages.processing_metadata` and forwarded in full to the model provider, so it is not a private channel the way an HTTP response is. Fetch the token exactly once over the operator API:

```bash
curl -X POST -H "Authorization: Bearer $OPERATOR_JWT" \
  https://<platform>/api/v1/system/ci_workers/<worker-id>/rotate_token
# → { "success": true, "data": { "ci_worker": {...}, "token_plaintext": "<shown once>", "note": "..." } }
```

That endpoint is ungated (one response, no approval) but needs the `system.ci_workers.rotate_token` permission, which `system.ci_workers.create` does not imply. The `POST /api/v1/system/ci_workers` REST create returns the token directly if you have `system.ci_workers.create` and are provisioning over HTTP rather than through an agent.

**Install + register the runner manually** (per Gitea Actions docs) using that token:

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
  workflow_file: "build-disk-image.yaml",   // workflow filename, NOT `workflow`
  ref: "v0.3.0",                            // branch/tag ref (required)
  inputs: { platform_slug: "ubuntu-2404-base", arch: "amd64" }
})
// → { run_id: "<gitea-run-id>", status: "queued" }
```

## Phase 4 — Watch the build ✅

```javascript
platform.get_gitea_workflow_run({ owner: "<account>", repo: "disk-images", run_id: "<run-id>" })
// → { status: "in_progress", started_at, jobs: [{ id, name, status, conclusion }, ...] }

// Stream a job's logs (job_id comes from the run's jobs[].id above)
platform.get_gitea_job_logs({ owner: "<account>", repo: "disk-images", job_id: "<job-id>" })
// → { logs: "..." }    // optional: tail: <N>, grep: "<regex>"
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
platform.system_terminate_ci_worker({ worker_id: "<worker-id>" })
// → { revoked: true, worker_id: "<worker-id>" }
```

This flips the `Worker` row to `status: "revoked"`, which immediately
invalidates its registration token (the digest is retained for the audit
trail but is unusable once status ≠ `active`). It does **not** create a
`System::Task`, does **not** call the Gitea API to deregister the runner,
and does **not** destroy any VM — the CI worker is a `Worker` row, not a
managed NodeInstance (see Phase 1). After revoking, **manually stop and
deregister the act_runner** on the host where you installed it (e.g.
`systemctl --user disable --now act_runner.service` + remove it from the
Gitea repo/org runner list).

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Build fails at "mmdebstrap" stage | Network issue to debian.org mirror, or out-of-disk on builder | SSH the host running the Gitea Actions runner; check disk + network. Resizing is operator-managed (the CI worker is not a managed NodeInstance — see Phase 1) |
| Build succeeds but webhook doesn't fire | `.gitea/workflows/build.yaml` last step missing or webhook secret mismatch | Verify the workflow's "Post to platform" step; rotate secret by re-running `bootstrap_disk_image_ci` with the same `label` (idempotent — rotates secrets) |
| Webhook fires but `DiskImagePublication` not created | Cosign signature verification failed | Use `platform.recent_events({ kind_prefix: "system.disk_image_publish_failed" })` to find the failure; common cause is OIDC issuer mismatch |
| Cosign signature mismatch | NodePlatform's `cosign_identity_regexp` doesn't match the CI runner's OIDC URL | Edit the NodePlatform row via the operator UI or `PATCH /api/v1/system/node_platforms/<id>` (no dedicated `system_update_node_platform` MCP wrapper); or update the CI workflow to use the right OIDC scope |
| SHA-256 mismatch on ingest | Artifact bytes differ from the digest the webhook reported (corruption in transit, or wrong digest posted) | Re-trigger the build; the publication record carries `error_message` with the expected/actual sha prefix. Re-delivering the same webhook re-verifies in place (`failed → verifying`) |
| CI worker offline | gitea-runner systemd unit failed | SSH (if SDWAN attached) → `journalctl -u gitea-runner.service`; common: token expired, network |
| Reproducibility check fails | Same source produces different output (timestamp leakage, locale, dpkg state) | Use SOURCE_DATE_EPOCH everywhere in build scripts; pin tool versions in Containerfile |
| Retention deletes still-needed image | A non-default publication aged past the retention count | Retention never purges the publication currently set as the platform default — keep the one you need promoted, or raise `disk_image_retention_count` (there is no per-publication `critical` flag) |

## How the System Concierge should use this

When an operator chats "build a new disk image" / "publish v0.3.0" / "tune image retention":

1. For first-time setup: surface `bootstrap_disk_image_ci` (one-shot — provisions the CI worker + webhook + repo secrets; **not** a build trigger)
2. For a build trigger: surface `dispatch_gitea_workflow` (owner, repo, `workflow_file`, ref, inputs) — or remind the operator a `git push` of a matching tag also triggers it
3. For status check: chain `get_gitea_workflow_run` → `system_list_disk_image_publications`
4. For retention tune: surface `system_set_disk_image_retention` (only `node_platform_id` + `retention_count`) and remind about default values
5. For decommission of a CI worker: use `request_confirmation` (destructive), then `system_terminate_ci_worker({ worker_id })`

## Related docs

- [`DISK_IMAGE_CI.md`](../DISK_IMAGE_CI.md) — architecture reference (this runbook complements it)
- [`module-authoring.md`](./module-authoring.md) — companion authoring flow for **modules** (vs disk images)
- [`../../initramfs/README.md`](../../initramfs/README.md) — local multi-arch builder for initramfs (no CI required for testing)
- [`SKILL_EXECUTORS.md`](../SKILL_EXECUTORS.md) — `cve_runbook_generate` if a published image has a CVE
- [`node-provisioning.md`](./node-provisioning.md) — NodeInstances boot from these published images

_Last verified: 2026-06-03_
