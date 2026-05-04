# Disk Image CI/CD — Operator Guide

End-to-end disk image build pipeline: NodePlatform → Gitea Actions → OCI ingest → publication. Uses the platform's GitOps + CI worker infrastructure with Cosign signing for supply-chain integrity.

## Architecture (one-paragraph summary)

A `System::NodePlatform` carries a `build_script` that produces a disk image (kernel + initramfs + composefs blob). The build runs on a self-hosted Gitea Actions runner (provisioned via `provision_ci_worker`) triggered by a webhook. After build, the runner pushes the artifact as an OCI blob (Cosign-signed via the platform's keyless identity), POSTs the webhook back to platform, which ingests via `DiskImagePublicationProcessor`. The resulting `DiskImagePublication` row links the OCI digest to the platform record + retention policy.

## End-to-End Flow

```
Operator                         Gitea Runner               Platform
───────                          ────────────               ────────
   │                                  │                          │
   │ 1. Trigger build                 │                          │
   │    (push to repo or              │                          │
   │     dispatch_gitea_workflow)     │                          │
   ├────────────────────────────────► │                          │
   │                                  │ 2. Run build_script:     │
   │                                  │    apt-mirror, kernel,   │
   │                                  │    composefs blob,       │
   │                                  │    initramfs, signed     │
   │                                  │    OCI artifact          │
   │                                  │                          │
   │                                  │ 3. POST webhook with     │
   │                                  │    OCI digest + SBOM     │
   │                                  ├─────────────────────────►│
   │                                  │                          │ 4. DiskImageWebhook
   │                                  │                          │    receives request,
   │                                  │                          │    validates signature
   │                                  │                          │
   │                                  │                          │ 5. DiskImagePublicationProcessor
   │                                  │                          │    fetches OCI manifest,
   │                                  │                          │    runs Cosign verify
   │                                  │                          │
   │                                  │                          │ 6. Creates
   │                                  │                          │    DiskImagePublication
   │                                  │                          │    + updates NodePlatform
   │                                  │                          │    .disk_image_oci_ref
   │                                  │                          │
   │                                  │                          │ 7. Retention service
   │                                  │                          │    prunes images beyond
   │                                  │                          │    retention_count
   │                                  │                          │
   │ 8. Provision NodeInstance from   │                          │
   │    Template — agent fetches      │                          │
   │    OCI artifact, boots from it   │                          │
   ◄──────────────────────────────────┴──────────────────────────┤
```

## Setup: Initial CI Worker + Webhook

### Step 1: Bootstrap the CI worker for an account

```javascript
platform.bootstrap_disk_image_ci({
  account_id: "<account>",
  // Provisions a Gitea Actions runner registered to the account's
  // disk-image build repo, with appropriate secrets (Cosign keys,
  // OCI registry credentials)
})
```

This creates:
- A `System::Task` of type `ci_worker_provision`
- A self-hosted Gitea Actions runner labeled `disk-image-builder`
- Repository secrets for Cosign + OCI registry auth (rotated independently)

### Step 2: Provision the build webhook

```javascript
platform.provision_disk_image_webhook({
  node_platform_id: "<platform-id>"
})
```

Returns:
```json
{
  "webhook_url": "https://platform.powernode.org/api/v1/system/webhooks/disk_image_built",
  "webhook_secret": "shared-secret-for-HMAC-signing"
}
```

Operator configures this webhook URL + secret in the build repo's CI workflow YAML so the runner can call back after a successful build.

## Operator Workflow

### Triggering a build

```javascript
// Direct dispatch
platform.dispatch_gitea_workflow({
  account_id: "<account>",
  repo: "<account>/disk-images",
  workflow: "build-disk-image.yml",
  inputs: { platform_slug: "ubuntu-2404-base" }
})

// Or via git push to the configured branch
```

### Monitoring a build

```javascript
// List recent runs
platform.list_gitea_workflow_runs({
  account_id: "<account>",
  repo: "<account>/disk-images"
})

// Tail a specific job's logs
platform.get_gitea_job_logs({ run_id: "<run-id>", job_id: "<job-id>" })
```

### Inspecting publications

```bash
# Via REST
curl /api/v1/system/disk_image_publications -H "Authorization: Bearer $JWT"

# Per-platform recent publications
curl "/api/v1/system/node_platforms/<id>/disk_image_publications" \
  -H "Authorization: Bearer $JWT"
```

Each publication carries:
- `oci_ref` — fully-qualified registry path (e.g. `git.ipnode.org/account/disk-images@sha256:...`)
- `git_sha` — source commit
- `built_at` — timestamp
- `cosign_identity` — who signed (Gitea Actions OIDC identity)
- `sbom_url` — SBOM artifact URL
- `size_bytes`, `sha256` — artifact integrity

### Promoting a publication

The latest publication is auto-promoted to `current` for its NodePlatform when ingest succeeds. To roll back:

```javascript
platform.system_revert_disk_image({
  node_platform_id: "<id>",
  to_publication_id: "<earlier-publication-id>"
})
```

The next NodeInstance provisioned from a Template using this Platform will fetch the rolled-back image.

## Retention Policy

`NodePlatform.disk_image_retention_count` (default: 3) controls how many publications are kept per platform. The `DiskImageRetentionService` (runs via Sidekiq cron) prunes older publications past the count, removing both the DB row + the OCI blob from the registry.

To change retention:

```bash
# Via API
curl -X PATCH /api/v1/system/node_platforms/<id> \
  -H "Authorization: Bearer $JWT" \
  -d '{"disk_image_retention_count": 5}'
```

## Secret Rotation

Three secret types in this pipeline:

1. **Cosign keyless identity** — Gitea Actions OIDC; rotates per-run automatically. No operator action.
2. **OCI registry credentials** — used by Gitea runner to push artifacts. Stored as Gitea Actions secret. Rotate via:
   ```javascript
   platform.set_gitea_action_secret({
     account_id: "<account>",
     repo: "<repo>",
     name: "OCI_REGISTRY_TOKEN",
     value: "<new-token>"
   })
   ```
3. **Webhook signing secret** — HMAC-shared between platform + build script. Rotate via `provision_disk_image_webhook` (issues a new pair; operator updates the runner's env).

## Troubleshooting

### Build succeeds but publication doesn't appear

The webhook didn't reach the platform (firewall? wrong URL?) or HMAC signature mismatch. Check:

```bash
# Last webhook attempts
curl /api/v1/system/disk_image_webhooks/recent -H "Authorization: Bearer $JWT"
```

If signature mismatched, rotate the webhook secret.

### Cosign verification fails

`DiskImagePublicationProcessor` rejects ingests where Cosign verify fails. Likely causes:
- Build runner used a different Cosign identity than the platform's `cosign_identity_regexp` config on `NodePlatform`
- OCI artifact was tampered post-signing

Inspect:
```bash
curl /api/v1/system/disk_image_publications/<id> -H "Authorization: Bearer $JWT"
# Look for publication_status="cosign_verify_failed" + publication_error
```

### Runner stuck in pending

Gitea Actions runner provisioned but not online. Check:

```javascript
platform.system_list_tasks({ task_type: "ci_worker_provision", status: "pending" })
```

Reprovision if necessary:
```javascript
platform.bootstrap_disk_image_ci({ account_id: "<account>", force: true })
```

## Source Files

**Models:**
- `extensions/system/server/app/models/system/disk_image_webhook.rb`
- `extensions/system/server/app/models/system/disk_image_publication.rb`

**Services:**
- `extensions/system/server/app/services/system/disk_image_publication_processor.rb` — webhook → ingest
- `extensions/system/server/app/services/system/disk_image_oci_ingest_service.rb` — OCI manifest fetch + Cosign verify
- `extensions/system/server/app/services/system/disk_image_direct_upload_ingest_service.rb` — fallback for non-CI uploads
- `extensions/system/server/app/services/system/disk_image_retention_service.rb` — prune past retention count

**Controllers:**
- `extensions/system/server/app/controllers/api/v1/system/disk_image_publications_controller.rb`
- `extensions/system/server/app/controllers/api/v1/system/disk_image_webhooks_controller.rb`
- `extensions/system/server/app/controllers/api/v1/system/webhooks/disk_image_built_controller.rb` — receives Gitea webhook
- `extensions/system/server/app/controllers/api/v1/system/worker_api/disk_image_publications_controller.rb` — runner-facing

**MCP tools:**
- `server/app/services/ai/tools/disk_image_operator_tool.rb` — `bootstrap_disk_image_ci`, `provision_disk_image_webhook`, `provision_ci_worker`
- `server/app/services/ai/tools/gitea_actions_tool.rb` — secrets, workflow dispatch, run monitoring

## Related Docs

- `extensions/system/initramfs/README.md` — multi-arch boot artifact build details
- `docs/system/threat-model.md` — supply-chain integrity rationale
- `extensions/system/docs/ARCHITECTURE.md` — disk image pipeline subsystem
