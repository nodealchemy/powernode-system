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
| `server` | platform base URL, `https` only, no credentials, max 2048 |
| `instance_id` | NodeInstance uuid |
| `key` | single-use bootstrap token (plaintext), printable, no whitespace, max 512 |
| `ca_fingerprint` | **always required.** `sha256:<64 lowercase hex>` of the DER of the **last** certificate of the configured CA chain |
| `ca_pem` | optional CA chain (PEM, max 64 KiB). If present, one certificate in it must match `ca_fingerprint` |
| `issued_at`, `expires_at` | ISO8601; `expires_at` after `issued_at` |
| `purpose` | `[a-z0-9_.-]{1,64}` |

## The pin

`ca_fingerprint` is enforced on the enrolment connection regardless of source:
the TLS handshake must verify (against `ca_pem` if embedded, otherwise system
roots) AND the verified chain must contain a certificate whose DER sha256
equals the pin. A mismatch refuses the connection; the key is never sent and
never logged. A v1 document without a pin is refused at parse time. The pin
is also accepted (optional) from legacy sources: `CA_FINGERPRINT=` (KEY=VALUE),
`powernode.ca_fingerprint` (cmdline), `ca_fingerprint` (fw-cfg / legacy JSON).

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
