# Module Manifest — Complete Schema Reference

Every Powernode NodeModule ships a `manifest.yaml` at the root of its OCI artifact. This document is the **complete, authoritative reference** for every field — content selection, dependencies, init lifecycle, security policy, services, build hints.

> **Federation services?** For the `services:` key (added by the Decentralized Federation work) and on-node runtime semantics, see [`federation/MODULE_MANIFEST_SCHEMA.md`](./federation/MODULE_MANIFEST_SCHEMA.md). That doc is the source of truth for service-related fields; this doc covers the rest of the manifest and links across.

Source of truth for examples: the template at `templates/module-repo/manifest.yaml`.

---

## Schema overview

```yaml
schema_version: 1

# Identity
name:          <string>            # required; matches NodeModule.name
display_name:  <string>            # human-readable label
description:   <string>            # one paragraph
license:       <SPDX identifier>   # e.g., "MIT", "Apache-2.0"

# Content selection (rsync-style glob lines — see "Content Specs" section below)
mask:             [<glob>, ...]
file_spec:        [<glob>, ...]
protected_spec:   [<glob>, ...]
dependency_spec:  [<glob>, ...]
package_spec:     [<package>, ...]

# Module-to-module dependencies
dependencies:
  requires:   [<repo>@<version-constraint>, ...]
  provides:   [<capability-tag>, ...]

# Lifecycle hooks (legacy — prefer `services:` for new modules)
init:
  start:   <shell command>
  stop:    <shell command>
  restart: <shell command>

# Service definitions (preferred — see federation/MODULE_MANIFEST_SCHEMA.md)
services: [<service spec>, ...]

# Restart semantics
reboot_required: <boolean>

# Security policy
security:
  capabilities:      [<Linux capability>, ...]
  selinux_profile:   <path | null>
  apparmor_profile:  <path | null>
  seccomp_profile:   <path | null>
  egress_allow:      [<host:port>, ...]
  privileged:        <boolean>
  user_namespace:    <boolean>

# AI skills shipped by this module (forward-compat, Track F-4)
skills: []

# Build pipeline hints
build:
  ubuntu_digest: <sha256 | null>
  apt_snapshot:  <RFC-3339 timestamp | null>
```

---

## Field reference

### Identity

| Field | Type | Required | Description |
|---|---|---|---|
| `schema_version` | integer | yes | Always `1` today. The platform refuses to import unknown versions. |
| `name` | string | yes | Must match `NodeModule.name`. The webhook receiver uses this to route ingest events to the correct row. Also matches `gitea_repo_full_name` for trust-policy lookup. |
| `display_name` | string | no | UI label. Defaults to `name` if absent. |
| `description` | string | no | One-paragraph operator-facing description. |
| `license` | SPDX | no | License of the module's *contents*. The manifest itself is governed by the repo's LICENSE file. |

### Content specs

The five spec fields (`mask`, `file_spec`, `protected_spec`, `dependency_spec`, `package_spec`) are **rsync-style glob lines**. Their interaction is the heart of composefs+overlayfs union semantics — read carefully.

#### `mask`
Paths to **exclude** from this module's blob at build time (rsync filter, local to this module). Does NOT affect neighbor modules' blobs.

```yaml
mask:
  - "/var/cache/apt/**"     # don't ship the apt cache
  - "/usr/share/doc/**"     # strip docs
```

#### `file_spec`
Paths this module **owns**. Acts as an rsync include filter at build time and as the module's claim during overlayfs composition. For DEPENDANT children (modules with `parent_module_id` set — config + instance varieties), this field is silently shadowed by `parent.dependency_spec` at read time — the child's column is dead weight.

```yaml
file_spec:
  - "/opt/nginx/**"
  - "/etc/nginx/**"
  - "/usr/share/nginx/**"
```

#### `protected_spec`
Paths I own that **no neighbor may ship**. The build pipeline folds these into every neighbor's `effective_mask` in BOTH priority directions, so a sensitive lower-module file (e.g., `/etc/shadow` from `system-base`) cannot be overridden by a service module's overlay layer. This is the security carve-out — use it for credentials, kernel config, anything that must not be replaceable.

```yaml
protected_spec:
  - "/etc/shadow"
  - "/etc/sudoers"
  - "/etc/ssh/sshd_config"
```

