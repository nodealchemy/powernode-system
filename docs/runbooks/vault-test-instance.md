# Runbook — Vault test instance

> Status: active
> Audience: platform maintainers exercising the platform's Vault-backed paths
> Prerequisites: the `vault` NodeModule built and published; a NodeInstance
> whose template composes it (the dev-cell does); operator shell on that node
> Runtime: ~20 min for first init, ~2 min per reboot (unseal)

Stands up a **real, sealed** HashiCorp Vault on a fleet instance so the
platform's Vault-dependent code paths can be exercised without the shared
`vault.ipnode.org`, which has been sealed since 2026-07-29 and whose unseal
keys are operator-held.

What this unblocks:

| Path | Code |
|---|---|
| Module signing via transit | `System::ModuleSigningService` in `"vault"` mode |
| Generic secret read/write | `Security::VaultClient` |
| Signing-key custody | `System::ModuleSigningKey` |
| DR drill | [vault-credential-restoration.md](./vault-credential-restoration.md) |

## Why not `vault server -dev`

Dev mode auto-unseals with an in-memory backend and prints a root token to
the journal. Publishing a module **auto-promotes it fleet-wide** (the
built → staging → blessed ladder is decorative — see the module plane's
promotion notes), so a self-unsealing Vault with a well-known root token
would be one template assignment away from any node.

This module ships **production mode with file storage**: it starts sealed
and stays sealed until an operator runs `vault operator init` /
`vault operator unseal`. Manual unseal after every reboot is the point, not
an omission.

## Rules that are not negotiable

- **Never pass an unseal key or the root token as a command argument.**
  `vault operator unseal` with no argument prompts and reads the key from the
  terminal without echoing it. An argument lands in shell history, in
  `/proc/<pid>/cmdline`, and in any process listing.
- **Never echo, log, or paste key material into a ticket, a commit, an MCP
  call, or a chat message.** Capture `vault operator init` output once, to an
  operator-held file with mode `0600`, outside any repo.
- Key **generation** happens inside Vault. Nothing here generates a private
  key on the box (`cosign generate-key-pair` belongs to the separate
  `"local"` signing mode, which is not what this runbook configures).

## 1 · Where it runs and why it is loopback-only

`vault.hcl` binds `127.0.0.1:8200` with `tls_disable = 1`. That is
deliberate: all three consumers (`ModuleSigningService`, `VaultClient`,
`ModuleSigningKey`) run **inside a Rails process**, so co-locating Vault with
the dev-cell makes every call a loopback call. The agent's egress policy
accepts `oif lo` unconditionally
(`agent/internal/security/egress.go`), so the module needs no
`egress_allow` entry and no firewall exception.

Reaching it over SDWAN + TLS instead is circular: `Acme::CertificateManager`
round-trips its own credentials through Vault, so the cert you would need to
protect the listener depends on the listener already working.

Widening the listener is an operator edit to **both** `vault.hcl` and the
module's `services[].exposed_ports`, and must not be done while
`tls_disable` is set.

## 2 · Assign the module

The dev-cell template composes it — `vault` is in `DEV_CELL_MODULES`
(`server/db/seeds/powernode_dev_cell.rb`). For any other template, assign it
the same way as any module (see
[template-authoring.md](./template-authoring.md)).

The NodeModule row itself comes from the manifest loader seed, which is
**not** in `SYSTEM_SEED_FILES` and therefore never runs on its own:

```bash
cd /home/pnadmin/work/server && bundle exec rails runner \
  "load Rails.root.join('../extensions/system/server/db/seeds/powernode_platform_modules.rb')"
```

## 3 · First boot — initialise

On the node:

```bash
export VAULT_ADDR=http://127.0.0.1:8200
vault status          # expect: Initialized false, Sealed true
```

Initialise. For a **test** instance one share is enough — the threat model
here is "don't hand out a self-unsealing Vault", not "survive a custodian
going rogue":

```bash
umask 077
vault operator init -key-shares=1 -key-threshold=1 > ~/vault-init.txt
chmod 0600 ~/vault-init.txt
```

`~/vault-init.txt` now holds the unseal key and the initial root token.
Move it to operator-held storage and delete the copy on the node. Do not
`cat` it into a terminal that is being recorded.

Unseal (prompts; no argument):

```bash
vault operator unseal
vault status          # expect: Sealed false
```

Log in with the root token the same way — `vault login` with no argument
prompts for it.

**Every reboot repeats the unseal step.** The storage backend lives under
`/persist/var/lib/vault/data`, which survives; the seal does not.

## 4 · Enable the engines the platform expects

### Transit (module signing)

```bash
vault secrets enable transit
vault write -f transit/keys/powernode-module-signing type=ecdsa-p256
```

- Mount `transit` is `Security::VaultTransitClient::DEFAULT_MOUNT`.
- Key name `powernode-module-signing` is
  `System::ModuleSigningService::DEFAULT_KEYNAME`. It is **config, not a
  secret** — the name alone grants nothing; only an authenticated session can
  invoke `transit/sign` against it. Override via the SiteSetting
  `system.module_signing.keyname` if you need a different one.

### KV v2 (secrets)

```bash
vault secrets enable -path=secret -version=2 kv
```

`VaultClient` builds KV paths as `secret/data/powernode/...`
(`#build_credential_path`, `#store_system_secret`), i.e. **KV v2 mounted at
`secret`**. Note that `Security::SecretStore#path_for` builds
`powernode/secret-store/<account>/<scope>/<key>` with no `secret/data/`
prefix — that shape needs its own mount and does not resolve against the
mount above. Only enable a second mount if you are specifically exercising
`SecretStore`.

