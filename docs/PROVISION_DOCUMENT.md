# powernode-provision document v1

One versioned JSON document carries a device's enrolment identity over every
channel: USB/boot-partition file, cloud-init / NoCloud / config-drive,
provider metadata (user-data) and PXE pickup. One schema, one renderer, one
strict parser.

- Schema: [schemas/powernode-provision-v1.schema.json](schemas/powernode-provision-v1.schema.json)
- Renderer: `System::ProvisioningDocument` (`server/app/services/system/provisioning_document.rb`)
- Parser: `agent/internal/identity/provision.go` (`ParseProvisionDocument`)

## Fields (all required unless noted; unknown keys are rejected)

| Field | Meaning |
|---|---|
| `version` | integer `1` |
| `server` | platform base URL: `https`, DNS name or `[IPv6]` host, optional `:port` (1..65535), optional printable path; the host starts with an alphanumeric; no credentials, spaces, control characters, `?` or `#`; max 2048. The Go, Ruby and schema rules are the same regex |
| `instance_id` | NodeInstance uuid |
| `key` | single-use bootstrap token (plaintext), printable, no whitespace, max 512 |
| `ca_fingerprint` | **always required.** `sha256:<64 lowercase hex>` of the DER of the **last** certificate of the configured CA chain |
| `ca_pem` | optional CA chain (printable PEM, max 64 KiB), ordered **anchor-last**. If present, one certificate in it must match `ca_fingerprint` |
| `issued_at`, `expires_at` | RFC 3339 date-time; `expires_at` after `issued_at` |
| `purpose` | `[a-z0-9_.-]{1,64}` |

## Strictness

Keys are exact and case-sensitive. Duplicate keys, case-variant keys
(`CA_FINGERPRINT`), `null`, nested objects/arrays, and `1.0`/`"1"` as the
version are all rejected (the agent tokenises the JSON; a generic schema
validator cannot express this). Any rejection of a v1 document is **terminal**:
the resolver stops and refuses to enrol, it never falls through to a weaker
source. That includes cloud user-data: any `{...}` that is not a well-formed
legacy JSON object with no `version` key in any letter case (`Version`,
`VERSION`, a syntax error) is judged by the strict parser and is terminal.

## The pin

`ca_fingerprint` is enforced on the enrolment connection regardless of source:
the TLS handshake must verify (against `ca_pem` if embedded, otherwise system
roots) AND the verified chain must contain a certificate whose DER sha256
equals the pin. A mismatch refuses the connection; the key is never sent and
never logged. A v1 document without a pin is refused at parse time. The pin
is also accepted (optional) from legacy sources: `CA_FINGERPRINT=` (KEY=VALUE),
`powernode.ca_fingerprint` (cmdline), `ca_fingerprint` (fw-cfg / legacy JSON).

**Bundle ordering and what is pinned.** The CA bundle is ordered anchor-last and
the pinned (last) certificate must be a self-signed CA (`basicConstraints
CA:TRUE`, issuer == subject, valid self-signature); the renderer raises
`RenderError` otherwise. On the agent, self-signed CAs in `ca_pem` are the trust
anchors and every other certificate in it is an intermediate, so a server that
sends only its leaf still validates when its intermediates are in `ca_pem`
(otherwise the server must send them). Hostname, validity and server-auth key
usage are verified as usual.

**Pinning a public root (for example ISRG Root X1) gives weak protection**: any
certificate any public CA issues under that root satisfies the pin. Use a
private CA for real protection.

**One pin, every source.** The first pin seen from any source is enforced on
whichever source finally supplies the key: a pinless legacy source (cmdline,
KEY=VALUE, fw-cfg) never overrides a pinned v1 document, even if it is earlier
in precedence.

**Network sources never veto.** After a pinless local hit the resolver keeps
scanning only LOCAL sources (files, fw-cfg, cmdline) for a pin or a refused v1
document. Cloud metadata (unauthenticated, spoofable on L2) is not consulted
then, so it can neither supply a pin nor refuse a local identity. Before any
hit, a cloud source's refusal is still terminal.

**After enrolment.** The pin is persisted next to the PKI material
(`ca-pin`, alongside `ca-bundle.crt`). With no `ca_pem` (pin-only) the
verified-chain certificate that matched the pin is saved as the CA bundle, so
the mTLS transport can load. Every reconnect (`transport.LoadFromPKIDir`) and
cert rotation enforce the persisted pin on top of the bundle; a malformed pin
file is an error, never a silent downgrade. `ca-pin` is written first on save,
`meta.json` records `"pinned": true`, and a missing `ca-pin` for a pinned
enrolment fails closed; a pinless re-enrolment removes a stale `ca-pin`.

