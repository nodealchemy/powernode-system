# claude-tmux NodeModule

> Status: active — increment 20, campaign 019f3458.

Managed Claude Code CLI in a named, systemd-supervised tmux session on a
fleet instance. Survives SSH disconnects; the operator reconnects with
`tmux -L claude-tmux attach -t claude-code`. The credential — an
Anthropic API key, **or** a Claude-subscription OAuth login (see
[Credential kinds](#credential-kinds-api-key-or-claude-subscription-oauth-seed-once))
— is Vault-injected at boot: never baked into the module image, never in
an env file, never logged. Reusable standalone; increment 21's managed
dev-cell is its first consumer.

## Hosting pattern: in-tree, not standalone

[`docs/runbooks/module-authoring.md`](./runbooks/module-authoring.md) documents
a per-repo "standalone module" pattern (`templates/module-repo/` skeleton, its
own Gitea repo, its own `.gitea/workflows/build.yaml`, webhook-triggered ingest
via `ModuleOciIngestService` — see [module-authoring.md](./runbooks/module-authoring.md#troubleshooting)
for the trigger mechanism). This module does **not** use that pattern — it
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

## Credential kinds: API key or Claude-subscription OAuth (seed-once)

A `System::ClaudeCodeCredential` is one of two kinds (`credential_kind`
column, declared by which param the operator POSTs — exactly one):

| | `api_key` (default) | `oauth` |
|---|---|---|
| Operator supplies | an Anthropic API key (`api_key` param) | the `claudeAiOauth` object from a logged-in machine's `~/.claude/.credentials.json` (`oauth` param; the full file shape `{"claudeAiOauth": {...}}` is also accepted) |
| Vault type | `claude_code_api_key` | `claude_code_oauth` (distinct type ⇒ distinct Vault path; rotations are independent) |
| Node staging | `/run/claude-tmux/api_key`, read-then-deleted into `ANTHROPIC_API_KEY` by the pane | installed as the session user's `~/.claude/.credentials.json` (0600) + an empty `/run/claude-tmux/oauth_ready` gate marker |
| Env var | `ANTHROPIC_API_KEY` exported in the pane | **never** exported — an env key would override the OAuth login |
| File deletion | staged file deleted after the one read | **never** deleted — Claude Code reads and rewrites it continuously |
| Who is authoritative after first boot | the platform (every boot re-fetches) | **the node** (seed-once; see below) |

The kind travels end-to-end as an explicit discriminator: the node_api
response carries `data.credential_type` (`"api_key"`/`"oauth"`) and the
fetch script branches on it — nothing is ever inferred from which fields
happen to be present. The `api_key` wire shape (`data.api_key`) is
unchanged, so fetch scripts built before OAuth keep working for api_key
credentials.

### Why seed-once (and what "stale by design" means)

Claude Code's OAuth login has **no environment-variable equivalent** — the
`~/.claude/.credentials.json` file *is* the interface, and Claude Code
**rewrites it in place** whenever it refreshes: the access token is
replaced, and the refresh token itself rotates with its own expiry. That
forces an explicit authority decision, because a naive "re-fetch from
Vault every boot" would overwrite freshly-rotated local tokens with the
old Vault snapshot — installing a **used** refresh token and silently
killing the session weeks after everything looked fine.

The chosen model is **seed-once / node-authoritative**:

- **Vault holds a bootstrap seed, nothing more.** The fetch script installs
  it **only when no usable local credential exists** (fresh node, wiped
  home, or a corrupt/unusable file — "usable" = parseable JSON whose
  `.claudeAiOauth.refreshToken` is a non-empty string).
- **After first install the node owns the credential.** Claude Code
  refreshes it locally; the platform copy is stale from that moment **by
  design** and is never pushed back onto the node. A usable local file is
  never touched, ever.
- Alternatives were rejected deliberately: *platform-authoritative*
  refresh would require implementing Anthropic's (undocumented) refresh
  flow server-side and would still race the node, because Claude Code
  refreshes locally regardless; *node write-back to Vault* would grant
  every node write access to its own credential (a compromised node could
  poison the seed) and still has the same race.

Operational consequences of seed-once:

- **The platform cannot revoke a seeded node, and an outage cannot stop
  one.** Once a usable local credential exists the fetch stages the
  session gate from it even when the platform answers 404 (row deleted)
  or is unreachable — a control-plane outage must not take down the one
  session it cannot help anyway. To revoke a node's access, remove the
  node's `~/.claude/.credentials.json` (and/or revoke the login at
  Anthropic); deleting the platform credential row only stops FUTURE
  seeding.
- **A kind flip takes effect on the next successful fetch, not during a
  fault.** The continuity fallback keys on the local file (the platform's
  declared kind is unknowable without a 200), so after an oauth→api_key
  flip a transient fault briefly starts the session on the leftover
  subscription login; both edges are narrow and self-heal on the next
  successful fetch. Future hardening: gate the fallback on the last-known
  platform kind.
- **A parseable-but-dead local file blocks re-seeding.** "Usable" is a
  shape check (non-empty `refreshToken`), not a liveness probe — if the
  local refresh token was revoked or expired, `rotate` is silently
  ineffective (the node keeps preferring its local file). Recovery:
  delete `~/.claude/.credentials.json` on the node, then
  `systemctl start` the credential + claude units to install the fresh
  seed.

- **Re-provisioning (or a wiped/ephemeral home) re-installs the Vault
  seed.** If the node's local copy had since rotated the refresh token,
  the seed may no longer authenticate — `rotate` the credential with a
  fresh `claudeAiOauth` blob from a logged-in machine, then
  `systemctl start` the credential + claude units.
- **The Vault copy going stale is not a fault.** Do not "fix" it by
  re-pushing the seed onto a working node; that is exactly the clobber
  this design exists to prevent.
- The seed is validated at POST time: `accessToken`/`refreshToken`
  required, `expiresAt` must be epoch **milliseconds** (an expired access
  token is fine — the refresh token is the lifeline), and a
  `refreshTokenExpiresAt` already in the past is rejected outright (a
  dead seed can never authenticate).

**Scope note:** OAuth kind is consumed by **claude-tmux only** today. The
`dev-cell` executor reuses the same fetch script but its pipeline expects
`ANTHROPIC_API_KEY` and its gate only accepts `/run/dev-cell/api_key` — an
oauth-kind credential on a dev-cell instance stages the file + marker but
the executor unit stays (correctly) skipped. Give dev-cell instances an
api_key-kind credential (or the account-provider fallback).

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
// API-key kind:
{ "api_key": "sk-ant-..." }
// — OR — OAuth (Claude subscription) kind: paste the claudeAiOauth object
// from a logged-in machine's ~/.claude/.credentials.json (the full file
// shape {"claudeAiOauth": {...}} is accepted too). Copy it privately —
// never through shell argv/history (e.g. paste into the request body in
// the operator UI, or read the file directly in your HTTP client).
{ "oauth": { "accessToken": "...", "refreshToken": "...", "expiresAt": 1234567890123, "refreshTokenExpiresAt": 1234567890123, "scopes": ["user:inference"], "subscriptionType": "max" } }
```

Rotate (same kind only — switching kinds is a deliberate `DELETE` + `POST`
so the old kind's Vault entry is always cleaned up):

```javascript
// POST .../claude_code_credential/rotate
{ "api_key": "sk-ant-new-..." }   // or { "oauth": {...} } for an oauth-kind credential
```

For an **oauth** credential, `rotate` replaces only the *Vault seed* —
seed-once means a node with a usable local credential ignores it until
its local copy is gone/unusable (see
[Why seed-once](#why-seed-once-and-what-stale-by-design-means)).

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

_Last verified: 2026-07-06 (credential kinds + seed-once OAuth: 2026-08-24)._
