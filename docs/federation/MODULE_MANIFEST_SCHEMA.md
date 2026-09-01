# Module Manifest YAML Schema (v1)

> Status: active

> **Scope.** This doc is the source of truth for the manifest's **`services:`**
> key (added by the Decentralized Federation work) and the on-node runtime
> semantics. Every other top-level field — content specs, dependencies, `init`,
> `security`, `skills`, `build`, `users`/`groups`/`sudoers` — is owned by
> [`../MODULE_MANIFEST_COMPLETE_SCHEMA.md`](../MODULE_MANIFEST_COMPLETE_SCHEMA.md).
> The manifest is **flat**: `services:` sits at the top level alongside `name`,
> `file_spec`, etc. — there is no `identity:` (or any other) wrapper object.

Authoritative source: each NodeModule ships a `manifest.yaml` that describes
its filesystem content selection, declared dependencies, init lifecycle hooks,
and (added in the Decentralized Federation work) **service definitions**.

The platform's `System::ManifestImportService` parses this YAML and writes
both the NodeModule fields (mask, file_spec, etc.) and the new
`system_module_services` rows (Decentralized Federation plan §A).

The Go on-node agent reads the same YAML directly to launch services. The
structured DB rows exist for query workloads (Platform Infrastructure
dashboard, scaling composer, service discovery) — they are NOT the on-node
runtime source.

## Top-Level Schema

```yaml
schema_version: 1

# Identity (validated against the platform's NodeModule.name)
name: powernode-hub-backend
display_name: "Powernode Hub Backend"
description: "Rails 8 API server + ActionCable channel"
license: MIT

# Content selection (rsync-glob lines)
mask: []
file_spec:
  - "/opt/powernode-rails/**"
  - "/etc/systemd/system/powernode-backend.service"
package_spec:
  - ruby3.3
  - bundler
  - libpq-dev
dependency_spec: []
protected_spec:
  - "/etc/systemd/system/powernode-backend.service"

# Module-to-module dependencies (Gitea repo @ version constraint)
dependencies:
  requires:
    - powernode/runtime-ruby@^1.0
    - powernode/postgres-primary@^1.0
  provides:
    - rails-runtime

# Module-wide init lifecycle (kept for legacy modules; new modules should
# use the `services:` key instead)
init:
  start: "/usr/sbin/service powernode-backend start"
  stop:  "/usr/sbin/service powernode-backend stop"
  restart: "/usr/sbin/service powernode-backend restart"

reboot_required: false

security:
  capabilities: [CAP_NET_BIND_SERVICE]
  egress_allow: []
  privileged: false

skills: []        # ModuleSkillRegistrar consumes this

build:
  ubuntu_digest: null
  apt_snapshot:  "20260514T000000Z"
```

## The `services:` Key (Decentralized Federation Plan §A)

A module can declare one or more services that the agent should run.
Each service maps to one `system_module_services` row.

```yaml
services:
  - name: rails
    start_command: "bundle exec puma -C config/puma.rb"
    stop_command:  "kill -SIGTERM $MAINPID"           # optional
    restart_policy: always                             # always | on-failure | never
    user: powernode                                    # optional; defaults to agent's user
    working_directory: /opt/powernode-rails            # optional

    env:
      RAILS_ENV: production
      RAILS_LOG_TO_STDOUT: "1"
      BACKEND_API_URL: "http://localhost:3000"

    exposed_ports:
      - { port: 3000, protocol: tcp, name: http }

    capabilities: []                                   # Linux capabilities to retain

    health:
      endpoint: /up                                    # optional; omit for non-HTTP services
      method: GET                                      # GET | POST | PUT
      interval_seconds: 30
      timeout_seconds: 5
      initial_delay_seconds: 10

    dependencies:
      - { service: postgres, kind: requires_health }   # references another service IN THIS MANIFEST

    metadata: {}                                       # forward-compat free-form
```

### `unit_body`: verbatim systemd unit passthrough

Most services describe their process via the structured fields above and let
the agent generate the `[Service]`/`ExecStart=`/`Restart=`/`[Install]`
stanzas. A service may instead supply `unit_body` — a **verbatim systemd unit
file body** — for lifecycle semantics the structured fields can't express
(`Type=oneshot`, `RemainAfterExit=`, `RestartSec=`, `StartLimit*=`,
`ExecStartPre=`, etc.):

```yaml
services:
  - name: claude
    unit_body: |
      [Unit]
      Description=Claude tmux session
      After=network-online.target
      Wants=network-online.target

      [Service]
      Type=oneshot
      RemainAfterExit=yes
      User=pnadmin
      ExecStart=/usr/local/bin/claude-tmux-start.sh

      [Install]
      WantedBy=multi-user.target
```

`unit_body` and `start_command` are **mutually exclusive** — a service
declares exactly one. `unit_body` rides the same `services:` write/enable/
detach lifecycle as a generated unit (the agent writes
`powernode-<moduleUUID>-<name>.service`, appends a generated `[Unit]` section
for any `dependencies:` entries, and — under chroot attach — an appended
`[Service]` section carrying the chroot directives); the body's own
`[Install]`/`WantedBy=` is what makes `systemctl --root enable` do anything,
since the agent does not append an `[Install]` section itself.

Sibling ordering (`After=`/`Requires=` on another service *in this same
manifest*) must NOT be hand-written into `unit_body` — the generated unit
name (`powernode-<moduleUUID>-<name>.service`) isn't known until attach time.
Express those as `dependencies:` instead; the agent emits the matching
ordering lines. Non-sibling ordering (e.g. `After=network-online.target`)
stays in the body verbatim.

