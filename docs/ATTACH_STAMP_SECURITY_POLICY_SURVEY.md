# attachStamp / security-policy drop-in survey (IMP-f5c0afa7183a)

Survey only — no code changed by this document. Filed per the audit-report-only
convention, ahead of the fix task.

## The confirmed defect

`attachStamp` (`agent/internal/runtime/reconcile.go:1231`, pre-fix position
`:1187` — line numbers below are as of the fix landing, not the pre-fix
survey pass) is:

```go
lifecycle.RenderedServicesHash(moduleID, mf.Services, pivotAwareRootMode()) + "|" + r.cfg.AgentVersion
```

`RenderedServicesHash` (`agent/internal/lifecycle/service.go:956`) hashes, per
service, `UnitName(moduleID, svc.Name)` and `RenderUnitModeGraph(...)` — i.e.
the rendered **unit body** only. It has no input derived from the module's
`security:` manifest block.

The stamp gates re-attach on the cloud-init hot-reconcile path: `RunOnce`
computes `fresh := r.attachStamp(mod.ID, mf)` and only queues a module into
`toReattach` when `fresh != current.LastAttachedManifestHashes[mod.ID]`
(`reconcile.go:445-448`). `attachModule` (`reconcile.go:1058`), which is where
every security-policy enforcement step actually runs, is invoked only for
modules in `toAttach` or `toReattach`. So on that path: **a manifest edit
confined to the `security:` block leaves the stamp byte-identical, the module
is never re-queued, and `attachModule` never runs again** — not just the
drop-in writes, the whole enforcement sequence inside it.

## Enumeration: what `attachModule` applies from `security:` and how

All of the following are constructed once per module by `buildPolicy(mf)`
(`reconcile.go:1707-1758`, pre-fix `:1660-1711`) from `m.Config["security"]`, and are then applied
inside `attachModule`, in this order (`policy.Apply`, `policy.go:80-106`,
plus the three per-unit drop-in loops that follow it directly in
`attachModule`, `reconcile.go:1085-1130`):

| Field | Source key | Applied by | Mechanism | Per-unit or per-module | Covered by `RenderedServicesHash`? |
|---|---|---|---|---|---|
| `Capabilities` | `security.capabilities` | `WriteCapabilityDropIn` | systemd drop-in `<unit>.d/capabilities.conf` (`CapabilityBoundingSet=`, `AmbientCapabilities=`) | per-unit | No |
| `SeccompProfile` | `security.seccomp_profile` | `WriteSeccompDropIn` | systemd drop-in `<unit>.d/seccomp.conf` (`SystemCallFilter=@<name>`) | per-unit | No |
| `UserNamespace` | `security.user_namespace` (default `true`) | `WriteUserNamespaceDropIn` | systemd drop-in `<unit>.d/userns.conf` (`PrivateUsers=`) | per-unit | No |
| `SELinuxProfile` | `security.selinux_profile` | `LoadSELinuxProfile` (via `policy.Apply` → `loadMACProfile`) | `semodule`-class load of a compiled `.pp`, not a drop-in — module-wide LSM state | per-module (not per-unit) | No |
| `AppArmorProfile` | `security.apparmor_profile` | `LoadAppArmorProfile` (via `policy.Apply` → `loadMACProfile`) | `apparmor_parser` load, not a drop-in — module-wide LSM state | per-module | No |
| `Privileged` | `security.privileged` | gates capabilities and MAC at the write site (skip when true, subject to `privilegedAllow`) — see note below for seccomp | n/a | per-module | No (but see below) |

