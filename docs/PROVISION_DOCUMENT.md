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

**Source precedence.** The agent tries eight key sources in this fixed order;
the first non-empty key wins and a later source never overrides it:

1. kernel cmdline / PXE single-fetch pickup
2. virtio fw-cfg
3. staged NoCloud / config-drive document (`/run/powernode/identity.cfg`)
4. provider metadata user-data (AWS, GCP, Azure, OpenStack, DigitalOcean)
5. media-scan provisioning file (USB, cidata, extra disks)
6. the `KEY` in the BOOT `identity.cfg`
7. console prompt (initramfs only)
8. claim poll (blocks until an operator confirms)

`/etc/identity.cfg` remains a legacy fallback behind all eight. A BOOT
`identity.cfg` with `SERVER` (and optionally `ID`) but no `KEY` is not a key; it
only drives the claim poll (8) and may carry a pin.

**Network sources never veto, and never pin.** Provider metadata (169.254.169.254
over HTTP) is unauthenticated and spoofable on L2, so it is consulted only while
no key has been found, never after one, and:

- Once any source has supplied a key, the resolver keeps scanning only LOCAL
  sources (files, fw-cfg, cmdline, the BOOT file) for a pin or a refused v1
  document. Metadata, the media scan, the console prompt and the claim poll are
  not run then, so none of them can supply a pin or refuse a local identity (a
  removable stick can neither veto an identity nor attach its own pin).
- Only LOCAL pins are authoritative (cmdline, fw-cfg, staged document, BOOT
  file, `/etc/identity.cfg`, console). A pin asserted by metadata or by a
  removable stick is not: when either wins over BOOT, the local pin is still
  collected, and if it differs from the winner's pin the resolver refuses
  (fail closed). Two local sources asserting different pins also refuse; the
  agent never picks one silently.
- A v1 refusal from provider metadata is deferred past ALL local sources (media
  scan, BOOT key, console prompt, claim poll, `/etc/identity.cfg`) and returned
  only if none of them yields a key, so a spoofed refusal cannot veto a local
  identity, claim-by-ID devices included.
- On a node with no earlier key the provider probes (about 1.5 s each, up to
  ~6 s off-cloud) run before the media scan, BOOT key and prompt.

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

## Operator download (one-shot)

`POST .../node_instances/:id/bootstrap_tokens` with `include_provisioning_document: true`
returns the rendered document as `provisioning_document` beside the one-time `token`.
The node-instances tab ("Generate enrolment key") builds `powernode-provision.cfg`
client-side from that response (a Blob); no server URL serves it again. The request
is refused with 409 once the instance is claimed or enrolled, and with 422 (no key
minted) when no CA is configured. The existing `identity.cfg` download stays key-free.

## Drive scan (`powernode-provision.cfg`)

A booting, UNENROLLED node scans attached drives for a v1 document (agent
`identity.MediaScanStrategy`, `agent/internal/identity/media.go`). The file is
`/powernode-provision.cfg` at the filesystem root, or `/powernode/provision.cfg`.

- **Never on an enrolled node.** The scan returns not-found before touching any
  device when a usable `node.crt` + `node.key` exists in the PKI dir, and the
  Resolver never runs it after an earlier source already supplied an identity
  (so media cannot veto it or attach a pin). This holds for every call site
  that resolves identity (runtime bootstrap, CLI, soft_recompose, prepare-root).
- **Probe order and "removable".** FIXED media first -- `LABEL=cidata`/`CIDATA`,
  then `/dev/sr*`, then the remaining disks -- and removable media LAST, so a
  stick cannot use up the budget ahead of the seed disk. "Removable" is decided
  by the hardware, never by a label or by being a CD-ROM: a disk whose real sysfs
  path runs through a `usbN` or firewire segment, any disk with a sysfs ancestor
  whose `removable` attribute reads `removable` (Thunderbolt and external PCI
  ports), a native SD card (`mmcblk*` with `device/type` = `SD`), or a non-optical
  disk with `removable=1`. An internal optical drive is fixed.
  Disks backing any current mount (root, `/boot`, dm slaves, `/dev/root`) and the
  image's `LABEL=BOOT` partition are skipped. If the mount table cannot be read
  the scan aborts before touching any device.