When `unit_body` is present and `user:` is omitted, the body's own `User=`
line governs — the row is saved with no `service_user`/`system_user`
(`ManifestImportService` skips user resolution in this case, so a user like
`pnadmin` that isn't a platform-allocated `ServiceUser` or a
`WELL_KNOWN_SYSTEM_USERS` entry doesn't need to be declared under `users:`).

## Validation Rules

- `name` is required, unique within the manifest's services list, max 100 chars.
- Exactly one of `start_command` / `unit_body` is required (non-empty string).
- When `unit_body` is present, it must contain a `[Service]` section and a
  `WantedBy=` line — the agent's offline `systemctl enable` reads
  `[Install]`/`WantedBy=` directly from the body.
- `restart_policy` (if present) must be one of `always | on-failure | never`.
- `health.method` (if present) must be one of `GET | POST | PUT`.
- `dependencies[*].service` must reference another service declared in the
  same manifest (cross-module service dependencies are NOT supported — modules
  depend on modules, services depend on services within a module).
- `dependencies[*].kind` (if present) must be one of `start_before | requires_health | softdep`.

### What each dependency `kind` renders to

The agent turns each edge into systemd directives on the *dependent's* unit:

| `kind` | Emitted | Meaning |
|---|---|---|
| `start_before` | `After=` + `Requires=` | target must be running before this service starts |
| `requires_health` | `After=` + `Requires=` | target must pass its health check first |
| `softdep` | `After=` + `Wants=` | target preferred-running, explicitly **not** required |

`start_before` and `requires_health` coincide today: the agent has no
readiness gate (units render `Type=simple`, and `health.*` is read only by
the on-demand smoke probe), so "healthy first" is not expressible as a
directive distinct from "started first". The strict form is the
conservative reading. An unrecognised `kind` also renders `Requires=`, so a
manifest written against a newer server cannot silently lose a necessity
guarantee on an older agent.

Two cautions when reaching for `softdep`:

- **`Wants=` does not wait for success.** `After=` orders only against the
  target's job *finishing*, not succeeding. A `softdep` onto a `Type=oneshot`
  service will let this service start after the target **failed**. Do not use
  it for an edge that stages credentials or other material this service needs
  — that is what `start_before` is for.
- **Recovery is expressed on the TARGET, and only for the strict kinds.**
  `Requires=` cancels this service's start job if the target fails, and
  systemd does not re-run the cancelled job when the target later succeeds.
  The agent closes that by inverting the graph: a service that is the target
  of a `start_before` or `requires_health` edge gets `Wants=<dependent>` on
  its own unit, so when it recovers via a start job it pulls its dependents
  back up (`lifecycle.recoveryDependents`). A `softdep` target gets no such
  line — an optional dependency must not drag its dependent up.

  Two consequences worth knowing before you declare a strict edge:

  - Starting the target now also starts its dependents, even if you only
    asked for the target.
  - Recovery is tied to the target's *start job*, not held continuously. If a
    dependent dies on its own while the target stays up, nothing revives it;
    that is the dependent's own `Restart=`/`StartLimit*` business. (The agent
    deliberately does not use `Upholds=` here: it is a continuous want, which
    makes the dependent un-stoppable on its own and re-tries a
    `Condition*=`-gated dependent about twice a second forever.)

## Idempotency and Deletion

`ManifestImportService.import!` is idempotent:

- Re-importing the same manifest updates existing `ModuleService` rows by
  matching on `(node_module, name)`.
- Re-importing a manifest with a service removed deletes the orphaned row
  (manifest YAML is the authoritative source).
- Cross-service dependencies that disappear from the manifest delete the
  corresponding `ModuleServiceDependency` edge.

This means: edit the manifest and re-publish — the platform's view converges on
the new manifest without manual cleanup. Import is **not** a standalone MCP
action: `ManifestImportService.import!` runs automatically on OCI ingest (the
publication processor) and on the operator REST path that saves an edited
`manifest_yaml` (`node_modules_controller`). To dry-run-validate a manifest
payload *before* publishing, use the `system_validate_module_manifest` MCP
action.

## On-Node Runtime

The Go agent reads `manifest.yaml` directly from the OCI artifact at module
attach time. It does NOT query the platform's `system_module_services` rows.
This separation means:

1. The platform's view (DB rows) drives operator UX + scaling decisions.
2. The on-node view (manifest.yaml) drives actual service execution.
3. Both views derive from the same authoritative source (the OCI artifact's
   manifest), so they cannot diverge as long as ingestion is correctly
   triggered when manifest_yaml changes.

If the operator edits manifest_yaml in the dashboard and saves: the platform
runs `ManifestImportService.import!` to refresh the DB rows immediately;
the agent picks up the change on its next module-attach cycle (typically the
next reconcile tick).

## Related Documentation

- [`../MODULE_MANIFEST_COMPLETE_SCHEMA.md`](../MODULE_MANIFEST_COMPLETE_SCHEMA.md) — every non-service top-level field (content specs, dependencies, `init`, `security`, `skills`, `build`, `users`/`groups`/`sudoers`)
- [`./SOCIAL_CONTRACT.md`](./SOCIAL_CONTRACT.md) — operator commitments around manifest accuracy
- [`../INGRESS_TLS_GUIDE.md`](../INGRESS_TLS_GUIDE.md) — how Traefik consumes a service's `exposed_ports` (Expose-Service wizard → VIP → port map → ACME → Traefik)
- [`./SPAWN_MODES.md`](./SPAWN_MODES.md) — federation spawn modes that consume these service definitions

_Last verified: 2026-06-03_
