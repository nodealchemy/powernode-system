# `grok-cli` NodeModule

Ships xAI's official **Grok Build CLI** (`@xai-official/grok`) as `/usr/bin/grok` on a fleet
instance, plus a boot-time credential fetch that stages the instance's xAI API key from the
platform over mTLS.

Sibling of [`claude-tmux`](./CLAUDE_TMUX_MODULE.md), and deliberately **not** the same shape.
Read the [Why there is no session](#why-there-is-no-session) section before adding one.

| | |
|---|---|
| Module slug | `grok-cli` |
| Category | `build-dev` |
| Payload | `@xai-official/grok`, version-pinned in `build.grok_version` |
| Binary | `/usr/bin/grok` (npm `--prefix /usr`) |
| Requires | `powernode-system-base`, `capability:os.userland`, `capability:runtime.node` |
| Provides | `dev.grok-cli` |
| Services | one: `credential` (root oneshot) |
| Egress | `api.x.ai` |
| `reboot_required` | `false` — hot-applies on a pivot-boot node |

---

## Why there is no session

`claude-tmux` supervises a long-running `claude` inside a systemd-managed tmux session. This
module does not, and that is the design, not an omission.

An always-on agent on a warm cell **spends money while nobody is looking**. That is not
hypothetical: idle dev-cells burned two credit autorefills before the account-provider fallback
was made opt-in (inc21, 2026-07-10). Shipping a second always-on agent would reintroduce exactly
that, doubled.

So this module ships the tool and the key and stops. Consumers invoke it:

```sh
grok -p "explain this failure"          # headless, one shot
grok                                    # interactive
```

If a supervised Grok session is ever genuinely wanted, it belongs in a **separate** module that
composes this one — so the expensive half can be assigned, unassigned, and reasoned about on its
own.

---

## Credential delivery

```
Operator sets a key                 Node boots
        │                                │
        ▼                                ▼
System::ClaudeCodeCredential     powernode-<uuid>-credential.service (root, oneshot)
  provider_type: "grok"    ──►     /usr/local/bin/grok-cli-fetch-credential.sh
  (Vault-backed)                          │  mTLS, node cert
        │                                 ▼
        └── or ── account's active   GET /api/v1/system/node_api/config/
                  grok Ai::Provider       ai_cli_credential?provider_type=grok
                  (opt-in, see below)     │
                                          ▼
                                   /run/grok-cli/api_key  (0600, pnadmin)
                                          │
                                          ▼
                                   /etc/profile.d/grok-cli.sh → export XAI_API_KEY
```

The key is **never** baked into the module image, never written to an env file, and never logged.
It moves jq→file inside the fetch script — never through a shell variable or an argv, either of
which could surface in `ps`, a trace, or an error message.

### Resolution order

1. **Per-instance credential** — a `System::ClaudeCodeCredential` row with
   `provider_type: "grok"`, stored in Vault (or the encrypted DB column on a Vault-less
   deployment). An operator sets this deliberately, so a broken/empty Vault for such a row is a
   **503**, never a silent fall-through to the account key.
2. **Account provider fallback** — the account's active `grok` `Ai::Provider` credential.
   **Opt-in, default OFF.**
3. Neither → **404**, which the node treats as a designed steady state (exit 78), not a fault.

### Enabling the account fallback

```ruby
SiteSetting.set("grok_cli_account_provider_credential_fallback", true, setting_type: "boolean")
```

There is no seed for this key, and that is deliberate: `SiteSetting.get` on an absent key returns
`nil`, so **the fallback is off until someone turns it on**. Absence is the safe default and needs
no migration to stay that way.

It is a *separate* flag from `dev_cell_account_provider_credential_fallback` (the Anthropic one)
because the flag is a **spend authorization** — "let dev-cells draw on the account's Anthropic
budget" is not the same decision as "let them draw on the xAI budget", and one should never
silently grant the other.

---

## Exit-code contract

The fetch script's exit codes are contract — the unit branches on them.

| Code | Meaning | Unit behavior |
|---|---|---|
| `0` | Key staged at `/run/grok-cli/api_key` | `active (exited)` |
| `78` | `EX_CONFIG` — no credential configured for this instance | **Success** (`SuccessExitStatus=78`). No restart, no `failed` state, no `type=1130 res=failed` audit record. |
| `1` | Transient: unenrolled, unresolvable platform URL, network/mTLS error, non-200/404, malformed response | `Restart=on-failure`, `RestartSec=30s` |

`78` is a *designed state*, not a fault: an instance with no key is a supported configuration and
restarting cannot fix it. After setting a credential, re-arm with `systemctl start <unit>`.

`SuccessExitStatus`, **not** `RestartPreventExitStatus` — the latter is inert for a control
process. Measured on live systemd 2026-08-17: exit 78 from an `ExecStartPre` with
`RestartPreventExitStatus=78` still produced `NRestarts=5`; the same exit from `ExecStart` produced
`NRestarts=0`. This unit's script *is* its main process, so its code governs directly.

---

## Operating

### Find the unit — never guess its name

The agent generates `powernode-<module-uuid>-credential.service`. A guessed name does not error:
`systemctl restart` on a nonexistent unit fails silently inside a `||` chain, leaving you certain
of a restart that never happened.

```sh
systemctl list-units 'powernode-*-credential.service' --no-pager --no-legend
systemctl is-active <the unit you just discovered>
```

### Verify the CLI

```sh
command -v grok       # must be /usr/bin/grok
grok --version
```

Check in **both** a login and a non-login shell. The manifest's `verify.probes` block does exactly
this on every heartbeat, and it is not optional: the login/non-login divergence is the VM-9000 bug
class, and this module ships a `/etc/profile.d` file that only login shells source.

### Confirm the key is staged

```sh
ls -l /run/grok-cli/api_key    # 0600, owned by pnadmin
```

**Never `cat` it.**

### `grok` fails with a connection error

Check the manifest before the network. The agent unions every module's `egress_allow` into one
node-wide nftables **default-deny** chain — an `ECONNREFUSED` to `api.x.ai` is this manifest, not
a fault. Note also that entries resolve to A/AAAA at install time and re-resolve only on
cert-rotate (~67 days); `api.x.ai` sits behind a CDN whose addresses rotate, so a stale-IP symptom
can recur looking identical. The interim unstick is a reconcile or cert-rotate; the durable fix is
DNS-aware egress.

---

## Building

Version pin lives in `build.grok_version` and is read by the `grok-cli` case in
`scripts/module-build/stage15.sh`. Three guards there are fatal, and all three exist because
something shipped without them:

1. the CLI must have installed into `/tmp/fat/usr` at all;
2. the installed `package.json` `.version` must equal the pin;
3. a `@xai-official/grok-linux-*` platform package must be present.

(3) is specific to this package and has no counterpart in the `claude-tmux` arm: the real
executable arrives via a platform-specific **optionalDependency**, and npm treats a failed
optional dependency as a *success*. Without that guard a registry hiccup ships a wrapper with
nothing behind it — a `grok` that resolves on PATH and cannot run.

Bump the pin deliberately. Unlike a release-binary fetch there is no single sha256 to verify; the
exact npm version plus npm's own integrity metadata is the reproducibility unit.

---

## Related

- [`CLAUDE_TMUX_MODULE.md`](./CLAUDE_TMUX_MODULE.md) — the sibling module and the source of most of
  this one's mechanics
- [`runbooks/module-authoring.md`](./runbooks/module-authoring.md)
- [`MODULE_MANIFEST_COMPLETE_SCHEMA.md`](./MODULE_MANIFEST_COMPLETE_SCHEMA.md)
