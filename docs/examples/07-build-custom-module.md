# Example 07 — Build a custom module from scratch

End-to-end walkthrough: author + register + sign + publish + assign a custom NodeModule. Companion seed: `db/seeds/example_custom_module.rb` (Phase 3).

**Goal:** demonstrate the full module supply chain — from blank git repo to assigned-to-Template — with concrete commands.

**Audience:** module authors, platform contributors, external developers consuming the system extension.

**Prerequisites:**
- Gitea account at `git.ipnode.org` with permission to create repos under your account
- `docker` + `oras` + `cosign` CLI installed locally
- A NodePlatform you'll assign the module to (e.g., ubuntu-24.04-amd64)

## Step 1 — Clone the canonical template

```bash
git clone git@git.ipnode.org:powernode/templates/module-repo.git my-redis-module
cd my-redis-module
rm -rf .git
git init
git remote add origin git@git.ipnode.org:<account>/modules/my-redis-module.git
```

## Step 2 — Edit `manifest.yaml`

```yaml
schema_version: 1

identity:
  name: my-redis
  category: userland
  variety: subscription
  description: Redis 7.4 with TLS + persistence
  cosign_identity_regexp: '^https://git\.ipnode\.org/<account>/modules/my-redis-module@.*$'
  cosign_issuer_regexp:   '^https://gitea\.ipnode\.org$'

package_spec:
  - redis-server
  - redis-tools

file_spec:
  include:
    - "/etc/redis/**"
    - "/var/lib/redis/.gitkeep"
  exclude:
    - "/etc/redis/sentinel.conf"

protected_spec:
  - "/etc/redis/redis.conf"          # this module owns the main config

dependency_spec:
  - name: system-base
  - name: security-hardening
```

## Step 3 — Add the rootfs tree

```bash
mkdir -p rootfs/etc/redis rootfs/var/lib/redis
touch rootfs/var/lib/redis/.gitkeep   # keeps the empty data dir in the artifact
```

```ini
# rootfs/etc/redis/redis.conf
bind 0.0.0.0 ::
port 6379
protected-mode yes
tls-port 6380
tls-cert-file /etc/redis/tls/server.crt
tls-key-file  /etc/redis/tls/server.key
tls-ca-cert-file /etc/redis/tls/ca.crt
appendonly yes
dir /var/lib/redis
```

## Step 4 — Validate the manifest locally

```javascript
platform.system_validate_module_manifest({          // ⚠️ aspirational — see project_system_mcp_gaps
  manifest_yaml: <contents of manifest.yaml>,
  category_slug: "userland"
})
// → { valid: true, warnings: [], conflicts: [] }
```

> **Note:** until `system_validate_module_manifest` ships, run a local syntax check via the builder image:
> ```bash
> docker run --rm -v $PWD:/work:ro ghcr.io/powernode/module-builder:latest --dry-run
> ```

## Step 5 — Push to Gitea

```bash
git add manifest.yaml Containerfile rootfs/ .gitea/
git commit -m "feat: my-redis module v0.1.0"
git tag v0.1.0
git push origin develop --tags
```

The `.gitea/workflows/build.yaml` triggers on tag push. Watch progress:

```javascript
platform.list_gitea_workflow_runs({ owner: "<account>", repo: "modules/my-redis-module" })
// → { runs: [{ id, status: "in_progress", ... }] }
```

## Step 6 — Wait for CI + signing

The workflow:
1. Runs the builder image with `manifest.yaml` + `rootfs/` → emits artifact tar at `dist/module.tar`
2. Pushes to OCI: `oras push git.ipnode.org/<account>/modules/my-redis-module:v0.1.0 ./dist/module.tar:application/vnd.powernode.module.v1+tar`
3. Signs with Cosign (keyless via Sigstore Fulcio): `cosign sign --yes <artifact-ref>`

After the workflow completes (~5 min), the platform's `ModuleOciIngestService` polls the registry and creates a `NodeModuleVersion` row in `lifecycle_state: draft`.

## Step 7 — Verify ingestion

```javascript
platform.system_list_module_versions({ module_name: "my-redis" })
// → { versions: [{
//      id: "v-redis-0.1.0",
//      version_string: "0.1.0",
//      lifecycle_state: "draft",
//      composefs_digest: "sha256:abc...",
//      ...
//    }] }
```

## Step 8 — Promote through lifecycle

```javascript
platform.system_promote_module_version({ id: "v-redis-0.1.0", to: "staging" })
// Test on a non-prod NodeInstance...

platform.system_promote_module_version({ id: "v-redis-0.1.0", to: "blessed" })
// Operator review passed; module is recommendable

platform.system_promote_module_version({ id: "v-redis-0.1.0", to: "live" })
// Now eligible for fleet-wide rollout
```

## Step 9 — Assign to a Template

```javascript
platform.system_assign_module_to_template({
  template_id: "<your-template>",
  module_name: "my-redis"
})
// → assignment created; instances built from this template will get my-redis on next reconcile
```

## Step 10 — Verify on a running instance

```javascript
platform.system_get_instance({ id: "<instance-from-the-template>" })
// → { instance: {
//      running_module_digests: { "my-redis": "sha256:abc...", ... },
//      ...
//    }}

platform.system_drift_report({ instance_id: "<id>" })
// → { drift: false }
```

SSH (or `system_execute_task`) to the instance:

```bash
systemctl status redis-server.service
# → active (running)

redis-cli ping
# → PONG
```

## What to watch

- **Cosign identity regex must match the OIDC issuer** of your Gitea Actions runs — if the regex doesn't match, ingestion rejects the artifact
- **`protected_spec` collisions** — if a higher-priority module owns `/etc/redis/redis.conf`, your file_spec is silently dropped during composition. Use `mask` in a config-variety override module if you need to carve out.
- **Module-Builder image version drift** — pin to a specific tag (`module-builder:1.2.0`) in your Containerfile for reproducibility
- **Promotion to `live` is `require_approval`** in many setups — check `module_promote_to_live` intervention policy

## Related

- [`runbooks/module-authoring.md`](../runbooks/module-authoring.md) — full reference for manifest fields + variety types
- [`templates/module-repo/`](../../templates/module-repo/) — canonical layout this example clones from
- [`templates/example-modules/`](../../templates/example-modules/) — 7 working examples (nginx, apache, chrony, security-hardening, system-base, rpi4-firmware)
- [`DISK_IMAGE_CI.md`](../DISK_IMAGE_CI.md) — companion pipeline for base disk images (different from modules)
