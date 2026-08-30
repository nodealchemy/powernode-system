# Module Authoring Runbook

> Status: active

Quick-start for authoring, signing, publishing, and assigning a new `NodeModule`. Covers `manifest.yaml` schema, `package_spec` / `file_spec` / `protected_spec` semantics, Containerfile patterns, two-stage CI pipeline, and Cosign static-key signing (Gitea Actions isn't on Sigstore Fulcio's trusted-issuer list, so keyless signing never verifies server-side — see Phase 5).

**Audience:** module authors (internal + external open-source contributors), template designers composing fleet-wide assignments.

## Phase 0 — Should this be a module at all?

Added 2026-07-28 after a proposal to split five new modules out of `dev-cell`
was cut to one. Module sprawl is a real cost: every module is a manifest, a
build arm, a publish, a template assignment, a version to bump, and another
entry in every composing node's LKG manifest. Answer this BEFORE Phase 1.

**First, check whether the capability already exists.** Search the catalog by
PURPOSE, not by guessed name — the MCP actions `system_discover_modules` and
`system_discover_templates` rank existing modules/templates by semantic
similarity to a free-text intent ("reverse proxy with TLS", "metrics
scraper"):

```
system_discover_modules   intent="reverse proxy terminating TLS"
system_discover_templates intent="public web serving stack"
```

Read the `coverage` field in the response before trusting an empty result. It
reports how much of the searched catalog actually carries an embedding; if
`unembedded` is non-zero, an empty result means **not indexed**, not "nothing
exists" — run `rails system:catalog:backfill_embeddings` (and
`rails system:catalog:embedding_coverage` to confirm) before concluding the
capability is missing. Ranking is vector-only with no keyword fallback, so an
unavailable embedding provider fails loudly rather than returning noise.

**A new module must satisfy at least one of:**

- **R1 — Two or more real consumers today**, or a hard
  `requires: capability:<name>` edge from another module's manifest. "Assumed
  co-assigned on the same template" prose does NOT count: the resolver cannot
  enforce it, so it protects nothing.
- **R2 — An independent third-party payload with its own version/CVE cadence.**
  The per-module CVE remediation pipeline (`package_module_refresh`,
  `rolling_module_upgrade`) operates per module, so a vendored upstream binary
  needs its own boundary to be CVE-bumped without dragging an unrelated module's
  churn. This is why traefik, gitleaks, act_runner and Chrome are separate.
- **R3 — An opt-in heavy payload a node type must be able to EXCLUDE**
  (`dev-cell-browser`, `dev-cell-docker`).

**This gate is machine-enforced over MCP (IMP-a67be4fe9041, 2026-08-21.)** It used to be
prose only, which meant an agent authoring a module read past it. `system_create_module`
(and `system_update_module` on the bare-create-then-update path) now REFUSE a
`manifest_yaml` that would add a new name to the build planner's buildable set unless the
call carries a `reuse_check`:

```
reuse_check: {
  considered: [ { module: "traefik", rejected_because: "terminates TLS, does not scrape" } ],
  justification: "R2",
  justification_detail: "vendored upstream binary with its own CVE cadence"
}
```

`justification` must be `R1`, `R2` or `R3`; `justification_detail` must be non-blank; every
`considered[].module` is looked up in the same buildable set that defines novelty, so an
invented candidate refuses the call by name. The accepted declaration is persisted to
`node_module.config["reuse_check"]` with a `checked_at` stamp. A bare-field create (no
manifest) and a re-import onto an already-buildable module (a CVE version bump) are not
gated — neither is authoring.

**The gate has a precondition of its own (IMP-45bda04c6123, 2026-08-25).** A `reuse_check`
summarises a survey, and a survey is only worth anything if it could have found something.
`system_discover_modules` ranks over embeddings, so a buildable module is **searchable**
only when it is enabled AND carries an embedding AND that embedding is not stale (the row
has not been edited since the vector was generated). The gate measures that directly:

- **Zero searchable modules ⇒ REFUSED.** The survey could not have returned a candidate for
  any intent, so "no existing module covers this" is the absence of a finding, not a
  finding. The refusal names `rake system:catalog:backfill_embeddings`. This is the state
  the live catalog was actually in on 2026-08-25: 42 buildable modules, 0 embeddings, and
  every reuse check since had cleared vacuously.
