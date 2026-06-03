# Powernode Federation Social Contract — v1

> Status: active

**Effective:** 2026-05-14
**Version:** 1

This document is the normative agreement between any two Powernode platform
operators who federate with each other. Each peer acknowledges this contract
version at handshake; the version number is recorded on the `FederationPeer`
record on both sides (`contract_version_agreed`).

The technical mTLS handshake authenticates *cryptographic identity*; the
contract below establishes the *social norms* that make a working federation
possible.

---

## The Twelve Commitments

By accepting a federation peering (`status: proposed → accepted`), each
operator commits to the following twelve norms. Violations of the
programmatically-checkable norms are surfaced as **findings** by the
platform's `Sdwan::FederationGovernance` scanner. The scanner emits
findings only — there is **no** auto-suspend on social-contract
violation today; an operator reviews each finding and decides whether to
`suspend!`/`revoke!`. (Automatic suspend-on-repeated-violation is
aspirational — see remediation #5's proposed liveness-driven suspend
executor; do not assume it runs.)

### 1. Identity disclosure

Each peer publishes via heartbeat metadata:

- **Operator contact** (email or signed PGP-attested identifier)
- **Declared geographic location / jurisdiction**
- **Platform version** (semantic version of the Powernode build)
- **Last known-good release tag**

Anonymous peering is disallowed. A peer that cannot supply these MAY be
`proposed` but cannot reach `enrolled`.

### 2. Reciprocity of grants

When a peer issues a `FederationGrant`, it commits to honoring it until
its `expires_at` OR an explicit `revoke!`. Grants are not silently
degraded; revocation before expiry MUST be paired with notification when
feasible (see commitment #4).

### 3. Truthful capability declaration

Each peer commits to declaring only:

- Resource kinds it can actually serve
- Schema versions it actually runs (per `federation_inventory.yaml`)
- Filter predicates it actually applies

Bogus claims trigger `peer_capability_drift` findings and become grounds
for peer revocation.

### 4. Notification on revocation

The revoking peer commits to delivering a final notification through
the federation channel (a `platform.peer.revoked` FleetEvent and a
heartbeat `revoked` status) before tearing down the connection.

- In-flight migrations get a 5-minute grace period
- Out-of-band operator email notification is recommended for high-trust
  pairs

### 5. Audit transparency

Both sides commit to logging every cross-peer action in their own audit
log with the peer's identifier (`federation_peer_id` + `remote_subject`).

On legitimate operator-to-operator request, peers commit to providing
audit-log excerpts pertaining to the requesting peer's interactions
within **72 hours**.

### 6. No undermining

Peers commit not to:

- Flood the capabilities channel (rate-limit your re-handshakes)
- Issue mass-scope grants programmatically without operator action
- Deliberately corrupt sync streams
- Use federation as a vector to probe peer internals beyond declared
  capabilities

### 7. Migration data hygiene

The receiving peer commits to:

- Applying migrations in a single transaction (no partial-apply-then-
  claim-success)
- Reporting conflicts truthfully (via `Migration#conflict_log`)
- Preserving source UUIDv7 identities (do NOT remap IDs at the destination)
- Honoring `migration_only` capability constraints (no auto-sync after migrate)

### 8. Data residency disclosure

Peers commit to declaring their data residency (region / jurisdiction)
and not silently moving migrated data across boundaries without operator
notification.

Peers that move data across jurisdictions commit to surfacing this in
the migration audit log (`Migration#metadata.cross_jurisdiction`).

### 9. Compromise disclosure

A peer that detects compromise (cert theft, intrusion, data exfiltration)
commits to notifying all federation partners within **24 hours** — faster
is better, even if embarrassing.

On notification, the receiving operator is expected to `suspend!` the
affected peering pending review. This is operator-driven — the platform
does not auto-suspend on a compromise notice (see Enforcement
Classification: #9 is a critical, operator-driven norm).

### 10. Backwards compatibility window

Each release commits to **N-1 federation compatibility** — the prior
minor version can federate with the current version without operator
intervention.

Major version bumps may break compatibility with a documented
deprecation notice + 30-day migration period.

### 11. Exit and unbinding

Either peer may `revoke!` at any time. On revocation:

- Data already migrated REMAINS where it was migrated (deletion is NOT
  retroactive without an explicit `Migration#delete` operation)
- Local audit logs preserved per local retention policy
- SDWAN VIPs unmounted
- Certificates revoked

### 12. Contract version honesty

Peers commit to advertising the actual contract version they will honor,
not a higher claimed version. Mismatched advertised vs. honored is a
violation of commitments #3 and #6.

---

## Enforcement Classification

- **Soft norms** (#1, #4, #5) — verified by operator review; surfaced
  in the dashboard's Peers panel.
- **Programmatically-scanned norms** (#3, #6, #7, #8, #10, #12) — the
  `Sdwan::FederationGovernance` scanner, the schema-version handshake,
  and migration validation surface deviations as **findings**. The
  scanner today emits these specific finding types:
  - `peer_capability_drift` → commitment **#3** (truthful capability declaration)
  - `peer_schema_version_drift` → commitment **#10** (N-1 compatibility window)
  - `peer_residency_missing` → commitment **#8** (data residency disclosure)

  Findings do **not** auto-suspend or auto-revoke the peer — an operator
  reviews each finding and acts (`suspend!` / `revoke!`) as warranted.
- **Critical norms** (#9, #11) — operator-driven; technical primitives
  support but cannot enforce.

---

## Contract Versioning Protocol

- The platform stores every released contract version in the
  `system_federation_contract_versions` table with a SHA-256 digest of the
  text.
- Peers exchange `contract_version_agreed` at handshake; both sides MUST
  reference the same version.
- Contract amendments require **N-1 compatibility** for one release. Older
  versions become read-only after deprecation; new federations cannot
  adopt them.

---

## Out of Scope (v1)

The following federation behaviors are NOT part of v1 and require
explicit operator opt-in via separate channels:

- **OIDC-federated identity** (sovereign auth is v1; cross-peer SSO is P9+)
- **Continuous audit-log replication** beyond migration audit entries
- **Multi-hop migration chains** (A → B → C as one operation)
- **Cross-tenant federation** (different organizations sharing a peer mesh)

---

## Acknowledgement

By calling `POST /api/v1/system/federation_api/accept` with a non-zero
`contract_version`, the remote operator acknowledges this contract on
behalf of their platform. The acknowledgement is recorded on both peers'
`FederationPeer` rows and surfaced in the dashboard's Peers panel.

Revocation of a federation peering does NOT retroactively revoke the
acknowledgement — the contract remains the framework under which the
peering operated for forensic and audit purposes.

---

_Last verified: 2026-06-03_