**Pinned TLS fixes the server name to the platform host.** Off-host absolute
blob URLs and redirects (for example the OCI pull path) therefore fail closed
on a pinned node; keep artifact downloads on the platform host.

Expiry is not checked against the device clock (no RTC/NTP at first boot); the
server enforces token expiry.

## Token handling

`ProvisioningDocument.render` takes the token plaintext as an argument at mint
time, returns it only inside the rendered string, and never stores or logs it.
It raises `RenderError` (without echoing the key) when no CA is configured or
the server URL is not a plain https URL.

## Deprecation (one image release)

The legacy shell `KEY=VALUE` identity.cfg, kernel-cmdline keys, fw-cfg entries
and the unversioned JSON shape (`instance_uuid`, `bootstrap_token`,
`platform_url`, `ca_pem`) stay accepted on READ for one image release, then
are removed. A JSON object that carries a `version` key is parsed strictly as
v1 and is never downgraded to a legacy shape. New writers emit v1 JSON only.

## Writers still emitting legacy formats (follow-up)

| Writer | Emits | Follow-up |
|---|---|---|
| `System::Providers::Proxmox::EnrollmentSeed#render_cicustom` | **Legacy `ID=/KEY=/SERVER=/CA_PEM_FILE=` by DEFAULT** (operator decision): images built before the new stager would copy a v1 document to the federation payload path. v1 JSON is opt-in with `POWERNODE_PVE_V1_CIDATA=1` | **Follow-up: flip the default to v1 once UKI images built from develop (new `powernode-cidata-payload.sh`) are promoted**, then drop the legacy branch |
| `System::Providers::Proxmox::EnrollmentSeed#build` and `LocalQemu::CloudSeed#build` | fw-cfg entries `opt/com.powernode/{instance_uuid,bootstrap_token,ca_pem,platform_url}` (no pin): the agent's fw-cfg reader is entry-per-key, not a document reader. Keys are still minted by the single issuer | agent fw-cfg v1 reader |
| `System::NetbootService.render_ipxe_script` (+ `initramfs/images/ipxe/template.ipxe.erb`) | kernel cmdline `powernode.*` keys | D11 |
| `Api::V1::System::NodeInstancesController` identity download | `identity.cfg` (`SERVER=/ID=/CA_PEM_FILE=`, no key) | D12 |

Not yet pin-aware on the agent: the claim poll uses the pin when present
(`ClaimStrategy.httpClient`) but legacy writers above do not yet emit one.

The claim flow (`/node_api/claim` polling) is not expressed by v1: a v1
document always carries a key. `ClaimStrategy` enforces a pin when one is
present on its identity and ignores its `HTTPClient` test override then.

## Platform-injected keys (D12)

When the platform itself provisions a VM it mints the key and injects it with
no human step. One issuer: `System::EnrollmentSeed` (`issue_token` for legacy
channels, `render_user_data` for v1). Every mint is
`BootstrapToken.issue!`: single-use, 1h TTL, bound to the NodeInstance, one
audit row written in the mint transaction (fail closed). The document is
rendered in the same transaction, so a missing/unusable CA or a non-https URL
rolls the mint back and raises `EnrollmentSeed::SeedError`; there is no
pin-less document. `ProvisioningService` surfaces that as a clear error and
creates no cloud instance.

Purposes: `cloud_seed` (AWS, OpenStack, GCP, Azure), `proxmox_uefi_provision`,
`local_qemu_provision`.

| Provider | Create-time channel | Re-mint on start |
|---|---|---|
| AWS | user-data = v1 (MIME multipart with the template `init_script` as part 2 when present) | yes: `modify_instance_attribute(user_data)` on the stopped instance, then start |
| OpenStack | user-data = v1 (MIME as above) | **no**: Nova cannot change user_data after create (rebuild only). The create-time key is the only one; a server that already enrolled keeps its mTLS identity |
| GCP | metadata `user-data` = bare v1; operator script in `startup-script` only | yes: `setMetadata` replaces only `user-data` (fingerprint kept); enrolled: the `user-data` item is removed |
| Azure | `properties.userData` = bare v1 (what the agent reads from IMDS); `osProfile.customData` = init script only | yes: PATCH `properties.userData` (customData is immutable) |
| Proxmox (uefi_disk) | NoCloud cicustom/ISO seed, legacy text by default, v1 with `POWERNODE_PVE_V1_CIDATA=1` (per-instance seed name) | yes: seed rewritten under the same name before `status/start` (cloud_init VMs, federation spawns and the fw-cfg opt-in are skipped) |
| local_qemu | fw-cfg entries (legacy keys) | yes: domain XML regenerated with a fresh key on start |
| pro_cloud | none (not wired) | n/a |