#### `dependency_spec`
The file_spec my **dependant config / instance children inherit**. When a child is created with `parent_module: <self>`, the child's `file_spec` reader returns *this* value transparently — the child's own column is unused. Leaf modules with no dependants leave this empty.

This is the mechanism behind the dependant-modules architecture (per `project_dependant_modules` memory): per-node and per-instance customizations override fields without rebuilding the base module.

```yaml
# In nginx (base) module:
dependency_spec:
  - "/etc/nginx/conf.d/**"   # what children may override

# In nginx-custom-config (dependant child with parent_module: nginx):
# file_spec is silently inherited from nginx.dependency_spec.
# The child can still ship NEW content under /etc/nginx/conf.d/.
```

#### `package_spec`
Debian/Ubuntu package names to install into the build chroot. Resolved by the Containerfile's `apt-get install` step at build time.

```yaml
package_spec:
  - nginx
  - libnginx-mod-stream
```

> **Naming conflicts**: package_spec uses native package names (apt). For RPM modules, the package_repository ingestion service handles cross-format translation; see `system_create_module_from_package` MCP action.

### Dependencies

```yaml
dependencies:
  requires:
    - powernode/powernode-base-ubuntu@^1.0
    - powernode/powernode-postgres@^1.0
  provides:
    - rails-runtime
    - http.port:3000
```

| Subkey | Format | Description |
|---|---|---|
| `requires` | `<gitea-org/repo>@<version-constraint>` | Modules this depends on. Constraint syntax: `^1.0` (compatible), `~1.2` (patch-compatible), `=1.2.3` (exact), `*` (any). |
| `provides` | abstract capability tags | What this module exposes that other modules can target. Often used with naming conventions like `http.port:80`, `database:postgres`, `runtime:rails`. |

When `system_compose_module` is invoked, the composer walks the dependency graph and rejects compositions where multiple modules provide the same capability (e.g., two modules both providing `http.port:80` on the same node).

### Lifecycle: `init` vs `services`

Two lifecycle mechanisms exist for historical reasons:

