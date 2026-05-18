# Vault Credential Restoration Runbook

Disaster-recovery runbook for the platform's credential storage layer. Operator companion to [`credential-restoration.md`](../credential-restoration.md) (which covers the design). This runbook focuses on hands-on backup, restoration, and audit verification procedures.

**Audience:** platform admins, security operators, on-call SREs handling DR drills or actual data-loss incidents.

## Why this matters

Powernode stores three classes of secrets:

| Class | Examples | Where stored | Restorable? |
|---|---|---|---|
| **Account encryption keys** | The per-account encryption key used to encrypt user-supplied secrets at rest | Vault transit (KV v2) + DB fallback | ✅ Yes (via Vault transit pepper restoration) |
| **mTLS client/server keypairs** | NodeCertificate, NodeInstancePeer, Devops::DockerHost TLS material | Vault KV v2 (per-instance namespacing) | ✅ Yes (via Vault KV restore + re-issue if expired) |
| **Bootstrap tokens** | Single-use tokens for NodeInstance enrollment | DB-only; intentionally short-lived | ❌ No — by design (re-issue at need) |

Loss of Vault means: any encrypted user-supplied secret (API keys, OAuth tokens, etc.) becomes unreadable. Loss of DB means: bookkeeping gone but Vault state survives. The double-loss case requires backup tape or accepting permanent loss.

## Prerequisites

Per memory `project_vault_pki_state.md`:

- Vault is deployed via `docs/infrastructure/vault-example/`
- Uses **manual Shamir unseal** + KV v2 + AppRole
- **NO PKI engine** mounted yet — `M0.N InternalCaService.VaultCaAdapter` blocked on production until `pki_int` + auto-unseal lands
- `LocalCaAdapter` works for tests/dev

For production restoration, you need:

- The **Shamir keys** (typically 5 keyholders, 3 of 5 threshold) — distributed via the original install procedure
- **Vault snapshot** stored offsite (e.g., S3 with KMS encryption + versioning + MFA delete)
- **DB backup** (logical pg_dump or PITR via WAL-E / pgBackRest)
- The **AppRole role-id + secret-id** for the platform's read access (used to verify post-restore)

## Phase 1 — Backup ✅

Run regularly (daily or per-change for critical accounts).

### Vault snapshot

```bash
# On the Vault server (or via Vault CLI with appropriate ACL)
vault operator raft snapshot save /backups/vault-snapshot-$(date +%Y%m%d).snap

# Encrypt (Vault snapshots contain unencrypted KV data when unsealed)
gpg --symmetric --cipher-algo AES256 \
  --output /backups/vault-snapshot-$(date +%Y%m%d).snap.gpg \
  /backups/vault-snapshot-$(date +%Y%m%d).snap

# Upload to offsite
aws s3 cp /backups/vault-snapshot-$(date +%Y%m%d).snap.gpg \
  s3://powernode-backups/vault/ \
  --sse aws:kms --sse-kms-key-id <kms-key>
```

### DB snapshot

```bash
# Logical (clean, easier restore; takes longer for large DBs)
pg_dump -Fc -d powernode_production > /backups/db-$(date +%Y%m%d).dump

# Or PITR via pgBackRest (preferred for production)
pgbackrest --stanza=powernode backup --type=full
```

### Shamir keys

The Shamir keys MUST live offline, distributed across ≥3 trusted holders. Refresh them on a known cadence (annually) via `vault operator rekey` and redistribute. Keep them OUT of:
- Source code, env files, anything in git
- Cloud storage (S3, GCS, Azure Blob — even encrypted)
- Operator laptops alone (single-machine loss = key loss)

Recommended: hardware security keys (Yubico) or printed shards in a fireproof safe.

## Phase 2 — Disaster scenarios

### Scenario A: Platform DB lost, Vault intact ✅

- All secrets in Vault are intact.
- Bookkeeping (which secret belongs to which account/agent/host) is gone.
- Re-create the DB schema from migrations; restore from PITR or pg_dump; the `VaultCredential` concern's `vault_path` columns drive Vault key lookup → secrets are readable again.

### Scenario B: Vault lost, DB intact ⚠️

- DB has fallback ciphertext for some credential types (per `project_credential_pattern` — Vault-first with DB fallback).
- Account encryption keys: only DB fallback, encrypted by a **per-account encryption key derived from a Vault transit pepper**. Without Vault, you cannot decrypt user-supplied secrets stored in DB.
- mTLS keys: NodeCertificate rows have the cert chain in DB; private keys are Vault-only. New cert issuance possible; existing private keys lost (revoke + re-issue all instances).

### Scenario C: Both lost ❌

- If you have offsite Vault snapshot + offsite DB backup: full recovery, see Phase 3.
- If you don't: account encryption keys are unrecoverable; treat all encrypted user secrets as lost; reset accounts.

## Phase 3 — Restore from backup ⚠️

### Step 1: Bring up a fresh Vault cluster

```bash
# Provision new Vault server(s) per docs/infrastructure/vault-example/
# Initialize from snapshot:
vault operator init -recovery-shares=5 -recovery-threshold=3 -recovery-pgp-keys=...

# Restore the snapshot (server must be running but unsealed and unauthorized)
vault operator raft snapshot restore /backups/vault-snapshot-<date>.snap

# Unseal with Shamir keys (3 of 5)
vault operator unseal <key-1>
vault operator unseal <key-2>
vault operator unseal <key-3>
# → vault is unsealed and serves requests
```

