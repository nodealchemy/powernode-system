# Powernode Module — Template Repo

This directory is the canonical layout for a Powernode module source repository.
Fork it (or use `pnmod init` once the SDK ships in M-MK-1) to create a new module.

## Structure

```
.
├── Containerfile              # Stage 1 builder — installs package_spec + copies rootfs/
├── manifest.yaml              # Authoring-time hints (name, license, security policy, etc.)
├── rootfs/                    # Files shipped verbatim into the module's filesystem
│   └── .gitkeep
├── .gitea/workflows/build.yaml  # Two-stage CI (builder + composer)
└── README.md
```

## Lifecycle

1. **Author:** edit `Containerfile`, `manifest.yaml`, and add files under `rootfs/`.
2. **Register:** in the Powernode UI, create a `NodeModule` and set `gitea_repo_full_name` to this repo's path. Generate + paste a `webhook_secret`. Configure the secret in this repo's settings as `POWERNODE_WEBHOOK_SECRET` (Actions secret) so the workflow can sign back.
3. **Build:** push a tag (`v1.0.0`) OR trigger via Powernode (which dispatches workflow_dispatch with `rsync_spec` + `package_spec` + `fingerprint`).
4. **Sign + push:** the workflow builds, runs syft (SBOM) + grype (VEX), composefs-encodes, fs-verity-hashes, cosign-signs (Sigstore keyless), and pushes the artifact to the configured OCI registry.
5. **Ingest:** the workflow's final step posts back to Powernode's `/api/v1/system/webhooks/gitea/module`, which triggers `ModuleOciIngestService`. A new `NodeModuleVersion` + per-arch `ModuleArtifact` rows land in the database.

## Module spec authority

The four glob-spec fields (`mask`, `file_spec`, `package_spec`, `dependency_spec`)
on the **`System::NodeModule` record in the platform** are authoritative for builds.
The `manifest.yaml` is consulted only on first-import to seed those fields; once
they're set in the platform, edit them via the UI / API and dispatch a new build.

The platform computes the **effective** rsync_spec at dispatch time, accounting
for higher-priority neighbor modules' file_spec carve-outs (this is why the same
module can deploy slightly different content depending on what other modules
sit beside it in a particular template's union mount).

## Required Gitea Actions secrets

| Secret | Purpose |
|---|---|
| `GITEA_PUSH_USERNAME` | OCI registry login |
| `GITEA_PUSH_TOKEN` | OCI registry token (write to `packages` scope) |
| `POWERNODE_WEBHOOK_SECRET` | HMAC secret matching `NodeModule.webhook_secret` |

## Required Gitea Actions vars

| Var | Default | Purpose |
|---|---|---|
| `POWERNODE_OCI_REGISTRY` | `registry.example.com` | Where to push the artifact |
| `POWERNODE_WEBHOOK_URL` | `https://platform.example.com/api/v1/system/webhooks/gitea/module` | Where to notify on build completion |

## Multi-arch builds

The matrix in `build.yaml` builds for both `amd64` and `arm64` on appropriate
runners. Self-hosted Gitea runners must be labeled `ubuntu-24.04` and
`ubuntu-24.04-arm` respectively. Single-arch repos can drop the matrix entry.

## Reproducible builds

The `Containerfile` pins `UBUNTU_DIGEST` to a specific Ubuntu 24.04 LTS image
digest, and `APT_SNAPSHOT` to a specific snapshot.ubuntu.com timestamp. Two
builds of the same source MUST produce identical `oci_digest` and
`fsverity_root_hash` — that's the SLSA Build Level 3+ contract Powernode requires.

Refresh both pins periodically (Renovate is configured to track ubuntu:24.04).

## Reference

- Plan: `~/.claude/plans/we-are-working-on-golden-eclipse.md` (M1 supply chain)
- Platform models: `extensions/system/server/app/models/system/node_module.rb`
- Build dispatch: `extensions/system/server/app/services/system/module_build_dispatch_service.rb`
- Webhook ingest: `extensions/system/server/app/controllers/api/v1/system/webhooks/gitea_module_controller.rb`