**Correction from review, seccomp is NOT gated by `Privileged` at the write
site.** `attachModule`'s seccomp loop (`reconcile.go:1088`, `if
policy.SeccompProfile != ""`) has no `!policy.Privileged` condition at all,
unlike the capability loop directly below it (`reconcile.go:1104`, `if
!policy.Privileged`). A Privileged module can only ever reach the seccomp
loop with an empty `SeccompProfile` today because `Policy.Validate`
(`policy.go:210`) refuses a Privileged policy that also declares
`SeccompProfile` — a refusal in a DIFFERENT file, not a write-site gate.
`security.RenderedPolicyHash` mirrors the write site literally (gates
seccomp on `SeccompProfile != ""` alone, not on `!Privileged`) rather than
assuming uniformity across the three drop-in families — see its own doc
comment and `TestPolicyValidate_RejectsPrivilegedWithSeccomp`, which pins the
Validate coupling this reasoning depends on. If that coupling is ever
relaxed, the stamp already tracks the write site correctly with no further
change needed; a stamp that had instead gated seccomp on `!Privileged` (to
"match" capabilities) would go stale for seccomp on privileged modules the
moment Validate stopped preventing the combination — this exact defect
class, reintroduced one field at a time.

`dropCapabilities` (`policy.go:167` → `DropCapabilitiesExcept`,
`capabilities.go:104`) is a **no-op except name validation** — the code
comment there is explicit that real enforcement moved to
`WriteCapabilityDropIn` and this function now only validates the allowlist.
So it's not a separate write path; already covered by the capabilities row
above.

**Conclusion: the gap is not capabilities-specific.** It is a property of
the stamp — it describes only the rendered unit body — and every field in
the module's `security:` block is invisible to it identically, whether that
field is enforced via a systemd drop-in (capabilities, seccomp,
user-namespace) or via a direct LSM policy load (SELinux, AppArmor). A
drop-in-only survey would have under-scoped the fix: the MAC profile loaders
are not drop-ins at all, but they are gated by exactly the same broken
stamp and would silently go stale the same way (e.g. a manifest edit that
changes `apparmor_profile` from one agent-owned profile name to another
would never reload on a live node).

## Search strategy for "every drop-in the agent writes" (breadth check)

Per house convention on negative claims, a single grep pattern is not
sufficient evidence of completeness. Three independent passes were run
against the whole `agent/` tree:

1. Named-convention search: `WriteCapabilityDropIn`, `WriteSeccompDropIn`,
   `WriteUserNamespaceDropIn` and their `*At` pivot forms — found exactly
   these three families, defined in `security/capabilities.go`, `mac.go`,
   `userns_dropin.go`.
2. Path-literal search: `filepath.Join(...".d")` / `systemd/system` /
   `os.WriteFile` across all of `agent/internal/` (not filtered by name),
   to catch a drop-in writer that doesn't follow the `WriteXDropIn` naming
   convention. This surfaced two more systemd-unit writers worth
   dispositioning explicitly (below) and no additional drop-in family.
3. Targeted negative check against files that matched an earlier, noisier
   sweep (`etcsudoers`, `k3sd/shell_applier.go`, `storage/exports.go`,
   `runtime/dhcp_renew.go`, `runtime/softreboot.go`) for the specific
   `<unit>.d` directory-construction pattern the three known families use —
   zero further matches.

### Other systemd-unit writers found, and why they're out of scope

- **`agent/internal/storage/{systemd,gateway,exports}.go`** write full
  `.mount`/`.service` unit bodies and `/etc/exports[.d]` entries for NFS/CIFS
  storage assignments. These are dispatched per-task
  (`MountTask`/`GatewayProvisionTask`/`ExportsApplyTask`) from the storage
  subsystem, not from module reconcile — they carry no `moduleID`, are never
  read by `attachStamp`, and have their own idempotency (content compare /
  `stopAndRemoveMountUnit`). Not part of this defect class.
- **`agent/internal/k3sd/shell_applier.go`: `WriteJoinConfig`** writes a real
  systemd drop-in (`k3s-agent.service.d/override.conf`, an `Environment=`
  override). This runs from `k3sd.Manager.Tick`, a wholly separate ticker
  from the `Reconciler` (`runtime/service.go:275-298`), with its own
  idempotency check (`HasJoinConfig` stats the file directly — no stamp of
  any kind). It is not gated by `attachStamp` and was never intended to be;
  noted here for completeness of the "every drop-in" enumeration, not as an
  instance of the defect.

## The pivot-compose path does not have this defect at all

`ComposeForPivot` (`compose.go:47`) is called from exactly two places:
`powernode-agent`'s pivot/boot command (`commands.go:429`) and
`soft-recompose` (`soft_recompose.go:97`) — both build a **fresh union from
scratch** (a new scratch root each time; `soft-recompose`'s own doc comment:
"a fresh generation each time is the only safe option"). Neither compares
any stamp or persisted hash before calling it. Every module in the boot
composition has its unit bodies and `security:`-derived drop-ins
(`WriteUserNamespaceDropInAt`, `WriteSeccompDropInAt`,
`WriteAmbientCapabilityDropInAt`, `compose.go:219-255`) rewritten
unconditionally on every invocation.

So the staleness bug is exclusively a property of the cloud-init
hot-reconcile path's re-attach gate. A drop-in-only (or any `security:`-only)
manifest change already takes effect correctly on the next reboot or
`soft-recompose`; it only fails to propagate to an already-attached,
never-rebooted node. This matters for the fix's shape: only `attachStamp` /
`RenderedServicesHash` (or a sibling used solely by the hot-reconcile gate)
needs to change. `ComposeForPivot` needs no equivalent stamp — it has no
staleness to protect against.

## The known, already-accepted pivot-path asymmetry (documented, not to be fixed here)

Two asymmetries between the cloud-init and pivot-compose enforcement of the
same `security:` block are already known and explicitly disclosed elsewhere
in the codebase — restated here because they interact with anything this
task's fix touches, but per the brief neither is in scope to change:

- **Capabilities are additive-only on the pivot path.**
  `WriteAmbientCapabilityDropInAt` never resets `CapabilityBoundingSet=`,
  only raises `AmbientCapabilities=` (`compose.go:186-189`, `service.go:763
  -769` heartbeat comment). An explicit empty capability list is therefore a
  no-op on this path (`compose.go:249`: `if len(policy.Capabilities) > 0`
  guards the write entirely) — deliberate, pending a per-module
  runtime-capability audit. The heartbeat discloses this by listing
  `capability_bounding_set` in `PivotConfinementOmitted`
  (`service.go:770-779`).
- **SELinux/AppArmor are not loaded on the pivot path at all.**
  `loadMACProfile` runs only inside `policy.Apply`, which `ComposeForPivot`
  never calls (it calls `policy.Validate()` directly, `compose.go:203`, and
  skips straight to unit/drop-in writes). The heartbeat discloses this too:
  `mandatory_access_control` is the second entry in
  `PivotConfinementOmitted`. So a module's `selinux_profile`/
  `apparmor_profile` is inert post-pivot regardless of what this task does
  about the hot-reconcile stamp — a separate, already-tracked gap.

Neither asymmetry is part of the stamp defect and neither should be touched
by this task's fix — restated here only so the fix's own tests don't
mistake either disclosed gap for a regression.

## The existing parity-test convention to extend

`RenderedServicesHash`'s own anti-drift test is
`TestRenderedServicesHash_MatchesTheFilesAttachWrites`
(`agent/internal/lifecycle/rendered_hash_test.go:86-117`): it attaches for
real via `AttachServicesModeOpts`, reads the actual on-disk unit bytes, hashes
them with the identical construction `RenderedServicesHash` uses, and asserts
equality — so the hash can never silently stop describing the file it claims
to describe. The fix needs an equivalent test for whatever it adds: write the
security-policy drop-in(s) for real via `WriteCapabilityDropIn` /
`WriteSeccompDropIn` / `WriteUserNamespaceDropIn` (and the SELinux/AppArmor
loaders, or an explicit note if those are handled by an unrelated signal),
read the actual bytes/state, and assert the new stamp component matches.

`agent/internal/runtime/attach_stamp_test.go` is the stamp-level test file
and already pins the exact zero-services shape
(`TestAttachStamp_NoServices` asserts `"|9.9.9"` for a manifest with no
services). Any fix that adds bytes to the stamp for a module's `security:`
block must account for this fixture explicitly — a module with services but
no security block, and a module with no services but a security block, are
two different pinned shapes the new test coverage needs to add rather than
leave implicit.

## Verification-shape note for the fix task

Per the standing rule to verify the input that makes a guard *fire*: the
test that matters is one where a manifest changes `security:` only (unit
body byte-for-byte identical) and asserts the stamp changes. The existing
`TestRenderedServicesHash_MovesWhenOnlyTheRenderingDiffers` is the template
for this shape (root-mode-only manifest change, unit body diverges, stamp
must diverge) — the fix's new test is the same shape with the *manifest's*
`security:` block as the varying input instead of root mode.

## Re-attach cost reasoning for the drop-in paths specifically

`attachStamp`'s own comment states the false-positive cost is bounded
because "attachModule is idempotent on its mount/cosign/fs-verity/policy
steps, each unit goes through writeIfChanged, and daemon-reload runs only if
something was written." Checked against the drop-in writers specifically:
`WriteCapabilityDropIn`, `WriteSeccompDropIn`, and `WriteUserNamespaceDropIn`
(and their `*At` pivot forms) all do an unconditional tmp-write +
`os.Rename` on every call — none of them compare existing content first, so
none of them are `writeIfChanged` internally. A one-time fleet-wide
re-attach after the fix ships will therefore rewrite every module's
drop-in files unconditionally (bytes will be identical to what's already on
disk for any module whose `security:` block hasn't actually changed, but the
write happens regardless of that) — more re-write work than the unit-body
path's `writeIfChanged` does today.

**Correction from review: this is NOT "still cheap" in absolute terms, and
that is not actually why shipping the fix is safe.** `mountModuleArtifact`
(called at the start of every `attachModule`, regardless of which stamp
segment changed) invokes `Puller.Pull`, whose cache-hit path
(`oci.readDigest`) streams the ENTIRE cached erofs blob through SHA-256
before returning, and `VerifyBlob` runs on top of that — real,
size-proportional cost per module, not a bounded three-small-files-plus-
daemon-reload cost. The drop-in writes are a small piece of a pass whose
real cost lives in that pull/verify step, which already runs on any
re-attach regardless of what this fix adds. The reason shipping this fix is
safe is that it ships inside a new agent binary — necessarily a new
`AgentVersion`, which was already the third stamp segment before this fix
existed — so exactly one fleet-wide re-attach pass happens on THIS upgrade
regardless of whether the security-policy segment is also new; the new
segment adds no additional fleet-wide pass beyond the one an agent upgrade
already causes every time. Worth flagging as a design input for a future
fix rather than a blocker on this one: extending the drop-in writers
themselves to `writeIfChanged` would reduce the marginal write cost of a
false-positive re-attach that ISN'T bundled with an agent upgrade, but is
additional scope beyond stamping the output and not required to close this
defect.

## Addendum: scope decision and fix design (post-review)

Two corrections from review, both incorporated into the implementation:

**SELinux/AppArmor are IN SCOPE.** They are gated by the identical
`attachStamp` staleness bug via the identical `buildPolicy(mf)` output;
splitting them into a follow-up would have shipped a fix that stamps some of
a module's resolved security policy and not the rest — the same half-measure
shape that created this bug in the first place (IMP-01a05efa stamped unit
bodies and not drop-ins).

Before including them, `semodule -i` and `apparmor_parser -r` re-application
safety was checked. Neither is empirically exercised from this codebase or
sandbox (no SELinux/AppArmor-enabled host is available here, and loading real
LSM policy is not something to attempt as a side effect of a docs pass).
Based on documented tool semantics: `semodule -i` on an already-installed,
byte-identical module is the standard idiom infrastructure tools (Ansible,
Puppet) call unconditionally on every convergence run without a pre-diff —
it is designed to be safe to re-run, though it may cost a policy-store
relink rather than being a true no-op. `apparmor_parser -r` ("replace") is
explicitly the intended reload operation, lightweight, and does not disturb
already-running processes' existing enforcement. This was flagged as
reasoned, not proven, and held as an open precondition on the scope decision.

**Resolved, in scope's favour, by a fact rather than by accepting the
reasoning as sufficient on its own:** no module under `modules/*/manifest.yaml`
on this fleet currently declares `selinux_profile` or `apparmor_profile`.
The MAC-load path is therefore INERT today — the one-time fleet-wide
re-attach this fix causes cannot invoke `semodule` or `apparmor_parser` at
all, because no module has a profile to load, so the unverified idempotency
assumption carries zero risk on this shipment. Descoping SELinux/AppArmor to
avoid the unproven assumption would have shipped a known-identical defect
for those two fields for no safety gain; shipping on the assumption alone,
had a module already declared a profile, would not have been acceptable.

**This does not close the question — it relocates it to a future event.**
`semodule -i` / `apparmor_parser -r` re-runnability on this fleet's actual
images remains UNVERIFIED, is currently unexercised for the reason above,
and MUST be verified before the first module declares a `selinux_profile` or
`apparmor_profile` — framed as a precondition on that event, not as settled.
Tracked separately so it survives this doc going stale: 01a0c063-993f.

**The fix does NOT stamp the resolved `security.Policy` struct.** The
initial proposal was `security.RenderedPolicyHash(policy)` hashing the
Policy's fields directly. Correction: `WriteCapabilityDropIn`'s emitted
bytes are not a pure function of the declared capability list alone — the
writer normalizes case, adds the `CAP_` prefix, and sorts before emitting.
A stamp built from the raw fields would be blind to a future fix in how a
writer RENDERS its bytes (the directive it emits, the normalization, the
ordering) exactly the way the pre-fix `attachStamp` was blind to a renderer
fix in unit bodies — IMP-01a05efa reproduced one layer over. The
implemented fix instead:

- Factors each cloud-init drop-in writer (`WriteCapabilityDropIn`,
  `WriteSeccompDropIn`, `WriteUserNamespaceDropIn`) into a pure
  `render*DropInBody` function plus a thin write, so the writer and the new
  `security.RenderedPolicyHash` (`agent/internal/security/policy_stamp.go`)
  consume the identical render — one render function, two callers, the same
  relationship `RenderUnitModeGraph` has to `RenderedServicesHash`.
- For SELinux/AppArmor, where there is no agent-rendered artifact to hash
  (the "render" is the profile file itself, authored outside the agent),
  hashes the resolved profile file's CONTENT (`hashResolvedProfileOrName`),
  falling back to hashing the bare declared name on any resolution/read
  failure — so editing a profile in place moves the stamp, and an
  unresolvable declaration still produces a deterministic, non-erroring
  value rather than blocking stamp computation (the real resolution failure
  surfaces separately, loudly, when `LoadSELinuxProfile`/
  `LoadAppArmorProfile` attempt the identical resolution inside
  `Policy.Apply`).
- Mirrors attachModule's own write-time branching LITERALLY, per component,
  rather than assuming uniformity: `Privileged` gates capabilities and MAC
  (SELinux/AppArmor) at the write site, and the stamp mirrors that; seccomp
  is gated only on `SeccompProfile != ""`, with NO `!Privileged` condition at
  either the write site or the stamp — a first pass wrongly nested seccomp
  inside the same `!Privileged` block as capabilities, which review caught by
  reading `reconcile.go:1088` against `:1104` side by side. User-namespace is
  written unconditionally regardless of `Privileged`. Capabilities/seccomp/
  userns are per-unit and omitted entirely when the module has zero units;
  SELinux/AppArmor are per-module and participate regardless of unit count.
  See `RenderedPolicyHash`'s doc comment for the full mapping, and
  `TestPolicyValidate_RejectsPrivilegedWithSeccomp` for the `Policy.Validate`
  coupling this asymmetry currently relies on to be unreachable in practice.
- `attach_stamp_test.go`'s `TestAttachStamp_NoServices` fixture was updated
  deliberately (not left to break silently): a service-less module with no
  `security:` block now stamps `"||9.9.9"` (two empty hash segments plus the
  agent version) rather than the old `"|9.9.9"`, and a new
  `TestAttachStamp_NoServicesButSELinuxProfileDeclared` pins the case that
  fixture does NOT cover — a service-less module whose module-level
  `security.selinux_profile` still contributes, since MAC profile loading is
  per-module, not per-unit.

Two test shapes were added per the review's own framing of what the
verification needs to prove:

1. `TestAttachStamp_MovesWhenOnlySecurityPolicyDiffers`
   (`internal/runtime/attach_stamp_test.go`) — the "moves when only X
   differs" shape, security: block as the varying input instead of root
   mode. Red-first confirmed: hand-reverted `attachStamp` to the pre-fix
   two-segment shape, this test (and `TestAttachStamp_NoServices`) failed
   exactly as predicted, then the fix was restored and the full `agent`
   module test suite (`go test ./...`) passed clean.
2. `TestRenderedPolicyHash_MatchesTheDropInsWritersProduce`
   (`internal/security/policy_stamp_test.go`) — the renderer-parity shape
   mirroring `TestRenderedServicesHash_MatchesTheFilesAttachWrites`: writes
   drop-ins for real via the production writers (capabilities, seccomp, and
   userns — all three, after review flagged the first version covered only
   two of the three writers), reads the actual on-disk bytes, and asserts
   `RenderedPolicyHash` equals a hash of those bytes. `want` is built from
   `os.ReadFile` of the real written bytes, never from calling a
   `render*DropInBody` function directly — so a `RenderedPolicyHash`
   reimplementation that hashed the Policy struct's fields instead of the
   render would diverge and fail here. The narrower residual this test does
   NOT catch, stated precisely per review rather than overclaimed: a future
   reimplementation that duplicated a writer's template byte-for-byte
   inline (instead of calling `render*DropInBody`) would still pass today
   and only drift the next time that writer's template changes — only
   structural review of "does `RenderedPolicyHash` call `render*DropInBody`"
   catches that shape.

Also added: `TestRenderedPolicyHash_StableUnderNormalizedEquivalentCapabilities`
(no spurious re-attach on a case/order-only edit), `_NoUnitsOmitsPerUnitComponents`,
`TestRenderedPolicyHash_PrivilegedSuppressesCapabilitiesEntirely` (capabilities
only — seccomp's Privileged interaction is covered separately, see below),
`_NilPolicy`, `TestHashResolvedProfileOrName_MovesWithFileContent` /
`_FallsBackToNameOnUnresolvable` for the MAC-profile content-hash path, and
`TestPolicyValidate_RejectsPrivilegedWithSeccomp`
(`internal/security/security_test.go`) pinning the `Policy.Validate` coupling
the seccomp gating design depends on.

Files changed: `agent/internal/security/capabilities.go`,
`agent/internal/security/mac.go`, `agent/internal/security/userns_dropin.go`
(pure render extraction, no behavior change to the writers themselves),
`agent/internal/security/policy_stamp.go` (new — includes the review-round
fix moving seccomp's gate out of the `!Privileged` block to match the write
site literally), `agent/internal/security/policy_stamp_test.go` (new),
`agent/internal/security/security_test.go` (one new test, above),
`agent/internal/runtime/reconcile.go` (`attachStamp`, plus the re-attach-cost
comment rewrite — see the section above),
`agent/internal/runtime/attach_stamp_test.go` (includes the fix to
`TestAttachStamp_MovesWhenOnlySecurityPolicyDiffers`'s precondition, which
originally passed the same `services` slice to both manifests, making the
precondition trivially — and uselessly — true; now two independently
constructed, content-equal slices, so a future edit that accidentally lets
them drift apart is actually caught),
`agent/internal/runtime/reconcile_test.go` (`testAttachStamp` helper updated
to the new three-segment shape — this is what caused
`TestReconcilerRunOnceNoOpsWhenStateMatches`,
`TestReconcilerRunOnceReattachesOnManifestChange`, and
`TestReconcilerHotReconcileSkipsAndWarnsWhenRebootRequired` to fail
transiently mid-implementation: their seeded state hashes used the helper
before it was updated, so they briefly disagreed with the real (fixed)
`attachStamp` — resolved by updating the shared helper, not the tests'
individual assertions). `ComposeForPivot`/`compose.go` were NOT touched —
confirmed out of scope earlier in this document. No manifest, pointer, or
deploy-facing file changed.

## Summary

- The gap is a property of the stamp, not of capabilities: it spans all of
  capabilities, seccomp, user-namespace (all drop-in-based) and SELinux/
  AppArmor (LSM-load-based) identically, because none of `buildPolicy`'s
  output ever reaches `RenderedServicesHash`.
- The defect only afflicts the cloud-init hot-reconcile re-attach gate.
  `ComposeForPivot` (boot and soft-recompose) rebuilds everything from
  scratch on every invocation and has no stamp to go stale.
- No drop-in emitter exists outside the three known families
  (capabilities/seccomp/userns); two other systemd-unit writers were found
  and dispositioned as out of scope (storage mount/export units; k3sd's
  independently-ticked join-config drop-in).
- The two pivot-path asymmetries (additive-only capabilities; no MAC
  profile loading) are pre-existing, disclosed via the heartbeat, and out of
  scope for this task's fix.
- **Superseded by the Addendum below**: this bullet originally proposed
  hashing the resolved `security.Policy` struct directly. Review corrected
  that — the implemented fix hashes the RENDERED bytes each drop-in writer
  produces (via shared `render*DropInBody` functions) and the resolved MAC
  profile file's CONTENT, precisely because hashing the Policy's fields
  would repeat IMP-01a05efa one layer over. See the Addendum for the final
  design and why.
- SELinux/AppArmor were brought into scope (not deferred) because they share
  the identical `buildPolicy(mf)` / `attachStamp` staleness bug; the
  `semodule`/`apparmor_parser` re-runnability question this raised is
  resolved for THIS shipment only because no module on the fleet currently
  declares a MAC profile (the load path is inert today) — not because the
  question itself is settled. See the Addendum and 01a0c063-993f.
- Review also caught that `attachModule`'s seccomp write loop is gated only
  on `SeccompProfile != ""`, with no `!Privileged` condition — unlike
  capabilities and MAC, which are. The stamp mirrors each write site
  literally rather than assuming the three drop-in families are gated
  uniformly.