**`init:` (legacy)** — A trio of shell commands populated into `System::NodeModule.init_start/stop/restart`. The on-node agent runs them as subprocesses (NEVER `eval`'d). Suitable for simple modules that need a one-shot start/stop.

```yaml
init:
  start:   "/usr/sbin/service nginx start"
  stop:    "/usr/sbin/service nginx stop"
  restart: "/usr/sbin/service nginx restart"
```

**`services:` (preferred)** — Structured service definitions that map to `system_module_services` rows. Supports per-service env, restart policy, health checks, dependencies between services, exposed ports. New modules should use this.

```yaml
services:
  - name: nginx
    start_command: "/usr/sbin/nginx -g 'daemon off;'"
    restart_policy: always
    exposed_ports:
      - { port: 80, protocol: tcp, name: http }
    health:
      endpoint: /healthz
      method: GET
      interval_seconds: 30
```

Full `services:` spec lives in [`federation/MODULE_MANIFEST_SCHEMA.md`](./federation/MODULE_MANIFEST_SCHEMA.md). The on-node agent reads the `services:` block directly from the OCI artifact's manifest — it does NOT query the DB.

### Reboot semantics

```yaml
reboot_required: false
```

| Value | Behavior |
|---|---|
| `false` | Hot-swap allowed — overlayfs lower stack remount + service restart. The agent attaches/detaches without rebooting the instance. |
| `true` | Attaching/detaching requires a reboot. The agent will defer the operation to the next reboot window. |

Set to `true` when the module touches kernel modules, init system, /boot, or anything that can't safely be hot-swapped.

### Security policy

The `security:` block is consumed by the on-node agent at module attach time. It's enforced at runtime via Linux capabilities, MAC profiles, and userns.

```yaml
security:
  capabilities: [CAP_NET_BIND_SERVICE]
  selinux_profile: null
  apparmor_profile: "profiles/myservice.apparmor"
  seccomp_profile: null
  egress_allow:
    - "registry.gitlab.com:443"
    - "github.com:443"
  privileged: false
  user_namespace: true
```

| Field | Type | Description |
|---|---|---|
| `capabilities` | array of Linux capabilities (`CAP_NET_BIND_SERVICE`, etc.) | What the module's processes are allowed to retain. Empty list = drop everything except what the kernel needs for basic IO. |
| `selinux_profile` | path inside the repo (e.g., `"profile.te"`) or null | SELinux Type Enforcement profile. Loaded on attach if non-null. |
| `apparmor_profile` | path or null | AppArmor profile (text format). |
| `seccomp_profile` | path or null | Seccomp filter. JSON or BPF assembly. |
| `egress_allow` | `host:port` strings (port optional) | Default-deny egress firewall. Empty list = no egress. |
| `privileged` | boolean | When `true`, the module needs raw hardware access (e.g., kernel modules, /dev/*). Requires **explicit operator approval** to attach (intervention policy `require_approval`). |
| `user_namespace` | boolean | When `true`, the agent maps the module's processes into a user namespace. Adds isolation but breaks some legacy software (e.g., requiring real root). |

### Skills (forward-compat)

```yaml
skills: []
```

A list of AI skill definitions this module ships. When attached, the on-node agent registers each declared skill with the platform via `ModuleSkillRegistrar`. Format under active design — see Track F-4 of the Golden Eclipse plan.

### Build hints

```yaml
build:
  ubuntu_digest: null     # falls back to Containerfile's UBUNTU_DIGEST default
  apt_snapshot:  null     # falls back to Containerfile's APT_SNAPSHOT default
```

| Field | Description |
|---|---|
| `ubuntu_digest` | SHA256 digest of the Ubuntu base image used by the Containerfile's `FROM` line. Pins the base for reproducible builds. |
| `apt_snapshot` | Snapshots.ubuntu.com timestamp (`20260514T000000Z`) — pins the apt package index for reproducibility. |

If null, the Containerfile's defaults apply. Pin these explicitly for SLSA L3 compliance and reproducible build chains.

---

## Trust policy fields

The trust-policy fields (`cosign_identity_regexp`, `cosign_issuer_regexp`) referenced in [`ARCHITECTURE.md`](./ARCHITECTURE.md) §1 do NOT live in `manifest.yaml`. They are persisted on the `NodeModule` row itself, set by the operator at module-registration time, and used during cosign verification of incoming module artifacts. See `extensions/system/server/app/models/system/node_module.rb` for the model attributes.

If you're designing a module-publish workflow that wants to bundle trust policy with the module, that's a roadmap item — open an RFC.

---

## Worked examples

### Example 1 — Base OS module (`system-base`)

A foundation module that ships the base Ubuntu rootfs minus runtime services. No init, no services — just files.

```yaml
schema_version: 1
name: system-base
display_name: "System Base (Ubuntu 24.04)"
description: "Minimal Ubuntu 24.04 rootfs. Every Powernode module composes on top of this."
license: "Various (Ubuntu base)"

mask:
  - "/var/cache/apt/**"
  - "/var/lib/apt/lists/**"
  - "/usr/share/doc/**"
  - "/usr/share/man/**"
file_spec:
  - "/bin/**"
  - "/sbin/**"
  - "/usr/**"
  - "/lib/**"
  - "/lib64/**"
  - "/etc/**"
  - "/var/**"
protected_spec:
  - "/etc/shadow"
  - "/etc/passwd"
  - "/etc/group"
  - "/etc/sudoers"
  - "/etc/ssh/sshd_config"
package_spec:
  - ubuntu-minimal
  - openssh-server

dependencies:
  requires: []
  provides:
    - base-os:ubuntu-24.04

reboot_required: false   # base attach is the boot itself; n/a for hot-swap

security:
  capabilities: []        # base; per-module additions stack on top
  privileged: false
  user_namespace: false   # base must NOT be userns'd
```

### Example 2 — Service module (`nginx`)

A standard service module with HTTP exposed port. Depends on system-base.

```yaml
schema_version: 1
name: nginx
display_name: "nginx HTTP server"
description: "nginx with default Ubuntu modules, ready to serve."
license: BSD-2-Clause

mask:
  - "/var/cache/apt/**"
file_spec:
  - "/etc/nginx/**"
  - "/usr/share/nginx/**"
  - "/var/log/nginx/**"
dependency_spec:
  - "/etc/nginx/conf.d/**"   # what dependant config children may carve out
protected_spec: []
package_spec:
  - nginx
  - libnginx-mod-stream

dependencies:
  requires:
    - powernode/system-base@^1.0
  provides:
    - http.port:80
    - http.port:443

services:
  - name: nginx
    start_command: "/usr/sbin/nginx -g 'daemon off;'"
    restart_policy: always
    exposed_ports:
      - { port: 80,  protocol: tcp, name: http }
      - { port: 443, protocol: tcp, name: https }
    health:
      endpoint: /
      method: GET
      interval_seconds: 30
      timeout_seconds: 5
      initial_delay_seconds: 5

reboot_required: false

security:
  capabilities: [CAP_NET_BIND_SERVICE]   # bind to :80
  egress_allow: []                        # nginx never initiates egress
  privileged: false
  user_namespace: true
```

### Example 3 — Config-variety dependant module (`nginx-prod-config`)

A child module that customizes nginx's configuration without rebuilding the parent.

```yaml
schema_version: 1
name: nginx-prod-config
display_name: "Production nginx config"
description: "Hardened nginx config for the production fleet (TLS-only, HSTS, rate limits)."
license: MIT

# file_spec is silently inherited from parent_module.dependency_spec
# (= nginx's dependency_spec = ["/etc/nginx/conf.d/**"])
file_spec: []

# This module's own contributions go under /etc/nginx/conf.d/
# (the parent's dependency_spec window)
protected_spec: []
package_spec: []

dependencies:
  requires:
    - powernode/nginx@^1.0
  provides: []

reboot_required: false

# Inherits parent's security defaults; can tighten further
security:
  capabilities: []
  egress_allow: []
```

> **Parent-module wiring** lives in the platform DB (`NodeModule.parent_module_id`), NOT in this YAML. Set the parent on module-creation via the operator UI or `system_create_module_from_package`.

### Example 4 — K3s server module

A cluster-control-plane module that exposes the K8s API and joins clusters by target_cluster_id metadata.

```yaml
schema_version: 1
name: k3s-server
display_name: "K3s control plane"
description: "K3s server node — runs apiserver, controller-manager, scheduler, etcd."
license: Apache-2.0

mask:
  - "/var/cache/apt/**"
file_spec:
  - "/usr/local/bin/k3s"
  - "/etc/rancher/**"
  - "/var/lib/rancher/k3s/**"
protected_spec:
  - "/var/lib/rancher/k3s/server/tls/**"   # cluster CA & node keys — never shadowable
package_spec:
  - curl
  - iptables

dependencies:
  requires:
    - powernode/system-base@^1.0
  provides:
    - k8s.apiserver
    - k8s.role:server
    - http.port:6443

services:
  - name: k3s-server
    start_command: "/usr/local/bin/k3s server --cluster-init"
    restart_policy: always
    exposed_ports:
      - { port: 6443, protocol: tcp, name: kubernetes }
    health:
      endpoint: /readyz
      method: GET
      interval_seconds: 15
      timeout_seconds: 5
      initial_delay_seconds: 30

reboot_required: false

security:
  capabilities:
    - CAP_NET_ADMIN          # configure iptables/ipvs
    - CAP_NET_BIND_SERVICE   # bind :6443
    - CAP_SYS_ADMIN          # mount namespaces for pods
  egress_allow:
    - "registry.k8s.io:443"
    - "ghcr.io:443"
  privileged: false
  user_namespace: false      # k3s needs real root for kubelet ops
```

Notice the `target_cluster_id` metadata used for multi-cluster K3s joining lives on the `NodeInstance.metadata` JSONB, not in manifest.yaml — same reasoning as parent-module wiring.

### Example 5 — Privileged hardening module (`security-hardening`)

A module that ships AppArmor + SELinux + audit configs. Requires operator approval to attach because it's privileged.

```yaml
schema_version: 1
name: security-hardening
display_name: "Security Hardening (SELinux + AppArmor + auditd)"
description: "Loads CIS-aligned MAC profiles and configures auditd. Affects every running service."
license: MIT

mask:
  - "/var/cache/apt/**"
file_spec:
  - "/etc/audit/**"
  - "/etc/apparmor.d/**"
  - "/etc/selinux/**"
protected_spec:
  - "/etc/audit/auditd.conf"
  - "/etc/audit/rules.d/**"
package_spec:
  - auditd
  - apparmor-utils
  - selinux-utils

dependencies:
  requires:
    - powernode/system-base@^1.0
  provides:
    - security:hardening
    - mac:apparmor
    - mac:selinux

init:
  start:   "/usr/sbin/service auditd start && aa-enforce /etc/apparmor.d/*"
  stop:    "/usr/sbin/service auditd stop"
  restart: "/usr/sbin/service auditd restart"

reboot_required: true       # MAC profile changes need a clean boot

security:
  capabilities:
    - CAP_AUDIT_CONTROL
    - CAP_AUDIT_WRITE
    - CAP_MAC_ADMIN          # SELinux + AppArmor admin
  selinux_profile: "profiles/hardening.te"
  apparmor_profile: "profiles/hardening.apparmor"
  seccomp_profile: null
  egress_allow: []           # auditd never initiates egress
  privileged: true           # ← REQUIRES OPERATOR APPROVAL to attach
  user_namespace: false      # MAC admin must run in init namespace
```

When attaching this module, the operator UI surfaces the privileged flag and requires explicit confirmation via the intervention policy. The Fleet Autonomy agent will not auto-attach privileged modules even at `auto_approve` policy.

---

## Validation

Manifests are validated at **two distinct moments**: at PR/CI time by a JSON Schema gate, and again at OCI ingest time by the Rails-side `System::ManifestImportService`.

### Build-time (CI schema gate)

**Schema:** [`modules/.schema/module-manifest.schema.json`](../modules/.schema/module-manifest.schema.json) — JSON Schema draft 2020-12. This is the machine-readable mirror of the prose reference in this document.

**Workflow:** [`.gitea/workflows/module-validate.yaml`](../.gitea/workflows/module-validate.yaml) runs on every PR or push that touches `modules/**/manifest.yaml`, `templates/example-modules/**/manifest.yaml`, `templates/module-repo/manifest.yaml`, or the schema itself. It walks every manifest in the extension, converts YAML → JSON via `yq`, then validates with `ajv-cli@5` (draft 2020-12, `--all-errors`).

**What this catches before runtime:**

- Top-level typos (`fil_spec:` instead of `file_spec:`) — `additionalProperties: false` at every level rejects unknown keys
- Bad enum values (`restart_policy: "sometimes"`)
- Bad `name` format (`BadName` rejected — must match `^[a-z](?:[a-z0-9-]{0,62}[a-z0-9])?$`)
- Bad Linux capability spelling (`NET_ADMIN` rejected — must match `^CAP_[A-Z_]+$`)
- Missing required fields (`schema_version`, `name`)
- Wrong schema version (only `1` is supported today)
- Bad `build.ubuntu_digest` format (must be `sha256:<64-hex>` or null)
- Bad `build.apt_snapshot` format (must be `YYYYMMDDTHHMMSSZ` or null)

**Run locally:**

```bash
cd extensions/system
schema="modules/.schema/module-manifest.schema.json"
for m in $(find modules templates -name manifest.yaml); do
  tmp="/tmp/$(echo "$m" | tr '/' '_').json"
  python3 -c "import yaml,json; print(json.dumps(yaml.safe_load(open('$m'))))" > "$tmp"
  npx --yes ajv-cli@5 validate -s "$schema" -d "$tmp" --spec=draft2020 --all-errors
done
```

(In CI the workflow uses `yq` instead of Python; either works.)

### Runtime (`System::ManifestImportService`)

When the platform ingests a new OCI artifact, `System::ManifestImportService.import!` runs a second pass that adds semantic checks the schema can't express:

- `schema_version` is a known integer (currently `1`)
- `name` matches the platform's `NodeModule.name`
- Each spec list is an array of strings (non-arrays raise `Invalid YAML structure`)
- `package_spec` entries are valid Debian package names
- `dependencies.requires` entries match the `<org>/<repo>@<constraint>` pattern
- `security.privileged: true` requires operator confirmation (handled at attach time, not import)
- `init` and `services` may both be present (init runs first; new modules prefer services-only)

For the full `services:` validation rules (name uniqueness, restart_policy enum, health endpoint format, dependency cycles), see [`federation/MODULE_MANIFEST_SCHEMA.md`](./federation/MODULE_MANIFEST_SCHEMA.md).

---

## Related documentation

- [`federation/MODULE_MANIFEST_SCHEMA.md`](./federation/MODULE_MANIFEST_SCHEMA.md) — the `services:` key + on-node runtime semantics
- [`ARCHITECTURE.md`](./ARCHITECTURE.md) §1 — module lifecycle, trust policy fields, build pipeline
- [`runbooks/module-authoring.md`](./runbooks/module-authoring.md) — end-to-end "ship a new module" walkthrough
- `templates/module-repo/manifest.yaml` — canonical authoring-time template
- `templates/module-repo/Containerfile` — the build context that consumes `build.ubuntu_digest` + `build.apt_snapshot`
