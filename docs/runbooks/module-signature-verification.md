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

**The fs-verity arm is measure-only on every rung.** The same mode also wires a check of each blob's fs-verity root against the manifest's `fsverity_root_hash`. Under `audit`, `runtime` and `all` alike it reports `verify:module_fsverity_audit` and never refuses; under `off` it does not run. It is not enforced because node images do not ship the `fsverity` binary yet: until they do, expect an `executable file not found` report on every mount attempt on an opted-in node. A newly attached module is checked twice in one service tick (prefetch and attach), and a failing attach repeats every tick. That report is the finding, not a node fault. `no fsverity_root_hash published` names a version whose publisher stamped no root. On a filesystem without verity support the enable step is skipped and the root is still compared in userspace, so the reports can go quiet. Where the binary is present and `/persist` supports verity, even this measure-only check enables fs-verity on the cached blob, which then becomes immutable. Enforcing this arm is a later agent change, after the binary ships and the reports are quiet.

**Where findings go.** The SERVICE reports its findings to the platform on its heartbeat (`module_signing_audit`, IMP-c52b5c2d6cbf): one entry per distinct finding — stage, the blob and reason, a repeat count and first/last timestamps — recorded on the node instance by `System::ModuleSigningAuditWriter`. They keep going to stderr as well, so the journal stays authoritative for live debugging. Under `audit` both arms contribute; under `runtime` and `all` the signature arm **enforces** instead of reporting, so only the fs-verity arm keeps producing findings there.

Read it **per node** — the instance's `module_signing_audit` config document. There is no fleet-level roll-up or sensor yet, so a fleet-wide sweep is still one read per instance; what changed is that the read no longer requires the node's journal.

Five readings, three underlying states, deliberately kept apart:

| What you see | What it means |
|---|---|
| no `module_signing_audit` document | **NOT MEASURED** — signing is `off` here, or the agent predates this block. Never read it as clean. |
| `finding_count` 0 **and** `mode: audit` | **QUIET** — both arms ran and found nothing. This is the measurement Step 2 waits for. |
| `finding_count` 0 **and** `mode: runtime` or `all` | **PARTIAL** — the signature arm *enforces* at this rung and reports nothing here, so this says only that the fs-verity arm is quiet. It is **not** evidence the signature arm is clean. |
| `finding_count` 0 **and** no `mode` | **UNATTRIBUTED** — the node named a rung the platform does not know, or named none (an agent predating the rung). Either way the measurement attributes to nothing: treat as not measured. |
| `findings` non-empty | what an enforcing rung would refuse here, today. |

Check `observed_at` before trusting any of it. The document is only ever written, never cleared, so a node moved back to `off` keeps its last document indefinitely — a stale record reads exactly like a current one apart from its timestamp.

Two of the stages are the measurement's own failure modes rather than blob findings: `verify:module_signing` means this node **degraded to no verification** (a non-enforcing site with no trust anchor), so its quiet reading is worthless until fixed; `verify:module_signing_keys` means a key refresh failed and the cached set is in use. Treat either as "not measured", not as a pass. `truncated: true` means the node had more distinct findings than the cap keeps, so `finding_count` is the size of the window, not the size of the problem.

**The BOOT COMPOSER is still stderr-only.** It verifies during the initramfs pivot, before any heartbeat exists, so its findings reach only the console. A node whose service is quiet can still have had boot-composer findings.

**Why the default is still `off`.** An `audit`-by-default fleet spends a verification pass on every boot-composer mount, and the boot-composer half of that measurement still is not delivered centrally. Turn `audit` on deliberately, per the steps below, and read the delivered findings rather than every node's journal.

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

Read the delivered findings per node (the instance's `module_signing_audit` config document, populated from the heartbeat) — or watch the agent log for `verify:module_signature_audit` lines, which say the same thing live: each names a blob the enforcing mode **would refuse** and why (`no cosign bundle at …` = the platform never signed that version → backfill; `no trusted key verified …` = signed under a key this node does not trust → check the key list / pinned keys). `verify:module_signing_keys` reports a failed key refresh (the cached set is used). Run `audit` until the fleet is quiet for at least one full publish cycle of every module.

## Step 3 — `runtime` (enforce where a refusal is recoverable)

```bash
printf 'MODE=runtime\n' > /persist/etc/powernode/module-signing.conf   # add KEYS= to pin
systemctl restart <agent unit>
```

A refused mount now fails the attach: the module is reported unconverged (`verify cosign: …`) every tick and retried; the node keeps running what it has. The boot composer keeps auditing. Fix the artefact (backfill / republish) rather than the node.

## Step 4 — `all` (boot composer too) — change window

Only after `runtime` has been clean across a reboot of every node class. **The delivered `module_signing_audit` document cannot establish that on its own**: under `runtime` the signature arm enforces at the service site (so it reports no findings there) and the boot composer's audit findings are console-only, which is precisely the site `all` starts enforcing. Confirm this rung from the nodes' consoles/journals for a boot of every node class, and use the document for the fs-verity arm and for Step 2's `audit` evidence. `MODE=all` makes an unsigned or badly-signed module an **unbootable node**; the boot-LKG fallback carries the frozen manifest's bundle, so a node that booted signed can fall back signed, but a node whose LKG predates signing cannot. Pin `KEYS=` here: a boot cannot refresh keys from a platform it cannot reach, and the cached set is only as fresh as the last successful service run.

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