## 5 · AppRole for the platform

`VaultClient#fetch_app_token` authenticates by AppRole and raises
`"VAULT_ROLE_ID not configured"` on a Vault-less plane, so this step is what
turns the plane on.

```bash
vault auth enable approle

vault policy write powernode-platform - <<'POLICY'
path "transit/sign/powernode-module-signing"   { capabilities = ["update"] }
path "transit/verify/powernode-module-signing" { capabilities = ["update"] }
path "transit/keys/powernode-module-signing"   { capabilities = ["read"] }
path "secret/data/powernode/*"                 { capabilities = ["create","read","update","delete","list"] }
path "secret/metadata/powernode/*"             { capabilities = ["read","list","delete"] }
POLICY

vault write auth/approle/role/powernode-platform \
  token_policies=powernode-platform token_ttl=1h token_max_ttl=4h
```

Read the credentials **without printing them to the terminal**:

```bash
umask 077
vault read -field=role_id   auth/approle/role/powernode-platform/role-id   > ~/vault-approle.role_id
vault write -f -field=secret_id auth/approle/role/powernode-platform/secret-id > ~/vault-approle.secret_id
```

Transfer both to the operator, then delete the node-side copies.

## 6 · Wire the platform to it

The platform reads Vault config from the `AdminSetting` row `vault_config`
(`Security::VaultClient.admin_setting_config`), falling back to `VAULT_ADDR`
/ `VAULT_ROLE_ID` / `VAULT_SECRET_ID` in the environment. Set it through the
**admin UI** (Infrastructure → Vault), not through `rails runner` — a
`secret_id` typed at a rails console lands in shell history and in the
console's own log.

Keys:

| Key | Value |
|---|---|
| `vault_addr` | `http://127.0.0.1:8200` (loopback, same box as Rails) |
| `vault_role_id` | from step 5 |
| `vault_secret_id` | from step 5 |

`VAULT_SKIP_VERIFY` is irrelevant on plain HTTP loopback; leave it unset.

## 7 · Verify

Read-back of a value the platform itself wrote is the honest end-to-end
check. From the node:

```bash
vault kv put  secret/powernode/system/runbook-probe value=ok
vault kv get  -field=value secret/powernode/system/runbook-probe   # => ok
vault kv metadata delete secret/powernode/system/runbook-probe
```

Then the transit round trip that module signing depends on — this is the one
that has **never been executed end to end** on any plane, because key
generation is Vault-only and no Vault was reachable:

```bash
cosign sign-blob --yes --key hashivault://powernode-module-signing \
  /path/to/a/test/blob > /tmp/sig.b64
cosign verify-blob --key hashivault://powernode-module-signing \
  --signature /tmp/sig.b64 /path/to/a/test/blob
```

`cosign` inherits `VAULT_ADDR` + `VAULT_TOKEN` from the environment
`ModuleSigningService#sign_env` builds — it is handed a **session token**,
never key material, and never via argv.

Do not enable signature enforcement until this round trip passes. The
enforcement ladder and its gates are in
[module-signature-verification.md](./module-signature-verification.md);
`promotion_criteria.rb`'s `REQUIRE_SIGNATURE_KEY` requires an explicit
`true`, so the default stays off.

## 8 · Day-2

**Reboot.** Unseal again (step 3). The service is `restart_policy: always`,
so Vault comes back sealed on its own; nothing else is needed.

**Config change.** `/etc/vault.d/vault.hcl` is in the module's
`protected_spec`, so a module refresh will not clobber an operator edit.
`vault-start.sh` prefers `/persist/etc/vault.d/vault.hcl` when it exists —
put persistent overrides there, since only `/persist` survives a recompose.

**Seal it.** `vault operator seal` — instant, reversible, and the right move
before any maintenance on the node.

**Destroy it.** Removing the module does not remove the data. Delete
`/persist/var/lib/vault` explicitly if the instance is being handed on.

## Troubleshooting

| Symptom | Cause |
|---|---|
| Unit dies immediately, journal says `/persist is not a mountpoint` | The wrapper refuses to start before `/persist` mounts — this is the guard working. Check the storage attachment, not Vault. |
| `failed to lock memory` at startup | `CAP_IPC_LOCK` did not survive the privilege drop. The wrapper uses `setpriv --ambient-caps=+ipc_lock`; a `runuser`-style drop clears ambient caps and would fail exactly this way. |
| `/v1/sys/health` returns 503 | Normal for a **sealed** Vault. This is why the module declares no `services[].health` probe — a health gate would fail every node after every reboot. |
| `VAULT_ROLE_ID not configured` in Rails | Step 6 was skipped, or `vault_config` holds a blank `vault_role_id`. |
| `permission denied` on `transit/sign` | The AppRole policy in step 5 was not applied, or the keyname differs from `system.module_signing.keyname`. |

## OpenBao

The Vault binary is BUSL-1.1 (HashiCorp relicensed at 1.15). Shipping it
inside a module for internal platform testing is within the Additional Use
Grant; it is **not** MIT-compatible and must not be described as such
wherever the platform asserts its own MIT licensing.

OpenBao (MPL-2.0, the community fork of Vault 1.14) covers the transit + KV
paths this module exists to exercise, but swapping to it is **not** a
version/URL edit: the binary is `bao`, the release naming and checksums
differ, and the stage-1.5 exec check greps `VAULT_VERSION`. It would be a
sibling `openbao` module, not a rename of this one. The credential-
restoration runbook also targets HashiCorp Vault specifically.
