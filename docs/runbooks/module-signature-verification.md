# Module Signature Verification (supply-chain enforcement on the node)

> Status: active — capability shipped **DEFAULT OFF**. Turning it on is an operator decision; this runbook is the procedure.

**Audience:** security operators, SREs owning the fleet's module plane.
**Prerequisites:** a platform that signs modules (`system.module_signing.mode` = `vault` or `local`, at least one key in `system.module_signing.trusted_public_keys`), shell access to nodes for the conf file, `system.modules.*` for the backfill.
**Runtime:** ~30 min to reach `audit` fleet-wide; days of clean audit before `runtime`; a deliberate change window for `all`.

## What this verifies, and what it does not

A node in an enforcing mode refuses to loop-mount a module erofs blob unless it carries a `cosign sign-blob` bundle over exactly those bytes that verifies under one of the platform's trusted module-signing public keys. The bundle is produced **server-side at publish** (`System::ModuleBlobSigner` → `ModuleSigningService#sign_blob!`, Vault-transit or the on-box local key — the private key never leaves either), after the platform has verified the builder's OCI image signature at ingest. So a verified mount proves: *the platform I trust verified and re-signed these bytes.*

It does **not** prove the module *manifest* (services, users, egress policy) is what the platform intended — the manifest is unsigned and travels the same channel — and it does not bind a bundle to a module identity. Both are known, unbuilt extensions. See `agent/internal/verify/doc.go` for the full map.