- **Enumeration wait.** The scan waits the full enumeration window (default 2 s,
  inside the budget) before deciding, even when a USB device is already there,
  because a fixed disk may still be enumerating.
- Per device: filesystem signature sniffed first (vfat, exfat, iso9660,
  ext2/3/4) and mounted ONCE with that type. The block device is made read-only
  (BLKROSET) before the mount, ext4 gets `noload`, and every mount is
  `-o ro,nosuid,nodev,noexec`. A device that cannot be set read-only is not
  mounted. BLKROSET is undone (previous state, via BLKROGET) only after a clean,
  non-detached unmount, by reopening the device by its path; an abandoned or
  detached device stays read-only.
- The file is opened component by component with `O_NOFOLLOW` (symlinks on the
  media are never followed), must be a regular file, and is refused if larger
  than the parser cap even if the excess is whitespace. Nothing is executed.
- **Selection.** All candidates are read within the budget, then EVERY document
  must be byte-identical (after trimming), whatever its tier: any difference at
  all (instance, key, issued_at, server, pin, ...) REFUSES (terminal). There is
  no known-id or newest-wins tie-break; the only flow this refuses is two
  different documents attached at once, which is ambiguous by definition.
- **Incomplete scans.** A candidate that passed the signature sniff but did not
  finish cleanly (BLKROSET or mount failure, abandoned, or unprobed because the
  budget ran out) makes the scan incomplete: nothing is used while a fixed
  candidate is incomplete, and a removable document is not used while any
  candidate is. The scan returns not-found and falls through.
- **Refusals.** A document that fails the strict parse (or is oversized) on FIXED
  media is a terminal refusal. On REMOVABLE media the scan logs the device name
  and returns not-found, so later strategies still run: a malformed stick cannot
  block enrolment of an unenrolled node. Only device names are logged, never
  contents or the key.
- The accepted document is staged to `/run/powernode/identity.cfg` (0600).
- **Budget (~10 s)** covers udev settle, the enumeration wait and the probe of
  every candidate as seen by the caller. Per-device I/O runs in a goroutine that
  is abandoned at the budget; work the kernel cannot interrupt (a mount or read
  stuck in D-state) finishes in the background and is then unmounted with
  `MNT_DETACH`. It is not a bound on that kernel work itself.

### Enrolled gate lifetime

The "already enrolled" gate is a usable `node.crt` + `node.key` in the PKI dir.
On diskless nodes or nodes whose `/persist` is tmpfs the PKI does not survive a
reboot, so the gate holds for ONE boot only: after a reboot the scan runs again
(and re-offers the media) unless an earlier source in the Resolver hits first.

### Threat model

The scan is trust-on-first-use of physical media: whoever can attach a drive
to an unenrolled node can offer it an enrolment document. The rules above bound
this (pin required, all documents must agree, fixed media probed first, no
effect once enrolled) but do not remove it. **Physical-access DoS:** a
malformed document on removable media is skipped (the node falls through to
other sources); a WELL-FORMED but DIFFERENT document next to the seed disk, or
a malformed document on fixed media, still refuses and blocks media enrolment
of an UNENROLLED node until it is removed. An enrolled node is unaffected.

## Console prompt (last resort before the claim poll)

Every image carries a masked prompt on `/dev/console` (`ConsolePromptStrategy`,
`agent/internal/identity/console.go`). There is no per-platform flag.

**When it runs** (all must hold):

- No earlier source supplied a key. A `KEY=` baked into the BOOT `identity.cfg`
  counts as an earlier source and suppresses the prompt.
- The BOOT `identity.cfg` has `SERVER` (the same condition that starts the
  claim poll; cloud VMs are never blocked).
- The node is not enrolled yet, and the agent runs **in the initramfs**
  (`/etc/initrd-release`). After the pivot the console belongs to the getty
  units; an unenrolled node never gets past the initramfs, so no
  `Before=`/`Conflicts=` juggling with `getty@`/`serial-getty@` is needed.
