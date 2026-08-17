# claude-tmux NodeModule

> Status: active — increment 20, campaign 019f3458.

Managed Claude Code CLI in a named, systemd-supervised tmux session on a
fleet instance. Survives SSH disconnects; the operator reconnects with
`tmux -L claude-tmux attach -t claude-code`. The Anthropic API key is
Vault-injected at boot — never baked into the module image, never in an
env file, never logged. Reusable standalone; increment 21's managed
dev-cell is its first consumer.

## Hosting pattern: in-tree, not standalone

[`docs/runbooks/module-authoring.md`](./runbooks/module-authoring.md) documents
a per-repo "standalone module" pattern (`templates/module-repo/` skeleton, its
own Gitea repo, its own `.gitea/workflows/build.yaml`, polled ingest via
`ModuleOciIngestService`). This module does **not** use that pattern — it
lives in-tree at [`modules/claude-tmux/`](../modules/claude-tmux/), built by
the shared [`build-platform-modules.yaml`](../.gitea/workflows/build-platform-modules.yaml)
matrix (the same pipeline as `node-exporter`, `redis`, `storage-tools`,
`log-forwarder-vector`, `qemu-guest-agent` — all generic, any-template,
operator-opt-in modules, not just the `powernode-hub-*` set).

Reasoning: the standalone pattern exists for independently-owned or
externally-published modules that shouldn't live in this repo. claude-tmux is
neither — it's a general-purpose platform module maintained alongside the
five modules above, with the identical "any fleet instance, any template"
consumption model. In-tree gets it the existing CI pipeline, existing cosign
identity, and existing publish-notify path for free, with zero new Gitea
repos/secrets to provision. Publish is push-based: CI POSTs to
`/api/v1/system/module_publications` on every build, which auto-creates the
`NodeModule` row (`variety: subscription`, category `Workloads` — the
resolver's fallback bucket if no row pre-exists; in practice the platform
seed pre-creates claude-tmux under `Build & Dev` before any publish runs) on
first publish via `ModulePublishTargetResolver` — no manual pre-registration
step.

## Credential delivery: extending the existing Vault-credential pattern

No prior mechanism delivered an **operator-supplied, opaque, third-party API
key** to an on-node systemd service. What already existed:

- `Security::VaultCredentialProvider` (`server/app/services/security/`) — a
  generic, account-scoped, type-keyed Vault-or-DB-fallback credential store.
  Already used for ACME DNS provider tokens, Docker daemon mTLS material,
  data-source API credentials, etc.
- `VaultCredential` concern (`server/app/models/concerns/`) — mixes the
  provider into any ActiveRecord model with a `vault_path` (+ optionally
  `encrypted_credentials`) column.
- `System::AcmeDnsCredential` + `AcmeDnsCredentialsController` — the closest
  precedent: operator POSTs plaintext, it's handed straight to
  `VaultCredentialProvider#store_credential` and never assigned to a model
  attribute, never serialized, never logged. No DB-fallback column at all
  (Vault-only; a Vault outage fails closed rather than ever landing the
  secret in Postgres).
- `Api::V1::System::NodeApi::*` — the on-node pull channel. Every endpoint is
  **mTLS-only** (`BaseController#authenticate_instance!` resolves the calling
  `NodeInstance` from the Traefik-forwarded, CA-verified client-cert CN — no
  bearer-token second auth surface). `LuksController` is the closest
  precedent for "issue secret material to the authenticated instance only."

This increment adds the smallest extension of that pattern:

1. `claude_code_api_key: "claude-code-api-keys"` — new entry in
   `Security::VaultCredentialProvider::CREDENTIAL_TYPES` (core `server/`).
