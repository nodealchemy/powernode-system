# Module Authoring Runbook

Quick-start for authoring, signing, publishing, and assigning a new `NodeModule`. Covers `manifest.yaml` schema, `package_spec` / `file_spec` / `protected_spec` semantics, Containerfile patterns, two-stage CI pipeline, and Cosign keyless signing.

**Audience:** module authors (internal + external open-source contributors), template designers composing fleet-wide assignments.

## Concept reference

| Concept | What it is | Backing model |
|---|---|---|
| **NodeModule** | A reusable userspace component (e.g., nginx, k3s-server). Has a category + variety. | `NodeModule` |
| **NodeModuleCategory** | Ordered grouping (network=60, container runtimes=70, userland=90+) | `NodeModuleCategory` |
| **Module variety** | `subscription` (always-on) / `config` (overrides another module's config) / `instance` (per-instance customization) | enum on `NodeModule` |
| **NodeModuleVersion** | A specific build of a module. Lifecycle: `draft → staging → blessed → live → archived` | `NodeModuleVersion` |
| **manifest.yaml** | Authoring-time spec describing module identity + composition rules | YAML at the root of module-repo |
| **package_spec** | Debian packages installed via `mmdebstrap` in the Containerfile builder stage | YAML field |
| **file_spec** | rsync-glob patterns determining which files from the rootfs/ tree end up in the module artifact | YAML field |
| **protected_spec** | Files this module owns — overrides from higher-priority modules are forbidden | YAML field |
| **dependency_spec** | Other modules this one requires (resolved by `DependencyResolutionService`) | YAML field |
| **Containerfile** | Dockerfile-style recipe for the module's builder image (used by Gitea Actions to produce the rootfs) | Dockerfile syntax |
| **composefs digest** | fs-verity hash committed to the OCI artifact; agent verifies before mounting | sha256 |

## Phase 1 — Set up the module repo ✅

The canonical layout lives at [`templates/module-repo/`](../../templates/module-repo/) — copy it as a starting point:

```
my-module/
├── manifest.yaml                  # the spec (this runbook focuses on it)
├── Containerfile                  # builder image (mmdebstrap → rootfs)
├── rootfs/                        # files copied into the module artifact
│   └── etc/
│       └── nginx/
│           └── nginx.conf
└── .gitea/
    └── workflows/
        └── build.yaml             # two-stage CI: builder → composer
```

Create a Gitea repository under `registry.example.com/<account>/modules/my-module` (private by default; public is allowed for community modules). Push the skeleton.

## Phase 2 — Author manifest.yaml ✅

Minimum viable manifest:

```yaml
schema_version: 1

identity:
  name: my-nginx
  category: userland                # references NodeModuleCategory.slug
  variety: subscription             # subscription | config | instance
  description: nginx 1.26 with TLS hardening + /healthz endpoint

  # Cosign trust pin: the platform rejects artifacts not signed by these
  cosign_identity_regexp: '^https://registry.example.com/<account>/modules/my-nginx@.*$'
  cosign_issuer_regexp:   '^https://gitea\.ipnode\.org$'

# Packages installed in the Containerfile builder stage via mmdebstrap.
# These end up in /var/lib/dpkg/status of the resulting rootfs.
package_spec:
  - nginx
  - nginx-extras

# Which files from rootfs/ to include in the artifact. rsync-glob syntax.
file_spec:
  include:
    - "/etc/nginx/**"
    - "/var/www/healthz/**"
  exclude:
    - "/etc/nginx/sites-enabled/default"   # don't ship the default vhost

# Files this module owns — higher-priority modules cannot override these.
# Protects against composition footguns.
protected_spec:
  - "/etc/nginx/conf.d/00-security.conf"

# Other modules required for this one to function. Resolved transitively.
dependency_spec:
  - name: system-base               # foundational (always-required)
  - name: security-hardening        # reasonable default
    optional: false
  - name: chrony                    # NTP for cert validation
    optional: true                  # used if present, not required
```

**Field semantics:**

- `identity.name` — globally unique within the account; the platform appends a hash to disambiguate across accounts.
- `identity.category` — must match a seeded `NodeModuleCategory` slug. Default seeded: `system-base`, `network-overlay`, `container-runtimes`, `security-hardening`, `userland`. Position determines composition layer order (lower → mounted earlier).
- `identity.variety`:
  - `subscription` — turn it on; always present once assigned. Examples: nginx, k3s-server.
  - `config` — modifies another module's config without rebuilding it. Examples: `daemon-json-override` for slice 10.
  - `instance` — per-NodeInstance customization (different host name, different TLS cert). Higher `effective_priority` than `subscription`.
- `package_spec` — apt packages installed in the Containerfile builder. Applied via mmdebstrap to the rootfs.
- `file_spec.include` / `exclude` — rsync-glob patterns. Globs are evaluated relative to the `rootfs/` directory in your repo.
- `protected_spec` — files this module owns. The composition layer rejects assignments that try to override these from a higher-priority module unless the override module sets `mask: true` (carve-out).
- `dependency_spec` — modules pulled in transitively by `DependencyResolutionService`. Use `optional: true` for soft dependencies.

## Phase 3 — Author Containerfile + rootfs ✅

The Containerfile produces the *builder* image — the stage that runs mmdebstrap, drops files into a clean rootfs, and emits the module artifact.

```dockerfile
# templates/module-repo/Containerfile
FROM ghcr.io/powernode/module-builder:latest AS builder

WORKDIR /work

# Copy your manifest and rootfs tree
COPY manifest.yaml ./
COPY rootfs/ ./rootfs/

# The base image's entrypoint reads manifest.yaml and:
#   1. Runs mmdebstrap with package_spec → /work/build/rootfs/
#   2. rsync-copies your rootfs/ tree on top per file_spec rules
#   3. mksquashfs → composefs digest
#   4. Emits the artifact at /work/dist/module.tar
ENTRYPOINT ["/usr/local/bin/build-module"]
```

The base image `ghcr.io/powernode/module-builder` provides a hermetic build environment with mmdebstrap, mksquashfs, mkcomposefs, and `cosign`. Don't deviate from it unless you need a custom debian release.

**rootfs/ tree:**

```
rootfs/
└── etc/
    └── nginx/
        ├── conf.d/
        │   ├── 00-security.conf      # in protected_spec — owned by this module
        │   └── 10-app.conf           # composable; lower-priority modules can override
        └── nginx.conf
```

The platform's authority on file paths trumps your repo: if a higher-priority module owns `/etc/nginx/nginx.conf` via its `protected_spec`, your `file_spec` for it is silently dropped during composition.

## Phase 4 — Local test (dry-run build) ✅

Test the manifest locally before pushing:

```bash
# From your module-repo working tree
docker run --rm \
  -v $PWD:/work:ro \
  -v $PWD/dist:/work/dist \
  ghcr.io/powernode/module-builder:latest \
  --dry-run

# → outputs:
#   /work/dist/manifest.json     (parsed manifest)
#   /work/dist/file-list.txt     (files that would be included)
#   /work/dist/package-list.txt  (packages that would be installed)
```

**Verify against the platform's compatibility check** (no upload):

```javascript
platform.system_validate_module_manifest({
  manifest_yaml: "<contents of manifest.yaml>",
  category_slug: "userland"
})
// → { valid: true, warnings: [...], conflicts: [...] }
```

This catches `protected_spec` collisions with existing modules in your account before you push.

## Phase 5 — Push to Gitea + CI build ✅

Push your repo. The `.gitea/workflows/build.yaml` triggers on push:

```yaml
# Two-stage build pipeline
on: [push]

jobs:
  build:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
      - name: Build module artifact
        run: |
          docker build -t module-builder:${{ github.sha }} .
          docker run --rm -v $PWD/dist:/work/dist module-builder:${{ github.sha }}

      - name: Push to OCI registry
        run: |
          oras push registry.example.com/<account>/modules/my-nginx:${{ github.sha }} \
            ./dist/module.tar:application/vnd.powernode.module.v1+tar

      - name: Sign with Cosign (keyless)
        run: |
          cosign sign --yes registry.example.com/<account>/modules/my-nginx:${{ github.sha }}
        env:
          COSIGN_EXPERIMENTAL: 1
```

**What happens behind the scenes:**

1. **Builder stage**: mmdebstrap installs packages from `package_spec` into a clean Debian rootfs
2. **Composer stage**: rsync applies your `rootfs/` tree per `file_spec` rules; mkcomposefs computes the fs-verity digest
3. **Artifact emission**: tar of the composefs lower layer + manifest.json (parsed) + composefs digest
4. **OCI push**: `oras` uploads the artifact to `registry.example.com`
5. **Cosign signing**: keyless signing via Sigstore Fulcio (no long-lived signing keys; ephemeral OIDC-bound certs tied to the Gitea Actions OIDC issuer)

The platform's `ModuleOciIngestService` polls the registry; when a new tag appears with a valid Cosign signature matching the manifest's `cosign_identity_regexp`, it creates a `NodeModuleVersion` row in `lifecycle_state: draft`.

## Phase 6 — Verify publication ✅

```javascript
platform.system_list_module_versions({ module_name: "my-nginx" })
// → { versions: [{ id, version_string, lifecycle_state: "draft", composefs_digest, ... }] }
```

Promote through the lifecycle:

```javascript
// draft → staging (visible to operators; can be assigned to test instances)
platform.system_promote_module_version({ id: "<version-id>", to: "staging" })

// staging → blessed (passes operator review)
platform.system_promote_module_version({ id: "<version-id>", to: "blessed" })

// blessed → live (rolls out fleet-wide; gated by require_approval policy)
platform.system_promote_module_version({ id: "<version-id>", to: "live" })
```

The `module_promotion_sensor` warns if a version has been in `staging` more than 24 h without operator action.

## Phase 7 — Assign to a Template ✅

Templates compose modules into reusable bundles:

```javascript
platform.system_assign_module_to_template({
  template_id: "<template-id>",
  module_name: "my-nginx",
  // Optional metadata available to the agent at boot:
  metadata: {
    "purpose": "edge-cdn-tokyo"
  }
})
// → { assignment: { id, template_id, module_id, priority, ... } }
```

Priorities are determined by the module's category position + variety. To override (e.g., for a per-node config module that should win over a base subscription module):

```javascript
// ⚠️ aspirational MCP — use REST today: PATCH /api/v1/system/node_module_assignments/<id>
platform.system_update_module_assignment({
  id: "<assignment-id>",
  effective_priority: 95               // higher than userland (90)
})
```

Once assigned, every NodeInstance built from this template will pull the module on its next reconcile tick. Use `system_drift_report` to verify.

## Common manifest patterns

### Override a base module's config (variety: config)

```yaml
identity:
  name: nginx-tokyo-config
  variety: config
  parent_module: my-nginx              # the module being overridden

# This module *only* contributes file_spec — no packages, no composefs lower
file_spec:
  include:
    - "/etc/nginx/conf.d/99-tokyo.conf"
```

### Per-instance customization (variety: instance)

```yaml
identity:
  name: hostname-override
  variety: instance

# Templates evaluated per-NodeInstance with metadata bindings
file_spec:
  include:
    - "/etc/hostname"
    - "/etc/hosts"

# The module-builder substitutes ${instance.hostname} from NodeInstance metadata
```

### Mask a parent module's protected file (carve-out)

```yaml
identity:
  name: chrony-no-pool
  variety: config
  parent_module: chrony

file_spec:
  include:
    - "/etc/chrony/chrony.conf"
  mask:
    - "/etc/chrony/chrony.conf"        # carve out parent's protected_spec ownership
```

The `mask` directive is a deliberate escape hatch — use sparingly; it inverts the safety guarantee of `protected_spec`.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `ModuleManifestSchemaError` on push | YAML doesn't match schema_version | Run `platform.system_validate_module_manifest` locally first |
| Cosign signature rejected | `cosign_identity_regexp` doesn't match the OIDC issuer | Verify the Gitea Actions OIDC URL matches your regexp |
| Module shows in registry but no `NodeModuleVersion` row | OCI ingest hasn't run yet | Wait 60 s for the next ingest poll; check `journalctl -u powernode-worker@default \| grep ModuleOciIngest` |
| `protected_spec` collision on assignment | Another module owns one of your protected files | Rename your file or use `mask` in a `config`-variety override |
| Assignment to template succeeds but agent doesn't pull | Module is `draft` lifecycle_state — agents only pull `blessed`+ | Promote: `system_promote_module_version` |
| fs-verity digest mismatch on agent | Module artifact corrupted during transit | Re-run CI build; the platform re-ingests on next OCI poll |

## How the System Concierge should use this

When an operator chats "I need a new module for X" / "compose a template for nginx + TLS":

1. Use `module_compose` skill — keyword-matches existing modules + drafts a Template
2. If a custom module is needed, surface this runbook + the `templates/module-repo/` skeleton
3. For assignment workflows, use `system_assign_module_to_template` with `request_confirmation`

## Related docs

- [`templates/module-repo/README.md`](../../templates/module-repo/README.md) — skeleton this runbook expands on
- [`templates/example-modules/`](../../templates/example-modules/) — 7 working examples (nginx, apache, chrony, security-hardening, system-base, rpi4-firmware)
- [`USE_CASE_MATRIX.md`](../USE_CASE_MATRIX.md) — composition use cases (long-lived edge, multi-tenant, per-tenant config)
- [`SKILL_EXECUTORS.md`](../SKILL_EXECUTORS.md) — `module_compose` skill for AI-assisted composition
- [`runbooks/cve-response.md`](./cve-response.md) — module updates triggered by CVE response
- [`DISK_IMAGE_CI.md`](../DISK_IMAGE_CI.md) — companion pipeline for base disk images (vs. modules)