Multipart user-data: the agent selects the part typed
`application/x-powernode-provision+json` (`agent/internal/identity/cloud.go`);
cloud-init ignores that unknown type and runs the script part. A multipart blob
with no such part is "not found", a malformed one or a bad v1 part is terminal.
An operator `user_data` override is not carried across a restart re-mint (the
template `init_script` is, on the unenrolled re-mint path only).

### Start policy: only an UNENROLLED instance gets a key

Everything below applies ONLY to an instance the platform ever seeded (a
`cloud_seed`, `proxmox_uefi_provision` or `local_qemu_provision` token exists for
it). An imported instance, or one enrolled through another path, keeps its
user-data/metadata untouched: no re-mint and no clearing.

On every start the provider resolves the NodeInstance by cloud id, **scoped to
the connection's account and provider, excluding terminated rows**; more than one
match is refused (`SeedError`, surfaced as a provider error). Then:

- not enrolled: a fresh 1h document is minted. Under the instance row lock the
  prior ACTIVE tokens of that instance and purpose are revoked first (one audited
  `revoked` row each, same transaction), so at most one seed key is live;
- enrolled (an `mtls_subject` or an active NodeCertificate): **nothing is minted**
  and the seed is neutralised: AWS user-data and Azure `userData` are overwritten
  with a key-less placeholder, GCP's `user-data` item is removed, the Proxmox
  seed is overwritten in place (the VM's cicustom/ISO still points at it).

A mint failure on start (no CA, bad URL, size, an ambiguous cloud id, a lock
deadlock) returns a provider error (`SeedUnavailable`, with a cause-specific,
retryable-where-true message) and the VM is not started. `InstanceControlService`
hands the NodeInstance it already holds to the adapter (`with_known_instance`),
so the scoped cloud-id lookup is only a fallback for callers without one. The
enrolled check is repeated under the instance row lock; the lock order
(instance, then tokens) matches `NodeEnrollmentService#enroll!`.

Not atomic with the provider: the mint commits before the provider write. If the
write then fails (for example AWS `modify_instance_attribute` rejected because the
instance is running), the previous key stays revoked and the new one is lost; the
next start mints again.

Size limits (raw bytes, enforced in `EnrollmentSeed`, `SeedError` names the limit):
AWS 16384, OpenStack 49149 and Azure 49151 (64 KB base64), GCP 262144. The agent
fetches up to 512 KiB of user-data and a provision part up to 128 KiB.

Init scripts: `#cloud-config`, `#!`, `#include`, `#include-once`,
`#cloud-boothook`, `#part-handler`, `#upstart-job`, or an operator's own complete
multipart (nested as a part). Anything else is refused. On a restart re-mint only
the template `init_script` is re-attached on the unenrolled path (the enrolled
path writes the key-less placeholder, so the init script is not re-attached;
cloud-init already ran it for this instance) (an operator `user_data` override is
not stored, since it may embed secrets; cloud-init runs scripts once per instance
so this does not re-run them).

The agent requires the provision part of a multipart to parse as strict v1 and
refuses more than one such part or a legacy shape inside it. The initramfs
stager stages any JSON user-data that has a `"version"` key (any case, any
layout) as the identity file and lets the agent's strict parser decide.

## Drive scan (`powernode-provision.cfg`)

A booting node scans attached drives for a v1 document (agent
`identity.MediaScanStrategy`, `agent/internal/identity/media.go`). The file is
`/powernode-provision.cfg` at the filesystem root, or `/powernode/provision.cfg`.

- Probe order: removable non-optical block devices; `LABEL=cidata`/`CIDATA`
  then `/dev/sr*`; remaining disks. Disks backing any current mount (root,
  `/boot`, ...) and the image's `LABEL=BOOT` partition are skipped.
- Filesystems vfat, exfat, iso9660, ext4, always `-o ro,nosuid,nodev,noexec`;
  nothing on the media is executed and symlinks on it are never followed.
- Several files: the one whose `instance_id` is already known (cmdline, fw-cfg,
  BOOT identity.cfg) wins; else the newest `issued_at`; else the scan REFUSES.
- A file that fails the strict parse is a terminal refusal (no fall-through).
  Only device names are logged, never contents or the key.
- The accepted document is staged to `/run/powernode/identity.cfg` (0600).
- Budget about 10 s; nothing found falls through to the next source.
