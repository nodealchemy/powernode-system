# Module Manifest — Complete Schema Reference

> Status: active

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
category:      <taxonomy slug>     # overlay-stack tier — see System::NodeModuleCategory::PLATFORM_TAXONOMY

# Content selection (rsync-style glob lines — see "Content Specs" section below)
mask:             [<glob>, ...]
file_spec:        [<glob>, ...]
protected_spec:   [<glob>, ...]
dependency_spec:  [<glob>, ...]
package_spec:     [<package>, ...]
carve_waivers:    [<glob>, ...]  # build-tooling only — see "Content Specs" below

# Module-to-module dependencies
dependencies:
  requires:   [<repo>@<version-constraint> | capability:<tag>[@<constraint>], ...]
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

# Fleet-managed Unix identity (users / groups / sudoers grants)
users:    [<user spec>, ...]
groups:   [<group spec>, ...]
sudoers:  [<sudoers grant>, ...]

# Build pipeline hints
build:
  ubuntu_digest: <sha256 | null>
  apt_snapshot:  <YYYYMMDDTHHMMSSZ timestamp | "none" | null>

# Post-deploy self-proof (see "Verify probes" below)
verify:
  probes:
    - name:        <identifier>
      command:     <BARE command name>
      resolves_to: <absolute path>   # REQUIRED
```

> **Authoritative top-level key set.** The keys above are exactly
> `System::ManifestImportService::KNOWN_TOP_KEYS`. Anything else is preserved
> verbatim under `config.manifest_extras` (forward-compat) but is not validated.
>
> **Exception: `carve_waivers`.** Schema-validated (module-validate.yaml) but
> intentionally NOT in `KNOWN_TOP_KEYS` — it's build-tooling input for
> `scripts/module-build/derive-file-spec.sh`'s conformance check, read
> directly from the manifest YAML, not a NodeModule DB column. It still
> round-trips harmlessly through the `manifest_extras` forward-compat path on
> import.

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
| `category` | taxonomy slug | no | Overlay-stack layering tier — one of `System::NodeModuleCategory::PLATFORM_TAXONOMY`'s keys (`system-base`, `base-os`, `language-runtime`, `data-plane`, `storage-guest`, `networking-proxy`, `observability`, `build-dev`, `platform-apps`, `workloads`). `ManifestImportService` resolves it to a `NodeModuleCategory`, creating the account's triplet on first use. Absent: the importing seed/caller's own fallback applies (the platform seed defaults to `workloads`). |

### Content specs

The five spec fields (`mask`, `file_spec`, `protected_spec`, `dependency_spec`, `package_spec`) are **rsync-style glob lines**. Their interaction is the heart of erofs+overlayfs union semantics — read carefully.

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

#### `carve_waivers`
Build-tooling only — not one of the five rsync-glob content-selection fields above, and not carved by stage2-carve.sh (it never reads this key). Consumed exclusively by `scripts/module-build/derive-file-spec.sh`'s `conformance` check (campaign 019f6084 inc0): globs of paths this module's `package_spec` owns (per `dpkg -L`, minus the base-os baseline) that are deliberately left OUT of `file_spec` — e.g. optional binaries/docs the module intentionally doesn't ship. Without a matching waiver, the conformance check WARNs (never fails the build) on every such "owned but not carved" path; a waiver silences the WARN for the matched paths only.

```yaml
carve_waivers:
  - "/usr/share/nginx/html/**"   # default placeholder site — intentionally not shipped
```

Matched via case-pattern matching against the absolute path (a `**` behaves like a single `*` — see the script's own comment for why that's still correct for this purpose). Does not affect what gets carved into the erofs blob; only affects the conformance report.

### Dependencies

```yaml
dependencies:
  requires:
    - powernode/powernode-base-ubuntu@^1.0
    - powernode/postgres-primary@^1.0
    - "capability:database.postgres@>= 16"   # capability requirement — see below
  provides:
    - rails-runtime
    - http.port:3000
