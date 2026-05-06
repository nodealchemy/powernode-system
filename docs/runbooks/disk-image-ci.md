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

The platform-managed CI worker is itself a NodeInstance with the `gitea-runner` module assigned, plus elevated Docker socket access for building images.

```javascript
platform.system_provision_ci_worker({
  hostname: "image-builder-1",
  provider_region_id: "region-aws-us-east-1",
  provider_instance_type_id: "type-c5-2xlarge",      // beefier for builds
  build_targets: ["amd64", "arm64"]                   // arch labels for Gitea Actions
})
// → { instance: {...}, runner_token: "...", registration_url: "..." }
```

The worker's `gitea-runner` module reads the token from systemd environment, registers with `registry.example.com`, and starts polling for jobs.

**Verify:**

```javascript
platform.system_list_ci_workers()
// → { workers: [{ id, status: "online", labels: ["amd64", "arm64", "docker"], ... }] }
```

For multi-arch builds, you can either:
- One worker with multi-arch QEMU emulation (cross-build amd64 from arm64 via binfmt)
- Two workers, one per arch (faster but more cost)

Recommend: one worker with QEMU for low-volume; two workers for daily builds.

## Phase 2 — Provision the disk image webhook ✅

The webhook is how the platform learns about new published images.

```javascript
platform.provision_disk_image_webhook({
  node_platform_id: "<platform-id>",
  webhook_url: "https://platform.ipnode.org/api/v1/system/webhooks/disk_image_built",
  shared_secret: "..."                                // generated; rotate via this same call
})
// → { webhook: { id, secret_fingerprint, ... } }
```

Configure the same webhook URL + secret in the Gitea repo's webhook settings. The CI workflow's last step posts to this webhook on successful publication.

**Verify the webhook is registered:**

```javascript
platform.system_list_disk_image_webhooks({ node_platform_id: "<platform-id>" })
```

## Phase 3 — Trigger a build ✅

```bash
# From a working tree of the platform's image-build repo:
git tag v0.3.0
git push origin v0.3.0
# → Gitea Actions kicks off the workflow
```

Or via the dispatcher MCP action:

```javascript
platform.bootstrap_disk_image_ci({
  node_platform_id: "<platform-id>",
  ref: "v0.3.0",                                       // git ref to build from
  arches: ["amd64", "arm64"]
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
//      { id, version: "v0.3.0", status: "published", composefs_digest, signed_at, ... }
//    ] }
```

`status: "published"` means the publication passed all verification checks (Cosign signature, fs-verity, manifest integrity). NodeInstances booting from this `NodePlatform` will use this image on next netboot.

**Promote the publication as the "default" for new instances:**

```javascript
platform.system_set_default_disk_image_publication({
  node_platform_id: "<platform-id>",
  publication_id: "<pub-id>"
})
```

## Phase 6 — Retention tuning ✅

Default retention: 90 days for routine publications, 365 days for any publication marked `critical: true`. Operators tune via the platform configuration:

```javascript
platform.system_set_disk_image_retention({
  node_platform_id: "<platform-id>",
  routine_days: 60,
  critical_days: 730                                   // 2 years
})
```

The `DiskImageRetentionService` runs daily (Sidekiq cron) and prunes old publications + their OCI artifacts. Pruning is conservative — never deletes a publication currently set as default for a NodePlatform.

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
| Build fails at "mmdebstrap" stage | Network issue to debian.org mirror, or out-of-disk on builder | Check `system_get_instance_stats` on the CI worker; resize via `provider_instance_type_id` change |
| Build succeeds but webhook doesn't fire | `.gitea/workflows/build.yaml` last step missing or shared_secret mismatch | Verify the workflow's "Post to platform" step; rotate secret via `provision_disk_image_webhook` |
| Webhook fires but `DiskImagePublication` not created | Cosign signature verification failed | Check `recent_events` for `disk_image_publication_failed` with reason; usually OIDC issuer mismatch |
| Cosign signature mismatch | NodePlatform's `cosign_identity_regexp` doesn't match the CI runner's OIDC URL | Update via `system_update_node_platform`; or update the CI workflow to use the right OIDC scope |
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
