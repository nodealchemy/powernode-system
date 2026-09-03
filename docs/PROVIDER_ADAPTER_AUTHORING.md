# Authoring a Cloud Provider Adapter

> Status: active

How to write a new **cloud/hypervisor provider adapter** for the fleet substrate so the platform can
provision, control, and reconcile compute instances (and, optionally, volumes / IPs / images) on a new
backend — AWS, GCP, Azure, OpenStack, Proxmox, ProCloud, local libvirt/QEMU, or your own.

Every adapter subclasses `System::Providers::BaseProvider`
(`app/services/system/providers/base_provider.rb`), implements a fixed ~24-method abstract contract,
and returns a small set of **normalized response shapes** that the rest of the platform reads without
knowing which backend produced them. The base class supplies the helpers (credential resolution, the
response builders, timeout constants, log scrubbing, capability discovery) so each adapter only writes
the backend-specific glue.

There are **8 adapters** today:

| `provider_type` | Class | Source |
|---|---|---|
| `aws` | `System::Providers::AwsProvider` | `app/services/system/providers/aws_provider.rb` |
| `gcp` | `System::Providers::GcpProvider` | `app/services/system/providers/gcp_provider.rb` |
| `azure` | `System::Providers::AzureProvider` | `app/services/system/providers/azure_provider.rb` |
| `openstack` | `System::Providers::OpenStackProvider` | `app/services/system/providers/open_stack_provider.rb` |
| `proxmox` | `System::Providers::ProxmoxProvider` | `app/services/system/providers/proxmox_provider.rb` |
| `pro_cloud` | `System::Providers::ProCloudProvider` | `app/services/system/providers/pro_cloud_provider.rb` |
| `local_qemu` | `System::Providers::LocalQemuProvider` | `app/services/system/providers/local_qemu_provider.rb` |
| `mock` | `System::Providers::MockProvider` | `app/services/system/providers/mock_provider.rb` |

**`MockProvider` (`app/services/system/providers/mock_provider.rb`) is the canonical minimal adapter** —
in-memory, no network, every method present. Read it end to end first; it is the running example used
throughout this doc. `LocalQemuProvider` (`app/services/system/providers/local_qemu_provider.rb`) is the
next-simplest real backend (libvirt/virsh) and shows a narrowed capability surface.

---

## 1. Where the adapter sits

The substrate's instance lifecycle (`pending → provisioning → starting → running → …`, see
[`ARCHITECTURE.md`](./ARCHITECTURE.md) §2) is driven by service-layer callers that never talk to a
cloud SDK directly. They resolve an adapter through the **Registry**, call the abstract method, and read
the normalized hash:

```
caller (CloudSyncService / ProvisioningService / VolumeManagementService / controllers)
  → System::Providers::Registry.for_instance(instance)   # → a BaseProvider subclass
  → adapter.get_instance(cloud_id)                        # backend-specific work
  → { success:, status:, private_ip_address:, … }         # normalized shape, backend-agnostic
```

`System::CloudSyncService` (`app/services/system/cloud_sync_service.rb`) is the reference consumer: it
calls `get_instance` / `list_instances`, then reads `result[:success]`, `result[:status]`,
`result[:private_ip_address]`, `result[:public_ip_address]`, `result[:instance_type]`, and treats
`result[:error_code] == "NotFound"` as "instance is gone". This is why the **return-shape contract
(§4) is load-bearing**: a bespoke hash with the wrong keys silently breaks the consumer even though the
adapter "ran".

---

## 2. Construction

```ruby
def initialize(connection, region: nil)
```

- `connection` — a `System::ProviderConnection` (`app/models/system/provider_connection.rb`) carrying
  credentials (typed columns + a `config` JSONB bag) and a `belongs_to :provider`.
- `region:` — an optional `System::ProviderRegion` (`app/models/system/provider_region.rb`). When nil,
  the base picks `connection.provider&.provider_regions&.first`; providers without regions (`proxmox`,
  `local_qemu`) yield `@region = nil`.

The base exposes `attr_reader :connection, :region, :logger, :last_authentication_error`. `logger` is
`Rails.logger`. Most adapters do **not** override `initialize`; they read credentials lazily via the
helpers in §5.