```

| Subkey | Format | Description |
|---|---|---|
| `requires` | Either a **name pin** `<gitea-org/repo>@<version-constraint>`, or a **capability requirement** `capability:<tag>[@<constraint>]` | Modules this depends on. See "The two `requires` forms" below. |
| `provides` | abstract capability tags | What this module exposes that other modules can target. Often used with naming conventions like `http.port:80`, `database:postgres`, `runtime:rails`. |

### The two `requires` forms

**Name pin** — `<owner>/<module>@<constraint>`, or a bare module name. Binds to
one specific module by its Gitea repo (`gitea_repo_full_name`) or name.
Constraint syntax: `^1.0` (compatible), `~1.2` (patch-compatible), `=1.2.3`
(exact), `*` (any). The constraint is recorded on the dependency edge but is
**not** enforced — the platform has no module semver to check it against
(`NodeModuleVersion#version_number` is an integer counter, not a semver
string).

**Capability requirement** — `capability:<tag>[@<constraint>]`. Says *what you
need* rather than *who provides it*: the importer picks the highest-priority
module on the account whose `provides` advertises `<tag>`. Any future module
providing that tag satisfies the requirement, with no manifest edit here. The
constraint (when present) is **`Gem::Requirement` syntax** — `>= 16`, `~> 1.0`,
`1.0` — not the npm caret form name pins use by convention. A bare `provides`
tag does not satisfy a versioned requirement: to answer
`capability:http-server@>= 1.26`, a provider must advertise `http-server@1.26`,
not bare `http-server`.

```yaml
requires:
  - "capability:os.userland"               # any provider of the tag
  - "capability:database.postgres@>= 16"   # provider must advertise a satisfying version
```

Unsatisfied capabilities are not a build failure — the import defers them and
`CapabilityGapSensor` reports the standing gap to the operator each tick,
clearing itself when a provider publishes. Full syntax rules and gotchas (drift
handling, malformed-constraint rejection) live in the module-authoring
runbook's [The two `requires` forms](./runbooks/module-authoring.md#the-two-requires-forms)
section — this doc mirrors the summary; that one is authoritative.

When `module_compose` is invoked, the composer walks the dependency graph and rejects compositions where multiple modules provide the same capability (e.g., two modules both providing `http.port:80` on the same node).

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

### Fleet-managed Unix identity (`users`, `groups`, `sudoers`)

Three top-level arrays declare the Unix identity a module needs at runtime. `System::ManifestImportService` validates them and reconciles them into `System::ServiceUser`, `System::ServiceGroup`, and `System::SudoersGrant` rows; the on-node agent materializes the corresponding accounts and `/etc/sudoers.d` drop-ins on module attach.

```yaml
groups:
  - name: powernode          # must match System::ServiceGroup::GROUPNAME_RX

users:
  - name: powernode          # must match System::ServiceUser::USERNAME_RX; unique within the manifest
    shell: /usr/sbin/nologin # optional
    home: /var/lib/powernode # optional
    gecos: "Powernode runtime user"   # optional
    primary_group: powernode          # optional; declared above OR already allocated platform-wide
    supplementary_groups: [docker]    # optional; each declared above OR allocated platform-wide

sudoers:
  - id: powernode-reload     # must match System::SudoersGrant::GRANT_ID_RX; unique within the manifest
    user: powernode          # declared in `users:` above OR a live platform ServiceUser
    runas: root              # optional
    commands: ["/usr/bin/systemctl reload powernode-backend"]
    flags: [NOPASSWD]        # optional
```

| Array | Required subkeys | Notes |
|---|---|---|
| `groups[*]` | `name` | Name must match `GROUPNAME_RX`; unique within the manifest. |
| `users[*]` | `name` | Name must match `USERNAME_RX`; unique. `shell`/`home`/`gecos` are optional strings. `primary_group` + each `supplementary_groups` entry must be declared in this manifest's `groups:` OR already allocated platform-wide (`ServiceGroup.live`). |
| `sudoers[*]` | `id`, `user` | `id` must match `GRANT_ID_RX`; unique. `user` must be declared in `users:` OR a live platform `ServiceUser`. `runas`, `commands`, `flags` shape the granted sudo rule. |

Validation collects the full error set in one pass (not first-error-wins), so a bad manifest surfaces every offending entry at once.

### Build hints

```yaml
build:
  ubuntu_digest: null     # falls back to Containerfile's UBUNTU_DIGEST default
  apt_snapshot:  "20260514T000000Z"   # or "none" / null to opt out (live archive.ubuntu.com)
```