- The caller is the `boot` or `service` enrolment path
  (`identity.InteractiveResolver()`). CLI commands, `soft_recompose` and
  `prepare-root` use `DefaultResolver()`, which never prompts.
- An exclusive `flock` on `/run/powernode/console-prompt.lock` is obtained, so
  two readers never share the tty.
- Fewer than 3 consecutive refusals were counted in
  `/run/powernode/console-refusals`; after 3 the prompt is off for this boot and
  the claim poll runs. A successful enrolment resets the counter.

**Input.** Masked: the terminal is put in no-echo, non-canonical mode before
the first read and restored before the descriptor is closed (also on timeout,
cancellation, panic and SIGTERM/SIGINT). Nothing is echoed, not even `*`. If
no-echo cannot be established the prompt is not shown.

- **Timeout** 60 s, then the boot continues to the claim poll. Override with
  the kernel cmdline `powernode.console_prompt_timeout=<seconds>`; `0` disables.
  The prompt has its **own** timeout: the Resolver's 30 s budget applies to the
  other sources and does not cut the prompt short (cancelling the context does).
- A **bare key** is combined with `SERVER`, the CA pin and the CA from the BOOT
  `identity.cfg`. Without a pin there a bare key is refused (v1 requires one);
  paste a provisioning document instead.
- A **pasted v1 document** (first non-space byte `{`) is read across newlines
  until the braces balance (string- and escape-aware), so a pretty-printed paste
  works, within the 128 KiB cap. It is parsed strictly and must match the
  image: `server` must equal the BOOT `SERVER`, and `ca_fingerprint` must equal
  the BOOT pin when the image carries one. Otherwise it is refused, so a
  console paste cannot point the node at another platform.
- Anything the operator typed that is refused is **terminal**; the agent unit
  restarts and prompts again (counted, see above).

**Staging.** The accepted identity is staged as a v1 document with purpose
`console-prompt` at `/run/powernode/identity.cfg` (0600, tmpfs), and the
returned identity is the re-parse of those bytes. It is staged *before*
enrolment (rather than only after) so a transient network failure or an agent
restart does not lose a key the operator typed. The enrol path then cleans up:
a **4xx refusal** (`enroll.IsRefused`) deletes the staged file and counts a
refusal, so the next attempt re-prompts instead of re-reading a dead key forever;
a **successful** enrolment deletes it and resets the counter. A **5xx or
network failure is retryable**: nothing is deleted or counted (the server returns
503 for transient failures such as the CA or audit sink being down, after rolling
the token back). Cleanup keys on HOW the file was staged, not on the document's
purpose (a pasted document keeps its own): a marker at
`/run/powernode/console-staged` names the staged file and the sha256 of its key,
so it also works after an agent restart and never touches another identity. A
staged bare key uses the BOOT `ID=` as `instance_id` (the CSR subject) when the
image has one, else the nil UUID (logged as "assigned by the platform at
enrolment", not as an instance). With a Vault CA the role must set
`use_csr_common_name=false`; enrolment verifies the issued CN and aborts with 503
(token not consumed) on a mismatch. The unit sets `LimitCORE=0` so a crash cannot dump the key.

**Input is never logged** or echoed in an error, and the buffers are zeroed.

**Baking the pin.** The disk-image build scripts (`amd64-uefi`, `arm64-uefi`,
`rpi4`) write `CA_FINGERPRINT=sha256:<hex>` into BOOT `identity.cfg` when a CA is
supplied (`--ca-pem-file`), computed by `initramfs/images/lib/ca-fingerprint.sh`
with the same rule as the renderer (DER sha256 of the LAST certificate, which
must be a self-signed CA); the build fails if the supplied CA does not satisfy
it. With no CA supplied no pin is baked and a bare key then needs a pasted
document. "Download boot config" (`node_instances#boot_config`) emits the same
`CA_FINGERPRINT=` from the configured chain. The agent never derives the pin
from `/boot/powernode-ca.pem`.
