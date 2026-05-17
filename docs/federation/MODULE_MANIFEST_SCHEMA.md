# Module Manifest YAML Schema (v1)

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
    - powernode/powernode-base-ruby@^1.0
    - powernode/powernode-postgres@^1.0
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

## Validation Rules

- `name` is required, unique within the manifest's services list, max 100 chars.
- `start_command` is required (non-empty string).
- `restart_policy` (if present) must be one of `always | on-failure | never`.
- `health.method` (if present) must be one of `GET | POST | PUT`.
- `dependencies[*].service` must reference another service declared in the
  same manifest (cross-module service dependencies are NOT supported — modules
  depend on modules, services depend on services within a module).
- `dependencies[*].kind` (if present) must be one of `start_before | requires_health | softdep`.

## Idempotency and Deletion

`ManifestImportService.import!` is idempotent:

- Re-importing the same manifest updates existing `ModuleService` rows by
  matching on `(node_module, name)`.
- Re-importing a manifest with a service removed deletes the orphaned row
  (manifest YAML is the authoritative source).
- Cross-service dependencies that disappear from the manifest delete the
  corresponding `ModuleServiceDependency` edge.

This means: edit the manifest, re-publish, run `system.import_manifest` MCP
action (or the equivalent operator path) — the platform's view converges on
the new manifest without manual cleanup.

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

- `docs/federation/SOCIAL_CONTRACT.md` (v1 ships in P4) — operator commitments around manifest accuracy
- `docs/federation/REVERSE_PROXY_GUIDE.md` (P2.5) — how Traefik consumes `exposed_ports` from these rows
- `docs/federation/OPERATOR_GUIDE.md` (P7) — dashboard-side service operations