### Step 2: Restore DB

```bash
# pg_dump:
createdb powernode_production
pg_restore -d powernode_production /backups/db-<date>.dump

# Or pgBackRest restore to PITR:
pgbackrest --stanza=powernode --type=time --target="2026-05-04 10:00:00 UTC" restore
```

### Step 3: Bring up the platform

```bash
sudo systemctl start powernode.target
sudo scripts/systemd/powernode-installer.sh status
```

The Rails app reads Vault via `Security::VaultCredentialProvider` on first secret access; verify by hitting an account-scoped endpoint that decrypts a user secret (e.g., a billing payment processor key).

## Phase 4 — Verify decryption + audit trail ✅

```bash
# As an operator:
curl -H "Authorization: Bearer $JWT" https://platform.ipnode.org/api/v1/accounts/<id>/credentials
# → returns metadata only (NEVER the actual secret values per `cryptographic_material_safety` rules)

# Verify a known credential decrypts (e.g., billing test mode key):
curl -X POST -H "Authorization: Bearer $JWT" https://platform.ipnode.org/api/v1/billing/test-charge
# → if this succeeds, the encryption stack is functional
```

For each credential type, log a verification event:

```javascript
platform.create_learning({
  title: "DR restoration verified",
  category: "discovery",
  content: "Restored from snapshot 2026-05-03; all 47 account encryption keys decrypted on first access; mTLS handshake verified on 3 sample instances; billing test charge succeeded. Total downtime: 23 min.",
  tags: ["dr", "vault", "restoration"]
})
```

`System::FleetEvent` records every Vault credential access via the
`vault.credential.*` event kinds — confirm via:

```ruby
System::FleetEvent.where("kind LIKE 'vault.credential.%'")
  .order(occurred_at: :desc).limit(100)
  .pluck(:account_id, :kind, :payload, :occurred_at)
```

Deployments with a parent-platform audit table (e.g. when the platform
bundles a private audit extension) may have richer per-action logs there;
consult the platform's audit-extension docs for that path.

For full SOC2 / compliance evidence, dump the audit log over the DR window and archive.

## Phase 5 — Key rotation ✅

Annual cadence for the Vault transit pepper. The `CredentialRestorationService` (per memory `project_credential_pattern`) handles re-encryption transparently:

```javascript
platform.system_rotate_vault_transit_pepper({
  scheme: "v2",                                 // bumps version label on transit key
  reencrypt_existing: true                      // walks all per-account keys; re-encrypts
})
// → { rotated_count: 47, status: "in_progress", task_id }
```

Re-encryption is online — the service walks accounts in batches, decrypts with old pepper, re-encrypts with new pepper, atomically swaps. No downtime; no operator action required after kicking off.

**Verify completion:**

```bash
# All accounts should have current transit_key_version
SELECT account_id, transit_key_version FROM accounts WHERE transit_key_version != '<current>';
# → empty result = all rotated
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `VaultUnreachableError` after restore | Vault snapshot restore complete but service didn't fully come up | `vault status` → confirm unsealed; `systemctl status vault` |
| `DecryptionFailedError` on account secret access | Vault transit key version mismatch (DB has v1, Vault has v2) | Run `system_rotate_vault_transit_pepper` to align |
| Some accounts decrypt; others fail | Per-account namespacing — incremental partial restore | Check `accounts.transit_key_version` for the failing account vs Vault state |
| mTLS handshakes fail after restore | Private keys expired during the outage | Run `system.cert_rotate` autonomy action (auto_approve policy) — re-issues all certs from current InternalCaService |
| Audit log gap covers the restoration window | Expected — no audit during downtime | Document the DR window explicitly in the restoration learning |
| Bootstrap tokens all expired | Expected — they're short-lived by design | Re-issue per-instance via `system_provision_instance` with `regenerate_bootstrap: true` |

## Anti-patterns (don't do this)

- ❌ Storing Shamir keys in a single git repo / secret manager (defeats the point of Shamir)
- ❌ Skipping Vault snapshot encryption (snapshots contain unencrypted KV when taken from an unsealed Vault)
- ❌ Manually editing `accounts.encrypted_data` in production to "fix" decryption — always rotate via the service
- ❌ Re-using a snapshot from a different Vault cluster as input to `raft snapshot restore` (cluster IDs don't align)
- ❌ Running DR drills only on paper — drill at least quarterly with real backup → restore cycle

## How the System Concierge should use this

When an operator chats "vault is down" / "restore credentials" / "rotate encryption":

1. **NEVER output secret material** in chat (per `cryptographic_material_safety` rules) — the Concierge is filtered to redact, but reinforce the convention
2. For DR drills, walk through Phase 3 + 4 step-by-step, surfacing each MCP/CLI command for operator copy-paste
3. For routine rotation, surface `system_rotate_vault_transit_pepper` with `request_confirmation` (sensitive, even though online)
4. For incident response, escalate immediately — do not auto-execute restoration

## Related docs

- [`credential-restoration.md`](../credential-restoration.md) — design reference (two-layer encryption, per-account keys, Vault transit pepper)
- `docs/infrastructure/vault-example/` (in parent platform repo) — Vault deployment topology
- Memory: `project_vault_pki_state.md`, `project_credential_pattern.md`
- Root `CLAUDE.md` Cryptographic Material Safety rules — operator behavior constraints