**Transient (BYOC) construction.** `BaseProvider.with_credentials(credentials)` builds an adapter from a
plaintext credential hash **without** a persisted `ProviderConnection` (`@connection` / `@region` are
nil). `System::CredentialValidationService`
(`app/services/system/credential_validation_service.rb`) uses it to test operator-supplied keys before
persistence. If your adapter needs extra ivar setup at construction, override `with_credentials` (see
its doc comment in the base).

---

## 3. The abstract contract (24 methods)

Every concrete adapter MUST implement these. In the base they each `raise NotImplementedError` (a
`BaseProvider::ProviderError` subclass — **not** Ruby's built-in `NotImplementedError`). The executable
contract for method existence + arity is the shared spec in §7.

### Introspection / auth

| Method | Signature | Returns |
|---|---|---|
| `provider_type` | `provider_type` | `String` — the registry key (`"mock"`, `"aws"`, …) |
| `authenticate?` | `authenticate?` | `Boolean` — cheap, side-effect-free credential probe; on `false`, set `@last_authentication_error` to a human message |
| `test_connection` | `test_connection` | `{ success:, message: }` |
| `get_metadata` | `get_metadata` | `Hash` — regions / instance types / volume types / features |
| `normalize_status` (protected) | `normalize_status(provider_status)` | `String` — maps a backend status to a `BaseProvider::STATUSES` value, `"unknown"` for anything unmapped |

### Instance lifecycle

| Method | Signature | Returns |
|---|---|---|
| `create_instance` | `create_instance(params)` | instance-response shape (§4) |
| `start_instance` | `start_instance(instance_id)` | instance-response shape |
| `stop_instance` | `stop_instance(instance_id, force: false)` | instance-response shape |
| `reboot_instance` | `reboot_instance(instance_id)` | instance-response shape |
| `terminate_instance` | `terminate_instance(instance_id)` | instance-response shape (or `{ success: true }`) |
| `get_instance` | `get_instance(instance_id)` | instance-response shape; **on "gone" return `build_error_response(..., code: "NotFound")` or raise `ResourceNotFoundError`** |
| `list_instances` | `list_instances(filters = {})` | `{ success: true, instances: [...], page_count: N, truncated: Boolean }` — page through up to `filters[:max_pages]` |

### IP addresses

| Method | Signature | Returns |
|---|---|---|
| `allocate_ip` | `allocate_ip` | `{ success:, allocation_id:, public_ip: }` |
| `associate_ip` | `associate_ip(instance_id, allocation_id: nil)` | `{ success:, public_ip:, association_id: }` |
| `disassociate_ip` | `disassociate_ip(association_id)` | `{ success: }` |
| `release_ip` | `release_ip(allocation_id)` | `{ success: }` |

### Volumes

| Method | Signature | Returns |
|---|---|---|
| `create_volume` | `create_volume(params)` | `{ success:, volume_id: }` |
| `attach_volume` | `attach_volume(volume_id, instance_id, device: nil)` | `{ success:, device: }` |
| `detach_volume` | `detach_volume(volume_id, force: false)` | `{ success: }` |
| `delete_volume` | `delete_volume(volume_id)` | `{ success: }` |
| `get_volume` | `get_volume(volume_id)` | normalized volume hash |

### Images

| Method | Signature | Returns |
|---|---|---|
| `create_image` | `create_image(instance_id, name:, description: nil)` | `{ success:, image_id: }` |
| `get_image` | `get_image(image_id)` | normalized image hash |
| `delete_image` | `delete_image(image_id)` | `{ success: }` |

> **Signatures are enforced.** `detach_volume` MUST be `(volume_id, force:)`, `attach_volume` MUST be
> `(volume_id, instance_id, device:)`, and the method MUST be named `reboot_instance` (not
> `restart_instance`). The `"a provider class with BaseProvider signatures"` shared example asserts
> exactly this — these were real divergences caught in an audit.

If your backend genuinely lacks a surface (e.g. no managed volumes), do **not** stub the methods with
fake success — narrow `capabilities` instead (§6) so callers skip them.

---

## 4. The return-shape contract (load-bearing)

Instance operations return a **normalized hash** built by the base helpers. Do not hand-roll it.

### `build_instance_response` (protected)

```ruby
build_instance_response(cloud_id:, status:, private_ip: nil, public_ip: nil, **metadata)
# =>
{
  success: true,
  cloud_instance_id: cloud_id,
  status: status,                 # a BaseProvider::STATUSES value
  private_ip_address: private_ip, # note the *_address key names
  public_ip_address: public_ip,
  provider_type: provider_type,
  synced_at: Time.current
}.merge(metadata)                  # extra keys (instance_type:, message:, …) are passed through
```

### `build_error_response` (protected)

```ruby
build_error_response(message, code: nil)
# =>
{ success: false, error: message, error_code: code, provider_type: provider_type }
```

**Why this matters:** consumers branch on `result[:success]`, read `result[:status]` /
`result[:private_ip_address]` / `result[:public_ip_address]`, and detect a deleted instance via
`result[:error_code] == "NotFound"` (see `app/services/system/cloud_sync_service.rb`). An adapter that
returns its own hash without `:success`, or that uses keys like `:private_ip` instead of
`:private_ip_address`, will appear to work but feed `nil`s into the consumer — exactly the class of bug
the contract exists to prevent. Always go through the two builders.

### Status normalization

`status:` values must come from `BaseProvider::STATUSES`:
`pending, starting, running, stopping, stopped, rebooting, terminating, terminated, failed, unknown`.
Implement `normalize_status(provider_status)` to map your backend's strings onto these, falling back to
`"unknown"`. `MockProvider` passes statuses through (it already speaks the platform vocabulary);
`LocalQemuProvider#normalize_status` maps libvirt states (`"shut off" → stopped`, `"crashed" → failed`,
…).

### "Gone" conventions (two accepted forms)

The base `sync_status(instance_id)` (a **concrete** helper — do not re-implement unless you have a
cheaper status-only query, as `local_qemu`/`proxmox` do) delegates to your `get_instance` and maps a
deleted instance to a `terminated` response. It recognizes a missing instance **two ways**, so your
`get_instance` may use either:

1. **Return** `build_error_response("...not found...", code: "NotFound")` — the hash form (used by
   `mock`/`aws`/`gcp`).
2. **Raise** `BaseProvider::ResourceNotFoundError` — the exception form (used by `azure`/`openstack`).

Any other error propagates to the caller. Pick one form and use it consistently.

---

## 5. Credentials (never handle raw key material)

Read credentials through the base helpers — never reach into `connection.config` ad hoc, and never log
or return secret values.

### `credential` (protected)

```ruby
credential(column: nil, config_key: nil, required: false, default: nil)
```

Resolves a single value with this precedence: typed connection **column** → connection **`config`**
JSONB key → **BYOC** `System::ProviderCredential` store
(`app/models/system/provider_credential.rb`, looked up via
`::System::ProviderCredential.for(account:, provider:)`) → `default`. With `required: true` it raises
`AuthenticationError` ("Missing required <provider_type> credential: <label>") when nothing resolves.

### `auth_credential` (protected)

```ruby
auth_credential(*keys)
```

Returns the first present value among `keys`, preferring request-scoped **transient** credentials (the
BYOC `with_credentials` path) and otherwise falling back to `credential(column:, config_key:)`. This is
the credential reader the four cloud adapters use.

### Crypto-safety (ABSOLUTE)

- **Never** log, echo, return, or pass as a traceable argument any private key, API secret, token,
  password, or seed phrase. Resolve via `credential` / `auth_credential` and hand the value straight to
  the backend SDK.
- The base scrubs structured logs: `log_operation(operation, **details)` runs `details` through
  `sanitize_for_log`, which redacts any key in `LOG_SENSITIVE_KEYS` (`access_key`, `secret_key`,
  `access_token`, `password`, `client_secret`, `private_key`, `ssh_key`, …) recursively — including
  ActiveRecord attribute dumps. **Use `log_operation`, not `logger.info` with raw params**, so a record
  or hash that happens to carry a secret is scrubbed.
- Adapters guide setup through the UI/API; they never generate or store key material themselves
  (per the platform's cryptographic-material-safety rules).

---

## 6. Capabilities (graceful degradation)

The default surface is `BaseProvider::CAPABILITIES = %i[instances volumes ips images sync]`. A backend
that does less overrides `capabilities`:

```ruby
def capabilities
  %i[instances sync]   # LocalQemuProvider — no volumes/IPs/images
end
```

`ProCloudProvider` narrows further to `%i[instances]`. Callers probe `adapter.supports?(:volumes)`
**before** creating DB rows or dispatching a provider call, so an unsupported operation fails as a
structured `Result` up front instead of a `NotImplementedError` mid-mission — e.g.
`CloudSyncService#sync_region_instances` gates on `supports?(:sync)` because `pro_cloud` has no
region-wide listing. Declare your real surface; let `supports?` do the gating.

---

## 7. The executable contract: `it_behaves_like "a cloud provider"`

The single most important thing for an adapter author: **every new adapter spec must invoke the shared
examples** in `server/spec/services/system/providers/shared_examples.rb`. They are the machine-checked
version of this whole contract.

```ruby
# server/spec/services/system/providers/your_provider_spec.rb
RSpec.describe System::Providers::YourProvider do
  subject { described_class.new(connection) }

  it_behaves_like "a cloud provider"   # method existence across the full interface
end
```

The shared examples (opt-in groups, adopt as your internals stabilize):

- **`"a cloud provider"`** — asserts the subject responds to the entire abstract interface
  (`provider_type`, all lifecycle / volume / IP / image methods). Cheap smoke test that catches a method
  dropped during a refactor.
- **`"a provider class with BaseProvider signatures"`** — class-level signature assertions:
  `detach_volume(volume_id, force:)`, `attach_volume(volume_id, instance_id, device:)`, and
  `reboot_instance` present / `restart_instance` absent. Run once globally.
- **`"a cloud provider with status normalization"`** — pass a `{ "cloud-status" => "platform-status" }`
  map; verifies each mapping, that every output is in `BaseProvider::STATUSES`, and that an unknown
  status falls back to `"unknown"`.
- **`"a cloud provider raises on auth failure" / "...on rate limit" / "...on not found"`** — set up the
  failure (stub your client) and the example asserts the adapter raises `AuthenticationError` /
  `RateLimitError` / `ResourceNotFoundError` rather than returning a `{ success: false }` hash.
- **`"a cloud provider validates credentials"`** — asserts `AuthenticationError` when a `required: true`
  credential is missing.

End-to-end provider verification runs against a real **Proxmox host**, not the in-memory mock.

### Specs gated on an optional SDK gem (aws / openstack)

`AwsProvider` and `OpenStackProvider` mock the vendor SDK client (`Aws::EC2::Client`,
`Fog::OpenStack::Compute`), so their specs' `before` blocks reference constants that only exist
when the SDK gem is installed. Those gems are **intentionally absent from the core bundle** (see
`server/powernode_system.gemspec`), so under the default bundle these specs self-**skip** (RSpec
`pending`) rather than fail — ~64 examples across the two files. A green run under the default bundle
therefore does **not** exercise `AwsProvider` / `OpenStackProvider` (including `run_instances`
`ClientToken` / `tag_specifications` and the connect/read timeout handling). `GcpProvider`
(mocked clients) and `AzureProvider` (hand-rolled Faraday client) need no SDK gem and always run.

To actually exercise the SDK-gated specs, run them with the SDK gems layered onto the core bundle:

```bash
# from anywhere in a checkout where extensions/system/ is mounted in the platform:
bash extensions/system/scripts/test-provider-gems.sh
# or a subset (paths relative to server/):
bash extensions/system/scripts/test-provider-gems.sh \
  ../extensions/system/server/spec/services/system/providers/aws_provider_spec.rb
```

The script generates a throwaway supplementary Gemfile (`eval_gemfile "Gemfile"` + `aws-sdk-ec2` +
`fog-openstack`), installs it, and runs the provider suite — the 64 skips become real assertions.
CI runs this automatically in the **`provider-specs`** job (`.gitea/workflows/ci.yaml`); the default
`rspec` job's `services` suite still shows those 64 as `pending`, which is expected there.

Because the gems are absent from the **runtime** bundle, those two adapters are also withdrawn at
runtime rather than advertised and then failing at first call — see §10, *Adapters that need an
optional SDK gem*. `sdk_availability_guard_spec.rb` covers that in the default lane and is written
to hold in this lane too.

---

## 8. The error hierarchy — when to raise each

All adapter errors subclass `BaseProvider::ProviderError` (which subclasses `StandardError`):

| Error | Raise when |
|---|---|
| `ProviderError` | generic / transport failure with no more specific class (base fallback in `handle_error`) |
| `NotImplementedError` | a required abstract method is unimplemented (the base stubs do this; you should not) |
| `AuthenticationError` | credentials rejected (401/403), or a `required:` credential is missing |
| `RateLimitError` | backend throttles you (429) |
| `ResourceNotFoundError` | the addressed resource is gone (404) — the exception form of the §4 "gone" convention |
| `QuotaExceededError` | the backend refuses for quota/limit reasons |

**Lifecycle/`get`/`list` failures should raise these typed errors**, not return `{ success: false }`
hashes — `list_instances` especially. `CloudSyncService` rescues `ResourceNotFoundError` and
`ProviderError` and maps them to platform `Result`s; the typed contract is what lets it do so without
string-matching. (The one deliberate exception is the §4 hash form of "gone" from `get_instance`, which
`sync_status` understands.)

---

## 9. Timeouts (fail-fast convention)

Every auth/token + SDK/HTTP call on the provisioning path MUST carry an explicit connect + read timeout.
Without one, an unreachable control-plane endpoint blocks for the SDK default (~60–600s) per call and
stalls fleet-wide provisioning. The base centralizes the values:

```ruby
DEFAULT_CONNECT_TIMEOUT = 10
DEFAULT_READ_TIMEOUT    = 60
```

Apply them by adapter style:

- **Faraday / hand-rolled REST** (azure, gcp, openstack auth): call the base helper
  `apply_http_timeouts(faraday)` inside the `Faraday.new { |f| ... }` block — it sets
  `open_timeout = DEFAULT_CONNECT_TIMEOUT` and `timeout = DEFAULT_READ_TIMEOUT`.
- **aws-sdk**: pass `http_open_timeout: DEFAULT_CONNECT_TIMEOUT, http_read_timeout: DEFAULT_READ_TIMEOUT`.
- **google client**: `config.timeout = DEFAULT_READ_TIMEOUT`.
- **fog (openstack)**: `connect_timeout: / read_timeout:` from the same constants.

Never hand-roll literal timeout numbers.

---

## 10. The Registry — making the adapter resolvable

`System::Providers::Registry` (`app/services/system/providers/registry.rb`) maps a `provider_type`
string to its adapter class and instantiates it. Classes are referenced by name and `constantize`d
lazily (so an unused SDK is never loaded):

```ruby
PROVIDER_CLASSES = {
  "aws"        => "System::Providers::AwsProvider",
  "gcp"        => "System::Providers::GcpProvider",
  # …
  "mock"       => "System::Providers::MockProvider",
  "local_qemu" => "System::Providers::LocalQemuProvider",
  "pro_cloud"  => "System::Providers::ProCloudProvider"
}.freeze
```

Callers resolve an adapter via:

- `Registry.for(connection, region: nil)` — by `ProviderConnection` (keys on `connection.provider.provider_type`).
- `Registry.for_instance(instance)` — by `System::NodeInstance` (used by `CloudSyncService`).
- `Registry.for_node(node, region:)` / `Registry.for_volume(volume)`.
- `Registry.with_adapter(connection:|instance:|node:+region:|volume:) { |adapter| … }` — yields the
  adapter, returning `Runtime::Result.err` instead of raising on an unknown type.
- `Registry.adapter_for(provider)` — the class **without** instantiating (used by
  `CredentialValidationService` for the BYOC flow).

To register a new adapter, **add an entry to `PROVIDER_CLASSES`** keyed by the exact string your
`Provider#provider_type` returns (this must equal your `provider_type` method's return value). For an
out-of-tree plugin, call `Registry.register("your_type", "Your::Adapter::ClassName")` at load time.
An unknown type raises `Registry::UnknownProviderError`.

### Adapters that need an optional SDK gem

Registration alone does not make an adapter usable. If your adapter is written against a gem that is
**not** in `server/Gemfile` (today: `aws-sdk-ec2`, `google-cloud-compute`, `fog-openstack`), declare
it on the adapter class:

```ruby
class AwsProvider < BaseProvider
  def self.required_sdk_gem = "aws-sdk-ec2"
  def self.sdk_constant     = "Aws::EC2::Client"   # presence proves the gem is loaded
end
```

`BaseProvider` defaults both to `nil`, so an adapter that runs on the core bundle (proxmox, mock,
local_qemu, pro_cloud, and azure — a hand-rolled Faraday client) needs no change. With the pair
declared, the Registry:

- **omits** the type from `Registry.available_providers` (`registered_providers` still lists every
  mapped type, operable or not);
- answers `Registry.sdk_available?(type)` / `Registry.missing_sdk_gem(type)` /
  `Registry.sdk_missing_message(type)`, and folds them into the one refusal seam every
  writer door is required to call: `Registry.sdk_refusal(type)` returns `nil` for a blank,
  unmapped or operable type and the operator-actionable message otherwise;
- raises `Registry::ProviderSdkMissingError` — a **subclass of `UnknownProviderError`**, so
  `with_adapter` and every existing rescue turn it into a `Runtime::Result.err` naming the gem —
  instead of letting the first call raise a bare `NameError` from inside the adapter.

The provider/connection front doors refuse before writing anything: `system_create_provider` and
`system_create_provider_connection` return an error result; `POST`/`PATCH`
`/api/v1/system/provider_connections` return 422 (the `PATCH` guard matters because
`connection_params` permits `:provider_id`); `POST`/`PATCH` `/api/v1/system/providers` return 422
with code `PROVIDER_SDK_MISSING` (on `PATCH` only when `provider_type` actually changes, so a
stranded row stays renameable and disableable); `POST /api/v1/system/provider_credentials` refuses
before auto-creating a `System::Provider` row; and `System::CredentialValidationService` refuses
before probing, because the BYOC probe reaches a bundled sibling gem (`aws-sdk-core` STS) and would
otherwise report a false pass for a type every adapter call refuses. The authoritative enumeration
of every `provider_type` writer and its guard is `spec/lint/provider_type_writer_census_spec.rb`,
which fails when a writer appears that the census does not list. The registry predicate itself is
covered by `spec/services/system/providers/sdk_availability_guard_spec.rb`, which drives the SDK
constant in both directions with `hide_const`/`stub_const` so it holds under the default bundle
*and* under the `provider-specs` lane described in §7.

---

## 11. Adding a new provider — step-by-step checklist

Using `MockProvider` (`app/services/system/providers/mock_provider.rb`) as the minimal template:

1. **Subclass `BaseProvider`.** Create `<name>_provider.rb` under `app/services/system/providers/`:
   `class <Name>Provider < BaseProvider`. Implement `provider_type` returning your registry key string.
2. **Implement the abstract set (§3)** — all 24 methods, with the exact signatures (mind
   `detach_volume(volume_id, force:)`, `attach_volume(volume_id, instance_id, device:)`,
   `reboot_instance`). Implement `authenticate?` as a cheap, side-effect-free probe; on failure set
   `@last_authentication_error`.
3. **Read credentials via the helpers (§5)** — `auth_credential(:access_key, …)` /
   `credential(column:, config_key:, required:)`. Never touch raw secrets in logs; use `log_operation`.
4. **Return the contract shapes (§4)** — build every instance response with `build_instance_response`
   and every error with `build_error_response`; map backend statuses through `normalize_status` into
   `BaseProvider::STATUSES`. Signal "gone" via the `code: "NotFound"` hash **or** `ResourceNotFoundError`.
5. **Apply the timeout convention (§9)** to every HTTP/SDK call.
6. **Narrow `capabilities` (§6)** if your backend lacks volumes/IPs/images/sync — don't fake them.
7. **Raise the typed errors (§8)** on auth/rate/not-found/quota failures (especially in `list_instances`).
8. **Register in the Registry (§10)** — add `"<name>" => "System::Providers::<Name>Provider"` to
   `PROVIDER_CLASSES` in `app/services/system/providers/registry.rb`. If your adapter needs a gem
   that is not in `server/Gemfile`, also declare `self.required_sdk_gem` + `self.sdk_constant`
   (§10, *Adapters that need an optional SDK gem*) so the Registry withdraws it instead of
   advertising an adapter that raises `NameError` at first call.
9. **Add a spec** at `server/spec/services/system/providers/<name>_provider_spec.rb` that calls
   `it_behaves_like "a cloud provider"` (and, as internals stabilize, the status-normalization and
   typed-error groups from `server/spec/services/system/providers/shared_examples.rb`).

---

## Related

- [`ARCHITECTURE.md`](./ARCHITECTURE.md) §2 — NodeInstance lifecycle the adapter drives, §9 — storage subsystem (volumes)
- [`USE_CASE_MATRIX.md`](./USE_CASE_MATRIX.md) — what each backend supports in practice
- `app/services/system/providers/base_provider.rb` — the authoritative contract
- `app/services/system/providers/mock_provider.rb` — the canonical minimal adapter
- `app/services/system/providers/registry.rb` — provider discovery / resolution
- `app/services/system/cloud_sync_service.rb` — the reference consumer of the return shapes
- `server/spec/services/system/providers/shared_examples.rb` — the executable contract

_Last verified: 2026-06-26_