2. `System::ClaudeCodeCredential` — one row per `NodeInstance`, Vault-only
   (mirrors `AcmeDnsCredential`'s no-plaintext-DB-fallback design).
3. `Api::V1::System::ClaudeCodeCredentialsController` — operator-facing CRUD
   at `/api/v1/system/nodes/:node_id/node_instances/:node_instance_id/claude_code_credential`,
   gated by `system.node_instance_credentials.{read,manage}`. Mirrors
   `AcmeDnsCredentialsController` exactly: plaintext in, Vault out, never a
   model attribute, never a response field, never a log line.
4. `NodeApi::ConfigController#claude_code_credential` — new mTLS-only read
   action at `GET /api/v1/system/node_api/config/claude_code_credential`,
   scoped strictly to `current_instance` (an instance can never read another
   instance's credential — same guarantee every other `node_api/config/*`
   action already has).

No Go agent changes. The module's own `claude-tmux-fetch-credential.sh`
(root, via `ExecStartPre=+...`) talks to the node_api directly with `curl
--cert/--key/--cacert` against the on-disk PKI material the agent already
wrote at enrollment (`/persist/var/lib/powernode/pki/` or
`/var/lib/powernode/pki/`), and resolves the platform URL by reading the
**same on-disk sources** the agent's own identity resolver reads, in the
same priority order (see `agent/internal/identity/*.go`): kernel cmdline →
qemu fw_cfg → `/boot/identity.cfg` → `/etc/identity.cfg`. This is read-only
shell re-derivation of already-on-disk boot facts, not a new capability —
the same philosophy `LuksController`'s agent-side callers already apply
(reading `/proc/mounts`, block-device metadata, etc. directly).

**Known gap:** cloud-provider metadata strategies (AWS/GCP/Azure/DO) are
*not* replicated in the shell script — only relevant for cloud-VM spawns,
not the Proxmox fleet this campaign targets. On a cloud-metadata-only
instance, `claude-tmux-fetch-credential.sh` fails closed (refuses to start
without a resolvable platform URL) rather than guessing.

## Secret handling inside the tmux session

`ExecStartPre=+.../claude-tmux-fetch-credential.sh` runs as **root** (needed
to read the agent's 0600 mTLS private key) and writes the fetched key to
`$RUNTIME_DIRECTORY/api_key` (`/run/claude-tmux/api_key`, systemd
`RuntimeDirectoryMode=0700`, chowned to the unprivileged session user).

`ExecStart=.../claude-tmux-start.sh` runs as the session user (`pnadmin` by
default) and starts the tmux session. The credential is **never passed as a
tmux/systemd argv** (would leak into `ps`/`/proc/<pid>/cmdline` for any local
user) — the pane's own shell reads-then-deletes the runtime file:

```sh
export ANTHROPIC_API_KEY="$(cat '/run/claude-tmux/api_key')"; rm -f '/run/claude-tmux/api_key'; exec claude
```

`export`/`rm`/command substitution are shell builtins/simple execs — the
key value itself never appears in any process's argv, and the runtime file
is deleted immediately after the one read that needs it.

## Failure taxonomy: "no credential" is a state, not a fault

`claude-tmux-fetch-credential.sh` distinguishes a *deliberately* uncredentialed
instance from a broken one, because only the second is worth retrying:

| Condition | Exit | Behaviour |
|---|---|---|
| Credential staged | `0` | stager succeeds; session starts |
| **HTTP 404 — no credential configured** | **`78`** (`EX_CONFIG`) | stager **succeeds having staged nothing** (`SuccessExitStatus=78`); the session unit is **skipped** by `ConditionPathExists` |
| Unenrolled, unresolvable platform URL, network/mTLS error, non-200, malformed response | `1` | stager fails, retried by `Restart=on-failure`, then held down by the start limit |

### Why the fetch is its own unit

The fetch runs as `ExecStart=` of a dedicated root oneshot
(`…-credential.service`), **not** as an `ExecStartPre=` of the session unit. That
is not stylistic. `RestartPreventExitStatus=` — and systemd's restart decision
generally — keys off the **main** process; an `ExecStartPre` is a *control*
process, so its exit code cannot prevent a restart. Measured on live systemd
(2026-08-17): exit `78` from `ExecStartPre` with `RestartPreventExitStatus=78`
set gave `NRestarts=5`, while the same exit from `ExecStart` gave `NRestarts=0`.
An earlier version of this module shipped exactly that inert directive.

The split lets each half use a mechanism that applies. The stager's exit *is* a
main-process exit, so `SuccessExitStatus=78` makes "no credential configured" a
clean success rather than a fault to retry. The session unit is then gated with
`ConditionPathExists=/run/claude-tmux/api_key`: **a false condition is not a
failure**, so systemd skips the unit with no restart, no `failed` state, and no
`type=1130 … res=failed` audit record at all.

An instance with no credential is the **intended steady state** — the
`dev_cell_account_provider_credential_fallback` SiteSetting defaults OFF (inc21,
2026-07-10) precisely so an idle cell cannot burn API credits. Before this split
that designed state exited `1` like any transient fault, so `Restart=on-failure`
turned it into an unbounded crash loop: one full mTLS handshake against the
control plane every `RestartSec` forever (~17k/day per idle cell), with the
journal and audit-log noise masking real failures. The stock start limit could
not stop it either — systemd's defaults (`10s`/`5`) are unreachable against
`RestartSec=5s`, since only ~2 starts fit in a 10s window. Both units now
declare a reachable `StartLimitIntervalSec`/`StartLimitBurst` **in `[Unit]`**
(systemd silently ignores them in `[Service]`).

So on a healthy uncredentialed cell you should expect **no** `res=failed` audit
records from these units at all — the stager succeeds and the session is
skipped. Any `res=failed` here is a genuine fault; read the journal line, it
names which branch fired. (Before the unit split this state produced an
unbounded stream: 717 restarts in one boot, one mTLS handshake against the
control plane every 5s.)

The same taxonomy and the same unit split govern `dev-cell`'s `executor`, which
reuses this script for its own `ANTHROPIC_API_KEY` and is gated on
`/run/dev-cell/api_key`.

## Operator runbook

Set the credential for an instance (one-time; until it exists the stager stages
nothing and the session unit is skipped). The staged credential lives in tmpfs
and is read-then-deleted, so after setting one either reboot the instance or
start the stager and then the session:

```bash
# discover the real unit names — never type a guessed one
systemctl list-units 'powernode-*-credential.service' 'powernode-*-claude.service' \
  --no-pager --no-legend --all
systemctl start <module>-credential.service && systemctl start <module>-claude.service
```

```javascript
// POST /api/v1/system/nodes/:node_id/node_instances/:id/claude_code_credential
{ "api_key": "sk-ant-..." }
```

Rotate:

```javascript
// POST .../claude_code_credential/rotate
{ "api_key": "sk-ant-new-..." }
```

Assign the module to a template (or a single instance's node — see the
"Known platform gap" note below), then restart the module's service on the
instance:

```javascript
platform.system_assign_module_to_template({ template_id: "<id>", module_id: "<claude-tmux id>" })
```

On the instance:

```bash
systemctl restart claude-tmux
tmux -L claude-tmux attach -t claude-code
```

## Known platform gap (not this increment's to fix)

`System::TemplateApplyService` (materializes `NodeModuleAssignment` rows from
a template's module closure) has no caller in the node-provisioning path —
only a manual `POST /api/v1/system/nodes/:id/apply_template` operator
endpoint reaches it. Assigning claude-tmux to a template does not by itself
land it on a freshly-spawned instance today; the operator (or a follow-up
platform fix) must also call `apply_template`. Tracked separately in this
campaign, same as every other module this increment's sibling work depends
on.

_Last verified: 2026-07-06._