The trust anchor is the platform's key list (`System::ModuleSigningTrust.public_keys`, served at `/api/v1/system/node_api/modules/signing_keys` — the same list ingest verifies against). A node either **pins** keys on `/persist` (strongest: the anchor does not travel the channel it guards) or fetches and caches the platform's list (bounded: whoever can impersonate the platform to that node can supply both the blob and a key it verifies under — the same bound the boot path's inline `cosign_public_key` has). Prefer pinning in production.

## The ladder

| Mode | Service loop (60 s) | `attach`/`update`/`sync`/`detach` CLIs | Boot composer (pivot / prepare-root / soft-recompose) |
|---|---|---|---|
| `off` (default) | no verification | no verification | no verification |
| `audit` | verify, **report**, never refuse | same | same |
| `runtime` | **enforce** | **enforce** | audit only |
| `all` | enforce | enforce | **enforce — an unsigned module is an unbootable node** |

Every rung past `off` needs a trust anchor at construction. An enforcing site with none **refuses to start** (the service does not come up; an `all`-mode boot refuses to compose) — loudly, once. A non-enforcing site degrades to no verification and reports it.

Policy sources, lowest to highest precedence:

1. `/persist/etc/powernode/module-signing.conf` — `MODE=off|audit|runtime|all`, `KEYS=/persist/etc/powernode/keys/a.pub:/persist/etc/powernode/keys/b.pub` (colon- or comma-separated; omit to use the platform's served list, cached under `/persist/var/lib/powernode/module-signing/platform-keys/`).
2. Environment: `POWERNODE_MODULE_SIGNING_MODE`, `POWERNODE_MODULE_SIGNING_KEYS`.
3. Service flags: `--module-signing-mode`, `--module-signing-key` (repeatable).

The boot composer reads only (1) and (2). An unknown mode is an error, never coerced.

## Step 0 — confirm the platform produces signatures

```bash
# On the platform. Which versions the fleet mounts lack a blob signature:
cd server && bundle exec rails system:modules:sign_blobs          # DRY RUN, lists candidates
# Sign them (states the count; shows first 3 and last 1 before acting):
APPLY=1 bundle exec rails system:modules:sign_blobs               # optional ACCOUNT_ID=<uuid>
```

Every publish path now signs automatically (`system.module_signing.sign_blobs`, default on outside test). A failed signing is **non-blocking**: the version publishes unsigned and a `system.module_blob_signing_failed` fleet event (severity medium) is emitted — watch for those before enforcing. Confirm on one module:

```bash
curl -s --cert node.crt --key node.key https://<platform>/api/v1/system/node_api/modules/<id>/download \
  | jq '.data.oci | {digest, cosign_bundle_b64: (.cosign_bundle_b64 != null), cosign_public_keys: (.cosign_public_keys | length)}'
```

Both must be non-null / non-zero.

## Step 1 — verify by hand on one node (same code path the node uses)

```bash
# The puller materialises the bundle beside the blob once the manifest carries it
# (next reconcile tick after the platform signed the version):
ls /persist/cache/modules/            # <digest>.erofs and <digest>.cosign-bundle
powernode-agent verify /persist/cache/modules/sha256_<digest>.erofs \
  --key-dir /persist/var/lib/powernode/module-signing/platform-keys   # or --key <pinned.pub>
```

`verify` builds its verifier through the same constructor the mount sites use, so its verdict is what an enforcing node would decide. `trust: static-key` in the output confirms the keyed path (not keyless) ran.

## Step 2 — `audit` fleet-wide (MEASURE)

```bash
install -d -m 0755 /persist/etc/powernode
printf 'MODE=audit\n' > /persist/etc/powernode/module-signing.conf
systemctl restart "$(systemctl list-units 'powernode-*-agent.service' --no-legend --plain | awk '{print $1}' | head -1)"
```

(Discover the unit name — never guess it; see the root `CLAUDE.md` terminology section.)

Watch the agent log for `verify:module_signature_audit` lines: each names a blob the enforcing mode **would refuse** and why (`no cosign bundle at …` = the platform never signed that version → backfill; `no trusted key verified …` = signed under a key this node does not trust → check the key list / pinned keys). `verify:module_signing_keys` reports a failed key refresh (the cached set is used). Run `audit` until the fleet is quiet for at least one full publish cycle of every module.

## Step 3 — `runtime` (enforce where a refusal is recoverable)

```bash
printf 'MODE=runtime\n' > /persist/etc/powernode/module-signing.conf   # add KEYS= to pin
systemctl restart <agent unit>
```

A refused mount now fails the attach: the module is reported unconverged (`verify cosign: …`) every tick and retried; the node keeps running what it has. The boot composer keeps auditing. Fix the artefact (backfill / republish) rather than the node.

## Step 4 — `all` (boot composer too) — change window

Only after `runtime` has been clean across a reboot of every node class. `MODE=all` makes an unsigned or badly-signed module an **unbootable node**; the boot-LKG fallback carries the frozen manifest's bundle, so a node that booted signed can fall back signed, but a node whose LKG predates signing cannot. Pin `KEYS=` here: a boot cannot refresh keys from a platform it cannot reach, and the cached set is only as fresh as the last successful service run.

## Rollback

`printf 'MODE=off\n' > /persist/etc/powernode/module-signing.conf` and restart the agent (or delete the file). For a node stuck at boot under `all`: boot the previous slot, or edit the conf on `/persist` offline (`qm --lock` first on a VM — see the memory note on offline `/persist` edits).

## Promote gate (platform side, opt-in)

`module_promotion_require_signature` (module config → account settings → `SiteSetting`, default off) makes an unsigned version ineligible in `System::Fleet::PromotionCriteria.evaluate` **and** withholds the publish-time auto-promote in both publish paths (`system.module_promotion_withheld`, reason names the setting). Publish itself is never blocked — the version row is kept for inspection and the fleet stays on the previous version.

## Key rotation

Append the new public key to `system.module_signing.trusted_public_keys` (never replace — artefacts signed under the old key stay mountable), switch the signer, then backfill. Nodes using the served list pick the new key up on their next service start; pinned nodes need the new file added to `KEYS=`. Verification tries every trusted key in order and succeeds on the first match.

## Things that will bite

- **`system.module_signing.trusted_public_keys` empty** → `/signing_keys` serves `[]` (a 200, not an error) and an enforcing node refuses to start with "no trusted public key". The local signer registers its key there on first use; a Vault-mode plane must have had its transit public key appended.
- **cosign version skew.** The platform signs with its cosign, the node verifies with the image's. The boot-image path already proves the static-key `sign-blob`/`verify-blob --insecure-ignore-tlog` pair across this fleet's versions; a new cosign major on either side must be re-proven on one module before `runtime`.
- **The `cosign_bundle` COLUMN on `ModuleArtifact` is not this signature.** On the Gitea-webhook ingest path it holds the stdout of `cosign verify --output json` — a verification *report* — so `ModuleArtifact.signed` counts reports. The node-facing bundle lives on `NodeModuleVersion.artifacts.erofs.cosign_blob_bundle_b64`.