- **Partial coverage ⇒ ALLOWED, but disclosed.** The response carries a `reuse_survey`
  block naming how many buildable modules the survey could not see. It is not refused:
  nothing embeds a module on save today, so every module authored lands unsearchable, and
  refusing on any gap would demand a backfill between any two authorings.
- **An empty catalog is not an unsearchable one** — the first module in an account is
  authorable with `considered: []`, exactly as before.
- **Escape hatch.** If the embedding provider is unreachable and the module must be
  authored anyway, pass `reuse_check.unindexed_catalog_ack: "<why>"` — a non-blank
  **string**, not a flag. The module is then recorded as carrying an explicitly UNVERIFIED
  reuse check.

The accepted declaration is persisted with a `catalog_coverage` stamp
(`{total, embedded, searchable}`) alongside `checked_at`, and both are read back on
`system_get_module` under `reuse_check` — so an auditor can later tell a real survey from a
blind one, which is precisely what the un-stamped record could not express.

The gate covers the **MCP authoring surface only**. The REST `import_manifest` endpoint,
the CI publish path, and `rails db:seed` call `System::ManifestImportService` directly and
are deliberately ungated: those are the human/committed paths, and Phase 0 above is the
gate for them. This is a sprawl gate, not a security boundary.

**Otherwise, bake it into the owning node-type module's own build arm and
file_spec.** Four of the five candidates in that review failed all three prongs
and stayed in `dev-cell`; `runtime-go` passed on R2 alone (Go ships security
releases roughly monthly, while dev-cell's scripts churn constantly — baked in,
every script tweak would re-ship a ~150MB-heavier blob and every Go CVE would
ride dev-cell's release treadmill).

Note that "it completes a family" is the WEAKEST justification — a family label
can rationalise any new member. `runtime-*` is demand-driven and should stay
that way: a language runtime earns a module only when the distro package cannot
satisfy the floor (ruby 3.2.8, node 24, go 1.25 all can't), never by analogy.

**Where functionality belongs, once you have decided it is not its own module:**

| Kind | Home |
|---|---|
| Fleet-wide generic mechanism | `base-os-*` (model: the ssh-hostkeys generalisation) |
| Per-node-type policy | the node-type module — **never** base-os |
| Per-instance data | never in any blob: identity envelope / fw_cfg / `/persist` |

That last row is an invariant, not a preference: a non-instance/node-specific
module must not contain instance/node-specific files, and no instance-specific
file belongs in a base-os build.

## Concept reference

| Concept | What it is | Backing model |
|---|---|---|
| **NodeModule** | A reusable userspace component (e.g., nginx, k3s-server). Has a category + variety. | `NodeModule` |
| **NodeModuleCategory** | Ordered grouping (network=60, container runtimes=70, userland=90+). A platform-side DB row, **not** a manifest key — see note below. | `NodeModuleCategory` |
| **Module variety** | `subscription` (always-on) / `config` (overrides another module's config) / `instance` (per-instance customization) | enum on `NodeModule` |
| **NodeModuleVersion** | A specific build of a module. State column is `promotion_state`: `built → staging → blessed → live`, with `retired` as the terminal/rollback state | `NodeModuleVersion` |
| **manifest.yaml** | Authoring-time spec describing module identity + composition rules | YAML at the root of module-repo |
| **package_spec** | Debian packages installed into the module's rootfs by the builder stage (`mmdebstrap` for platform modules, apt in the Containerfile for third-party repos) | YAML field |
| **file_spec** | rsync-glob patterns determining which files from the rootfs/ tree end up in the module artifact | YAML field |
| **protected_spec** | Files this module owns — overrides from higher-priority modules are forbidden | YAML field |
| **dependency_spec** | Other modules this one requires (resolved by `DependencyResolutionService`) | YAML field |
| **Containerfile** | Dockerfile-style recipe for the module's builder image (used by Gitea Actions to produce the rootfs) | Dockerfile syntax |
| **erofs digest** | fs-verity hash committed to the OCI artifact; agent verifies before mounting | sha256 |

## Phase 1 — Set up the module repo ✅

The canonical layout lives at [`templates/module-repo/`](../../templates/module-repo/) — copy it as a starting point:

```
my-module/
├── manifest.yaml                  # the spec (this runbook focuses on it)
├── Containerfile                  # builder image, third-party path (apt → rootfs)
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

# Identity — flat top-level keys (no `identity:` wrapper).
name: my-nginx
display_name: "nginx 1.26 with TLS hardening"
description: "nginx 1.26 with TLS hardening + /healthz endpoint"
license: "BSD-2-Clause"

# Packages installed into the rootfs by the builder stage (mmdebstrap).
# These end up in /var/lib/dpkg/status of the resulting rootfs.
package_spec:
  - nginx
  - nginx-extras

# Paths this module OWNS in the artifact (rsync-include, flat glob list).
file_spec:
  - "/etc/nginx/**"
  - "/var/www/healthz/**"

# Paths to EXCLUDE from this module's blob (rsync-style mask, local-only).
mask:
  - "/etc/nginx/sites-enabled/default"   # don't ship the default vhost

# Files this module owns — no neighbor may ship these. Folded into every
# neighbor's effective_mask in both priority directions.
protected_spec:
  - "/etc/nginx/conf.d/00-security.conf"

# Other modules this one requires/provides. Resolved transitively by
# DependencyResolutionService. Two `requires` forms — see below.
dependencies:
  requires:
    - "powernode/system-base@^1.0"      # name pin
    - "powernode/security-hardening@^1.0"
    - "powernode/chrony@^1.0"           # NTP for cert validation
    - "capability:database.postgres@>= 16"  # capability requirement
  provides:
    - "http-server"
    - "http-server@1.26"                # versioned — see below
```

### The two `requires` forms

**Name pin** — `<owner>/<module>@<constraint>`, or a bare module name. Binds to one
specific module by its Gitea repo (`gitea_repo_full_name`) or name. The constraint is
recorded on the dependency edge but is **not** enforced: the platform has no module
semver to check it against (`NodeModuleVersion#version_number` is an integer counter,
not a semver string). That is why every pin in this repo is the conventional `@^1.0`.

**Capability requirement** — `capability:<tag>[@<constraint>]`. Says *what you need*
rather than *who provides it*: the importer picks the highest-priority module on the
account whose `provides` advertises `<tag>`. Any future module providing that tag
satisfies the requirement, with no manifest edit here.

```yaml
requires:
  - "capability:os.userland"               # any provider of the tag
  - "capability:database.postgres@>= 16"   # provider must advertise a satisfying version
```

Rules worth knowing before you write one:

- **The constraint is `Gem::Requirement` syntax** — `>= 16`, `~> 1.0`, `1.0`. The npm
  caret form (`^16`) is **not** valid here, even though name pins use it by convention.
  A malformed constraint is now rejected at import with a manifest error; it is also
  rejected at PR time by [`module-validate.yaml`](../../.gitea/workflows/module-validate.yaml)
  against [`module-manifest.schema.json`](../../modules/.schema/module-manifest.schema.json).
  (Historically it was silently reported to the operator as a *missing provider*,
  which sent people off to author a module that already existed.)
- **A bare `provides` tag does not satisfy a versioned requirement.** If you want to
  answer `capability:http-server@>= 1.26`, advertise `http-server@1.26`, not
  `http-server`. This is deliberate: it forces providers to state their version rather
  than being matched optimistically.
- **Unsatisfied capabilities are not a build failure.** The import defers them, and
  `CapabilityGapSensor` reports the standing gap to the operator each tick. It clears
  itself when a provider publishes.
- **Drift is advisory.** The constraint is matched once at import; if the provider is
  later re-imported at a version that no longer satisfies it,
  `DependencyResolutionService` emits a `:constraint_drift` warning but still resolves
  the module into the closure.

**Field semantics:**

- `name` — globally unique within the account (platform appends a hash to disambiguate across accounts). The manifest's `name` is the stable identifier; downstream tooling looks up the `NodeModule` row by it.
- `package_spec` — apt packages installed by the builder stage. Applied via mmdebstrap to the platform rootfs (Phase 5 Stage 1).
- `file_spec` — **flat array of rsync-style glob strings** identifying paths this module owns. The artifact ships these.
- `mask` — paths to EXCLUDE from this module's blob at build time. Local-only — does NOT affect neighbor modules' blobs.
- `protected_spec` — files this module owns that NO neighbor module may ship. The build pipeline folds these into every neighbor's effective_mask in both priority directions, so a sensitive lower-module file (e.g. `/etc/shadow` from system-base) cannot be overridden by a service module's overlay layer.
- `dependencies.requires` — modules pulled in transitively. Either a name pin (`<owner>/<module>@<version-constraint>`) or a capability requirement (`capability:<tag>[@<constraint>]`) — see [The two `requires` forms](#the-two-requires-forms) above.
- `dependencies.provides` — capability tags this module advertises, bare (`http-server`) or versioned (`http-server@1.26`). Denormalized into the `capabilities` column at import so capability requirements can be resolved without scanning every manifest. Only the versioned form can satisfy a versioned requirement.

**Important — these are NOT in the manifest:** `category`, `variety`, `cosign_identity_regexp`, `cosign_issuer_regexp` live on the platform-side `NodeModule` DB row (set at registration time via the operator UI at `/app/system/modules/new`, or as the `category_id:` argument to `system_create_module_from_package`). They are not validated by the manifest schema. The `NodeModuleCategory` a module belongs to is a **platform-side DB row** selected at registration — the seeded slugs (`system-base`, `network-overlay`, `container-runtimes`, `security-hardening`, `userland`) are operator-facing taxonomy on that row, never a manifest field. `variety` accepts `subscription` (turn it on; always present once assigned — e.g. nginx, k3s-server), `config` (modifies another module's config without rebuilding it — e.g. `daemon-json-override` for slice 10), or `instance` (per-NodeInstance customisation — higher `effective_priority` than `subscription`).

For the authoritative shape see `extensions/system/templates/module-repo/manifest.yaml` and `extensions/system/modules/.schema/module-manifest.schema.json`. The [`MODULE_MANIFEST_COMPLETE_SCHEMA.md`](../MODULE_MANIFEST_COMPLETE_SCHEMA.md) doc (in the parent `docs/` directory) is the operator-facing prose reference.

## Phase 3 — Author Containerfile + rootfs ✅

The Containerfile produces the *builder* image for the **third-party per-repo build** (`templates/module-repo/.gitea/workflows/build.yaml`): it installs `package_spec` with apt and layers your `rootfs/` on top. The composer stage then carves the module out of that image. (Platform modules under `modules/*/` take a different Stage 1 — see Phase 5.)

```dockerfile
# templates/module-repo/Containerfile
ARG UBUNTU_DIGEST=sha256:cdb5fd928fced577cfecf12c8966e830fcdf42ee481fb0b91904eeddc2fe5eff
FROM docker.io/library/ubuntu@${UBUNTU_DIGEST}

# Packages from the dispatched package_spec — the composer stage writes the
# spec to /workspace/package_spec.txt before invoking the build.
COPY package_spec.txt /tmp/package_spec.txt
RUN xargs -a /tmp/package_spec.txt apt-get install -y --no-install-recommends

# Your rootfs/ tree lands at the filesystem ROOT, on top of the package
# install — this is how a module overrides its package's defaults.
COPY rootfs/ /
```

The base is `docker.io/library/ubuntu` pinned to an immutable **digest**, not a floating tag (SLSA L3+ reproducibility); override with `--build-arg UBUNTU_DIGEST=sha256:...` to rebuild against an older base. There is no entrypoint and no artifact emitted here: the builder image *is* the input to the composer stage, which rsyncs out only what `file_spec` matches.

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

## Phase 4 — Local test (manifest validation) ✅

There is no local build dry-run — the two-stage mmdebstrap → `mkfs.erofs`
pipeline (Phase 5) only runs in Gitea Actions. (An earlier local `--dry-run`
flow against a published builder image was described here and has been
retired; no such image is built or published by this pipeline.) Two real
local/pre-push checks exist instead:

**Schema-validate against the JSON schema** (works before the module is even
registered — no `NodeModule` row required):

```bash
# From your module-repo working tree
yq -o=json '.' manifest.yaml > /tmp/manifest.json
npx --yes ajv-cli@5 validate \
  -s <path-to-checkout>/modules/.schema/module-manifest.schema.json \
  -d /tmp/manifest.json \
  --spec=draft2020 --all-errors
```

This is exactly what [`module-validate.yaml`](../../.gitea/workflows/module-validate.yaml)
runs at PR time — running it locally first just fails faster. Catches typos
(`fil_spec:` vs `file_spec:`), missing required fields, bad enum values, and
malformed `capability:<tag>[@<constraint>]` constraints.

**Verify against the platform's compatibility check** (no upload, but
requires an *existing* `NodeModule` — register the module first via the
operator UI at `/app/system/modules/new` or `system_create_module_from_package`,
then use this to validate subsequent manifest revisions against it):

```javascript
platform.system_validate_module_manifest({
  module_id: "<existing NodeModule id — manifest name must match its name>",
  manifest_yaml: "<contents of manifest.yaml>"
})
// → { valid: true, validation_errors: [] } | { valid: false, error: "...", validation_errors: [...] }
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
          # Canonical workflow bootstraps a rootfs directly, not docker build.
          # See templates/module-repo/.gitea/workflows/build.yaml for the
          # authoritative two-stage pipeline (rootfs bootstrap → rsync filter →
          # mkfs.erofs → fs-verity → syft + grype → cosign sign → oras push).
          bash scripts/module-build/stage1-rootfs.sh --module my-nginx
          # ... composer stage runs mkfs.erofs + emits the artifact bundle ...

      - name: Push to OCI registry
        run: |
          oras push registry.example.com/<account>/modules/my-nginx:${{ github.sha }} \
            ./dist/module.tar:application/vnd.powernode.module.v1+tar

      - name: Sign with Cosign (static key)
        run: |
          cosign sign --key env://COSIGN_PRIVATE_KEY --yes registry.example.com/<account>/modules/my-nginx:${{ github.sha }}
        env:
          COSIGN_PRIVATE_KEY: ${{ secrets.POWERNODE_COSIGN_PRIVATE_KEY }}
```

**Do not copy the workflow inline** — use the canonical version at [`templates/module-repo/.gitea/workflows/build.yaml`](../../templates/module-repo/.gitea/workflows/build.yaml). The example above sketches the shape; the canonical workflow handles the full two-stage build, SBOM/VEX generation, in-toto provenance attestations, and OCI referrers. Diverging from the canonical workflow risks composing modules that the platform's `ModuleOciIngestService` rejects.

**What happens behind the scenes:**

1. **Builder stage**: mmdebstrap installs packages from `package_spec` into a clean Debian rootfs
2. **Composer stage**: rsync applies your `rootfs/` tree per `file_spec` rules; mkfs.erofs computes the fs-verity digest
3. **Artifact emission**: tar of the erofs lower layer + manifest.json (parsed) + erofs digest
4. **OCI push**: `oras` uploads the artifact to `registry.example.com`
5. **Cosign signing**: static-key signing — Gitea Actions isn't on Sigstore Fulcio's trusted-issuer list, so keyless certs would never verify server-side. The `assemble` job signs with `POWERNODE_COSIGN_PRIVATE_KEY`, a Gitea Actions secret you add to your repo (ask your platform operator for the value — it's the private half of the platform's `POWERNODE_COSIGN_PUBLIC_KEY`). Keyless/Fulcio signing only applies to modules actually built on a Fulcio-trusted CI (e.g. GitHub Actions), not this Gitea template.

The platform's `ModuleOciIngestService` polls the registry; when a new tag appears with a valid Cosign signature, it creates a `NodeModuleVersion` row in `promotion_state: built`. By default that means `cosign verify` against the platform's static `POWERNODE_COSIGN_PUBLIC_KEY`; the `NodeModule`'s `cosign_identity_regexp` / `cosign_issuer_regexp` (set on the DB row, not the manifest) only come into play on the keyless fallback path, for modules signed by a genuinely Fulcio-trusted issuer.

## Phase 6 — Verify publication ✅

```javascript
platform.system_list_module_versions({ module_name: "my-nginx" })
// → { versions: [{ id, version_string, promotion_state: "built", composefs_digest, ... }] }
```

The column is `promotion_state` (not `lifecycle_state`); valid states are `built, staging, blessed, live, retired`. `built` is the freshly-ingested state; promote through `staging → blessed → live`, demote/rollback to `retired`. Promotion advances that ladder and at most one timestamp column; it does not change which version the fleet serves.

Promote through the lifecycle:

```javascript
// built → staging (visible to operators; can be assigned to test instances)
platform.system_promote_module_version({ id: "<version-id>", to: "staging" })

// staging → blessed (passes operator review)
platform.system_promote_module_version({ id: "<version-id>", to: "blessed" })

// blessed → live (the last ladder rung; gated by require_approval policy).
// This does NOT roll the version out — use system_rollback_module_version to
// repoint current_version_id, or a rolling_module_upgrade for a batched rollout.
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

Priorities are determined by the module's category position + variety. The `system_update_module_assignment` MCP action toggles an assignment's `enabled` state, but not its priority — to override `effective_priority` (e.g., for a per-node config module that should win over a base subscription module), edit the assignment over REST:

```bash
# Bump effective_priority above userland (90) so a per-node config wins.
PATCH /api/v1/system/node_module_assignments/<assignment-id>
{ "effective_priority": 95 }
```

To change *which* modules a template carries, use the assign/unassign MCP actions (`system_assign_module_to_template` / `system_unassign_module_from_template`) rather than an update call.

Once assigned, every NodeInstance built from this template will pull the module on its next reconcile tick. Use `system_drift_report` to verify.

## Common manifest patterns

### Override a base module's config (variety: config)

`variety` and `parent_module` are **platform-side `NodeModule` fields**, not
manifest keys — set them when you register the module (UI or
`system_create_module_from_package`). The manifest itself stays flat and only
contributes the override file:

```yaml
schema_version: 1
name: nginx-tokyo-config
display_name: "nginx Tokyo overrides"

# This module *only* contributes file_spec — no packages, no erofs lower.
file_spec:
  - "/etc/nginx/conf.d/99-tokyo.conf"
```

### Per-instance customization (variety: instance)

Register this module with `variety: instance` on its platform-side row (higher
`effective_priority` than a `subscription` module). The manifest stays flat:

```yaml
schema_version: 1
name: hostname-override
display_name: "Per-instance hostname"

# Templates evaluated per-NodeInstance with metadata bindings.
file_spec:
  - "/etc/hostname"
  - "/etc/hosts"

# The module-builder substitutes ${instance.hostname} from NodeInstance metadata.
```

### Mask a parent module's protected file (carve-out)

Register with `variety: config` + `parent_module: chrony` on the platform-side
row. `file_spec` and `mask` are flat top-level arrays in the manifest:

```yaml
schema_version: 1
name: chrony-no-pool
display_name: "chrony without pool directives"

file_spec:
  - "/etc/chrony/chrony.conf"
mask:
  - "/etc/chrony/chrony.conf"          # carve out parent's protected_spec ownership
```

The `mask` directive is a deliberate escape hatch — use sparingly; it inverts the safety guarantee of `protected_spec`.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `ModuleManifestSchemaError` on push | YAML doesn't match schema_version | Run `platform.system_validate_module_manifest` locally first |
| Cosign signature rejected | Static-key mismatch (default path) — repo's `POWERNODE_COSIGN_PRIVATE_KEY` doesn't correspond to the platform's `POWERNODE_COSIGN_PUBLIC_KEY`; only the keyless fallback checks `cosign_identity_regexp`/`cosign_issuer_regexp` | Confirm the repo's cosign key secret with your platform operator; for the keyless fallback, verify the signing CI's OIDC issuer matches your regexp |
| Module shows in registry but no `NodeModuleVersion` row | OCI ingest hasn't run yet | Wait 60 s for the next ingest poll; check `journalctl -u 'powernode-*-sidekiq.service' \| grep ModuleOciIngest` |
| `protected_spec` collision on assignment | Another module owns one of your protected files | Rename your file or use `mask` in a `config`-variety override |
| Assignment to template succeeds but agent doesn't pull | The module's `current_version_id` does not point at a version carrying a mountable artifact. That pointer — **not** `promotion_state` — is what the node-facing download resolves (`NodeApi::ModulesController#download` reads `@module.current_version&.artifact`) | [Why the agent isn't pulling](#why-the-agent-isnt-pulling), below. Promoting is **not** the fix |
| fs-verity digest mismatch on agent | Module artifact corrupted during transit | Re-run CI build; the platform re-ingests on next OCI poll |

### Why the agent isn't pulling

No node-facing surface consults `promotion_state`, so promoting a version cannot change
what an agent receives. `promotion_state` is a ladder the *platform* reads for its own
decisions (the `module_promotion_sensor`, the staging check in
`DecisionEngine#apply_module_promotion`, CVE remediation's candidate filter, compliance
counts); `NodeModule#current_version_id` is what a node is served. Start by finding out
what the pointer points at — `system_list_module_versions` marks the served row
`current: true` — then match the cause:

**1. The pointer was never moved onto your build.** Publishing writes it by default, but
withholds it in several cases, and the two publish paths report differently:

- The Gitea module webhook (`gitea_module#handle` → `System::ModulePublicationProcessor`)
  withholds when the module sets `auto_promote` false, when the erofs layer is under the
  non-empty floor, or when `System::CoreProvenanceGate` refuses the build's core provenance
  (that gate is inert unless the publish carries a `native_build`). Each emits a
  high-severity `system.module_promotion_withheld` event naming the reason — read it first.
- The REST/worker publish (`ModulePublicationsController#create`) withholds on `auto_promote`
  false, on the same non-empty floor, and on a batch-atomic deferral when a sibling module in
  the same build batch is still building. Only the deferral emits an event
  (`system.module_promotion_deferred`); the other two are log-only. **So the absence of a
  withheld event does not mean the pointer moved** — check `current: true` rather than
  inferring from events.

  Fix: repoint with `system_rollback_module_version({ module_id, version_id })`. Despite the
  name it moves `current_version_id` **forward** as well as back, and it is the writer that
  arms `RestartAfterUpdate`. It refuses a target whose artifact is missing, whose `oci_digest`
  is blank, or whose recorded size is below the same non-empty floor
  (`NodeModuleVersion#rollback_usable?`) — which is precisely the floor case above, so for
  that one repointing is not available: lower the floor
  (`SiteSetting system.module_publish.min_artifact_bytes`) and republish, or fix the build so
  the layer carries real content. A deferral needs no action — the orchestrator promotes the
  whole batch when its siblings finish.

**2. The pointer was moved onto a spec-only version.** Editing a module's versioned
attributes (`file_spec`, `config`, `dependency_spec`, `protected_spec`, …) fires
`NodeModule#auto_create_version`, which creates a new version row and points
`current_version_id` at it. That row carries no build artifact, so `download` returns
"Module has no published artifact" and the agent has nothing to mount. Fix: republish so a
build artifact lands on the new version, or repoint to the last version that has one.

Whether the promotion ladder *should* gate what the fleet serves is an open lifecycle-gating
question tracked separately (IMP-c7d618b0b72f); this runbook describes current behaviour only.

## How the System Concierge should use this

When an operator chats "I need a new module for X" / "compose a template for nginx + TLS":

1. Use `module_compose` skill — semantically ranks existing modules (embedding cosine, keyword fallback) + drafts a Template
2. If a custom module is needed, surface this runbook + the `templates/module-repo/` skeleton
3. For assignment workflows, use `system_assign_module_to_template` with `request_confirmation`

## Related docs

- [`templates/module-repo/README.md`](../../templates/module-repo/README.md) — skeleton this runbook expands on
- [`templates/example-modules/`](../../templates/example-modules/) — 5 working examples (apache, chrony, nginx, rpi4-firmware, security-hardening)
- [`USE_CASE_MATRIX.md`](../USE_CASE_MATRIX.md) — composition use cases (long-lived edge, multi-tenant, per-tenant config)
- [`SKILL_EXECUTORS.md`](../SKILL_EXECUTORS.md) — `module_compose` skill for AI-assisted composition
- [`runbooks/cve-response.md`](./cve-response.md) — module updates triggered by CVE response
- [`DISK_IMAGE_CI.md`](../DISK_IMAGE_CI.md) — companion pipeline for base disk images (vs. modules)

_Last verified: 2026-08-04_
