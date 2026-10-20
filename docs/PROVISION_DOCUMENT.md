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
| `server` | platform base URL: `https`, DNS name or `[IPv6]` host, optional `:port` (1..65535), optional printable path; no credentials, spaces or control characters, max 2048. The Go, Ruby and schema rules are the same regex |
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
source.

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

**After enrolment.** The pin is persisted next to the PKI material
(`ca-pin`, alongside `ca-bundle.crt`). With no `ca_pem` (pin-only) the
verified-chain certificate that matched the pin is saved as the CA bundle, so
the mTLS transport can load. Every reconnect (`transport.LoadFromPKIDir`) and
cert rotation enforce the persisted pin on top of the bundle; a malformed pin
file is an error, never a silent downgrade.

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
| `System::Providers::Proxmox::EnrollmentSeed#render_cicustom` | `ID=/KEY=/SERVER=/CA_PEM_FILE=` NoCloud user-data + CA as meta-data | D12 |
| `System::Providers::Proxmox::EnrollmentSeed#build` and `LocalQemu::CloudSeed#build` | fw-cfg entries `opt/com.powernode/{instance_uuid,bootstrap_token,ca_pem,platform_url}` | D12 |
| `System::NetbootService.render_ipxe_script` (+ `initramfs/images/ipxe/template.ipxe.erb`) | kernel cmdline `powernode.*` keys | D11 |
| `Api::V1::System::NodeInstancesController` identity download | `identity.cfg` (`SERVER=/ID=/CA_PEM_FILE=`, no key) | D12 |

Not yet pin-aware on the agent: the claim poll uses the pin when present
(`ClaimStrategy.httpClient`) but legacy writers above do not yet emit one.

The claim flow (`/node_api/claim` polling) is not expressed by v1: a v1
document always carries a key. `ClaimStrategy` enforces a pin when one is
present on its identity and ignores its `HTTPClient` test override then.