| Field | Description |
|---|---|
| `ubuntu_digest` | SHA256 digest of the Ubuntu base image used by the Containerfile's `FROM` line. Pins the base for reproducible builds. |
| `apt_snapshot` | snapshot.ubuntu.com timestamp (`20260514T000000Z`) — consumed directly by `build-platform-modules.yaml` Stage 1 as the `mmdebstrap` `base_url` (`https://snapshot.ubuntu.com/ubuntu/<timestamp>/`), pinning the apt package index so two builds of an unchanged module resolve the identical package set (campaign 019f5885 inc5). `"none"` and `null` (field omitted) are equivalent, documented opt-outs — both fall back to the live `http://archive.ubuntu.com/ubuntu/` mirror (pre-inc5 behavior). Use the opt-out when snapshot.ubuntu.com hasn't caught up on a package this module needs yet. Third-party apt sources a module registers itself (e.g. `log-forwarder-vector`'s `apt.vector.dev`, `storage-tools`'s `packages.cloud.google.com`) are **not** covered by this pin — those remain a documented, irreducible reproducibility waiver until/unless the vendor offers a snapshot service. |

If null, the live-mirror default applies (see the opt-out note above). Pin these explicitly for SLSA L3 compliance and reproducible build chains.

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

A cluster-control-plane module that exposes the K8s API. (`k3s-server` bootstraps its own cluster and never issues a `join_request`, so `target_cluster_id` does not apply to it — an HA server still registers against a cluster on `phase=ready`, but only the one it bootstrapped. On `k3s-agent` workers the field is [NOT IMPLEMENTED](./CONTAINER_RUNTIMES.md#multi-cluster-routing-via-target_cluster_id--not-implemented) on the agent side.)

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

Notice `target_cluster_id` is not a manifest.yaml key — same reasoning as parent-module wiring. Two corrections to earlier revisions of this line: it is a **module-assignment `config`** key, not `NodeInstance.metadata`; and nothing reads it from either place. The platform consumes `target_cluster_id` only as a runtime-handshake request parameter, from two phases: `phase=join_request` (`runtime_handshake_handlers.rb:164`), which the agent never populates, and the `cluster_id` an already-joined node echoes on `phase=ready` (`:195`), which can only name the cluster it is already in. Neither lets an operator choose one, so multi-cluster worker placement is [NOT IMPLEMENTED](./CONTAINER_RUNTIMES.md#multi-cluster-routing-via-target_cluster_id--not-implemented).

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

## Verify probes

`verify:` is the module's **self-proof**: what must be true on the node for this
module to be doing its job. Optional; a manifest without it behaves exactly as
before. Declared probes are mirrored onto `NodeModule#config` at import, ride
the existing `config` blob out to the agent, and are run by the agent's
`internal/probe` package after each attach and on a refresh interval. Results
travel on the heartbeat as `module_verify_state`, are persisted by
`System::ModuleVerifyStateWriter`, and a mismatch reaches an operator through
`System::Fleet::Sensors::ModuleVerifyFailedSensor`
(`system.module_verify_failed` → `system.module_verify_investigate`).

```yaml
verify:
  probes:
    - name: gitleaks-binary
      command: gitleaks
      resolves_to: /usr/local/bin/gitleaks
```

| Field | Required | Meaning |
|---|---|---|
| `name` | yes | `^[a-z0-9][a-z0-9._-]{0,63}$`. Concatenated into the signal fingerprint a failed probe raises. |
| `command` | yes | A **bare** command name — no slash, no whitespace, no shell metacharacter. Resolved through `PATH`. |
| `resolves_to` | **yes** | The absolute, canonical path that name must resolve to. |

### The two rules, and why they are rules

Both come from the ratified design in the platform's
`docs/operations/autonomous-infrastructure-readiness-2026-08-12.md` §2 (that
file lives in the parent monorepo, not in this repo, so it is named rather
than linked).

1. **`resolves_to` is required — a resolved path, never mere existence.** An
   existence check ("is there a `gitleaks` on `PATH`?") is exactly what passed
   while the VM-9000 binary was *shadowed*: the name resolved, to the wrong
   file. A probe that cannot say **which** file must answer the name is not a
   weaker probe, it is the bug — so `System::ManifestImportService` refuses to
   import one and the JSON schema marks it `required`. For the same reason
   `command` must be a bare name: an absolute path resolves itself and never
   exercises the `PATH` lookup, so it is structurally incapable of seeing a
   shadow.

2. **Every probe runs in BOTH a login and a non-login shell.** There is
   deliberately **no `shells:` key** — the divergence between the two *is* the
   bug class (a login shell sources `/etc/profile`, `/etc/profile.d/*` and
   `~/.bash_profile`, which is where a `PATH` gets reordered), so it cannot be
   a per-module choice. A probe is scored **passing only when the report
   covers both shells and both agree**; a report naming one shell is recorded
   as `unknown`, never `pass`, so an older or partial agent produces "not
   measured" rather than a false green.

### What a failure looks like

`system.module_verify_failed` (high) carries `expected_path`, the per-shell
`resolved` value, and a `shadowed` boolean separating "resolved to the wrong
file" from "did not resolve at all" (the shape of the 2026-08-07 gitleaks v4
empty-artifact whiteout). There is **no applier**: a wrong artifact, a
shadowing package, or a `PATH`-reordering profile script are all repaired by a
person, and re-serving the same module changes none of them.

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
# Same YAML→JSON tool (yq) the CI workflow uses — install via
#   sudo curl -fsSL https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -o /usr/local/bin/yq && sudo chmod +x /usr/local/bin/yq
while IFS= read -r m; do
  tmp="/tmp/$(echo "$m" | tr '/' '_').json"
  yq -o=json '.' "$m" > "$tmp"
  npx --yes ajv-cli@5 validate -s "$schema" -d "$tmp" --spec=draft2020 --all-errors
done < <(find modules templates -name manifest.yaml | sort)
```

This mirrors [`.gitea/workflows/module-validate.yaml`](../.gitea/workflows/module-validate.yaml) exactly (mikefarah `yq` for YAML→JSON, then `ajv-cli@5`), so a local pass and the CI gate agree.

### Runtime (`System::ManifestImportService`)

When the platform ingests a new OCI artifact, `System::ManifestImportService.import!` runs a second pass that adds semantic checks the schema can't express:

- `schema_version` is a known integer (currently `1`)
- `name` matches the platform's `NodeModule.name`
- Each spec list is an array of strings (non-arrays raise `Invalid YAML structure`)
- `package_spec` entries are valid Debian package names
- `dependencies.requires` entries match the `<org>/<repo>@<constraint>` pattern
- `security.privileged: true` requires operator confirmation (handled at attach time, not import)
- `init` and `services` may both be present (init runs first; new modules prefer services-only)
- `verify.probes[*]` require `name`, a **bare** `command`, and `resolves_to` (an absolute, canonical path); unknown keys inside `verify:` or a probe are rejected, so a `shells:`-shaped typo fails loudly instead of importing as a probe that silently tests less
- `users` / `groups` / `sudoers` entries validate name/id regexes, intra-manifest uniqueness, and group/user cross-references (each `primary_group`, `supplementary_groups` entry, and sudoers `user` must be declared in the same manifest OR already allocated platform-wide via `ServiceGroup.live` / `ServiceUser.live`)

For the full `services:` validation rules (name uniqueness, restart_policy enum, health endpoint format, dependency cycles), see [`federation/MODULE_MANIFEST_SCHEMA.md`](./federation/MODULE_MANIFEST_SCHEMA.md).

---

## Related documentation

- [`federation/MODULE_MANIFEST_SCHEMA.md`](./federation/MODULE_MANIFEST_SCHEMA.md) — the `services:` key + on-node runtime semantics
- [`ARCHITECTURE.md`](./ARCHITECTURE.md) §1 — module lifecycle, trust policy fields, build pipeline
- [`runbooks/module-authoring.md`](./runbooks/module-authoring.md) — end-to-end "ship a new module" walkthrough
- `templates/module-repo/manifest.yaml` — canonical authoring-time template
- `templates/module-repo/Containerfile` — the build context that consumes `build.ubuntu_digest` + `build.apt_snapshot`

_Last verified: 2026-08-04_
