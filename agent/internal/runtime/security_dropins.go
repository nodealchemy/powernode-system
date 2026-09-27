package runtime

import (
	"fmt"

	"github.com/nodealchemy/powernode-system/agent/internal/lifecycle"
	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/security"
)

// securityDropInFuncs bundles the per-unit security drop-in writers for ONE
// attach path. attachModule (reconcile.go, the live cloud-init/pivot-
// reconcile path) writes to the process's own systemdDropInRoot;
// renderPivotUnits (compose.go, the boot/pivot-compose path) writes under an
// explicit sysroot. The two paths otherwise share the identical DECISION —
// see applyModuleSecurityDropIns — so only the I/O target differs.
type securityDropInFuncs struct {
	// userNamespace/seccomp/capability (W1, IMP-caef5c00d63f round W) now
	// report a `changed bool` alongside error — see writeDropInFile's own
	// doc (security/dropin_write.go) for why: a security-drop-in-ONLY
	// change moves no unit BODY at all, so applyModuleSecurityDropIns'
	// caller (applyModuleSecurityPolicy) has no other way to learn that a
	// RUNNING unit's confinement actually changed and may need a
	// daemon-reload/restart to take effect.
	userNamespace func(unit string, enabled bool) (bool, error)
	seccomp       func(unit, profilePath string) (bool, error)
	capability    func(unit string, allow []string) (bool, error)
	// removeSeccomp/removeCapability (R7, review round 14, hygiene) remove a
	// STALE seccomp.conf/capabilities.conf a PRIOR policy left behind — a
	// manifest edit that stops declaring a profile, or a unit becoming
	// privileged (which opts out of the corresponding write entirely), must
	// not leave that file still enforced. Absence is success; see
	// security.RemoveSeccompDropIn(At)/RemoveCapabilityDropIn(At)'s own doc.
	// Also now report `changed` (W1) for the same reason: removing a STALE
	// drop-in is itself a confinement change a running unit needs applied.
	removeSeccomp    func(unit string) (bool, error)
	removeCapability func(unit string) (bool, error)
	// removeLegacyAmbientCapability (X6, IMP-caef5c00d63f round X, HIGH,
	// B1 — delta on W3) removes a PRIOR (older-agent) compose's stand-alone
	// ambient-capabilities.conf, run as its OWN independent step for EVERY
	// unit regardless of posture (privileged or not — the legacy file is
	// stale cruft either way). Deliberately separate from the capability/
	// removeCapability calls above: a failure here is ALWAYS non-fatal (see
	// applyModuleSecurityDropIns' own call site) — merging it into the
	// primary write/remove's own error (the pre-X6 shape) meant a failure
	// cleaning up this unrelated legacy file discarded a SUCCESSFUL primary
	// write and failed the unit closed, which then never restarted to pick
	// up the narrower capabilities.conf that had, in fact, already landed.
	removeLegacyAmbientCapability func(unit string) (bool, error)
}

// qgaModuleName is R5's own pinned recovery-channel identity check (review
// round 14): this self-hosted control plane's host-root recovery path
// (qemu-guest-agent) is INTENTIONALLY declared non-privileged — its own
// manifest's rationale (see security.WriteCapabilityDropInAt's doc): a
// `privileged: true` request is refused by an account's own
// privileged_module_ids allowlist it may not be on, so qga instead
// declares the full known capability set directly. It therefore cannot
// rely on privilegedApproved alone to qualify for the full-capability-set
// exemption below. Pinned by NAME because the agent has no other reliable
// per-module identity signal today — publishing a signed module under this
// exact name to the shared catalog is itself a privileged, server-gated
// action, so an arbitrary untrusted manifest cannot simply declare its way
// into this name.
//
// TODO(server): deliver a proper allowlist/exemption field from the
// platform instead of pinning by name — this is the interim fix.
const qgaModuleName = "qemu-guest-agent"

// qualifiesForFullSetExemption reports whether a module may receive the
// full-capability-set drop-in-write-failure exemption below (R5, review
// round 14, SECURITY): that exemption's whole justification is "this
// module's resolved posture is ALREADY the maximal/unconfined one, so a
// write failure changes nothing" — which is only true for a module an
// operator (the privileged allowlist) or this node itself (qga, its own
// recovery channel) actually TRUSTS to run unconfined. Before this, ANY
// module whose manifest happened to resolve to the full capability set —
// via an explicit `capabilities: [...]` list, which needs no operator
// approval at all, unlike `privileged: true` — got the IDENTICAL "never
// fail closed" treatment, regardless of whether anything ever approved it
// for that posture.
func qualifiesForFullSetExemption(moduleID string, mf *manifest.Manifest, privilegedAllow []string) bool {
	if privilegedApproved(moduleID, privilegedAllow) {
		return true
	}
	return mf != nil && mf.Name == qgaModuleName
}

// applyModuleSecurityDropIns writes every one of mf's services' security
// drop-ins (PrivateUsers=, SystemCallFilter=, CapabilityBoundingSet=/
// AmbientCapabilities=) through funcs, and returns the DEDUPED set of units
// that must FAIL CLOSED (IMP-caef5c00d63f phase 3/4 — see compose.go's
// redesign doc comment on renderPivotUnits for the full reasoning, restated
// briefly here since attachModule shares it):
//
//   - a capability write failure fails closed UNLESS the resolved allow set
//     already equals security.KnownCapabilities in full AND the module
//     qualifies for that exemption (R5, review round 14 — qualifiesForFullSetExemption:
//     the privileged allowlist, or this node's own qga recovery channel —
//     a write failure changes nothing security-wise for a unit already at
//     the ceiling, e.g. qemu-guest-agent, but only a TRUSTED module may
//     rely on that reasoning rather than merely resolving to the same
//     shape);
//   - a user-namespace write failure fails closed UNLESS policy.UserNamespace
//     is already false (PrivateUsers=no is systemd's own default absent the
//     directive, so a false-policy write failure leaves the SAME posture —
//     true for ANY module regardless of identity, since it never grants
//     anything beyond what systemd already defaults to);
//   - a seccomp write failure ALWAYS fails closed — an absent filter is
//     "every syscall allowed", never equivalent to a declared profile.
//
// Privileged modules opt out of the capability/seccomp writes entirely (they
// accept ALL capabilities by design), but NOT the user-namespace write —
// PrivateUsers is orthogonal to the privileged opt-out, so a failure there is
// exactly as real a regression for a privileged module as for any other.
//
// DEDUPED (review F6): userns.conf and capabilities.conf (and, when a
// profile is declared, seccomp.conf) live in the SAME <unit>.d directory, so
// one directory-level failure (a stray file blocking MkdirAll, ENOSPC) can
// trip more than one of the three writes for the SAME unit in one pass. A
// unit that fails on two counts must still be named ONCE in the returned
// list — a caller that folds it into a breadcrumb or a heartbeat field
// treats the list as a SET of affected units, not an event log, and a
// duplicate there would silently double-count in anything that sums or
// dedupes further downstream.
//
// onError receives an UNPREFIXED stage name ("userns_dropin",
// "seccomp_dropin", "capability_dropin", "capability_dropin_exempt"); each
// caller wraps it with its own path's existing prefix ("compose:" /
// "reconciler:") so neither path's OnError stage names change shape from
// before this helper existed.
//
// changedUnits (W1, IMP-caef5c00d63f round W) is the DEDUPED set of units
// whose on-disk drop-in bytes actually changed this pass — a write that hit
// writeDropInFile's own skip-if-identical path, or a remove of an
// already-absent file, never adds a unit here. The live reconcile path
// (applyModuleSecurityPolicy) needs this to decide whether a RUNNING unit's
// confinement actually moved and needs a daemon-reload/restart; the
// boot/pivot-compose path (compose.go) discards it — nothing is running yet
// at that point, so "changed" carries no restart decision to make.
func applyModuleSecurityDropIns(moduleID string, mf *manifest.Manifest, policy *security.Policy, unitAllow map[string][]string, privilegedAllow []string, funcs securityDropInFuncs, onError func(stage string, err error)) (changedUnits, failedUnits []string) {
	seenFailed := make(map[string]bool)
	fail := func(unit string) {
		if seenFailed[unit] {
			return
		}
		seenFailed[unit] = true
		failedUnits = append(failedUnits, unit)
	}
	seenChanged := make(map[string]bool)
	markChanged := func(unit string, changed bool) {
		if !changed || seenChanged[unit] {
			return
		}
		seenChanged[unit] = true
		changedUnits = append(changedUnits, unit)
	}

	for _, svc := range mf.Services {
		unit := lifecycle.UnitName(moduleID, svc.Name)

		// X6 (IMP-caef5c00d63f round X, HIGH, B1): run BEFORE and
		// INDEPENDENTLY of every other write/remove below, for every unit
		// regardless of posture (privileged or not — the legacy file is
		// stale cruft either way, same reasoning W3 already applied).
		// Best-effort like the privileged branch's own removeSeccomp/
		// removeCapability calls: a failure here is reported but NEVER
		// fails the unit closed and never discards another call's own
		// changed=true — merging it into the primary capability write's own
		// error (the pre-X6 shape) is exactly what let a successful
		// narrowing write get thrown away by an unrelated cleanup failure.
		if changed, err := funcs.removeLegacyAmbientCapability(unit); err != nil {
			onError("legacy_ambient_capability_dropin_remove", fmt.Errorf("module %s unit %s: %w", moduleID, unit, err))
		} else {
			markChanged(unit, changed)
		}

		if changed, err := funcs.userNamespace(unit, policy.UserNamespace); err != nil {
			onError("userns_dropin", fmt.Errorf("module %s unit %s: %w", moduleID, unit, err))
			if policy.UserNamespace {
				fail(unit)
			}
		} else {
			markChanged(unit, changed)
		}

		if policy.Privileged {
			// R7 (review round 14, hygiene): a unit that has since become
			// privileged opts out of the capability/seccomp WRITES entirely
			// (below) — but a STALE seccomp.conf/capabilities.conf from a
			// PRIOR non-privileged state must not keep narrowing it below
			// what "privileged" means, forever. Best-effort: a removal
			// failure is reported but never fails the unit closed — unlike
			// a write failure, it cannot leave the unit MORE exposed than
			// its manifest declares.
			if changed, err := funcs.removeSeccomp(unit); err != nil {
				onError("seccomp_dropin_remove", fmt.Errorf("module %s unit %s: %w", moduleID, unit, err))
			} else {
				markChanged(unit, changed)
			}
			if changed, err := funcs.removeCapability(unit); err != nil {
				onError("capability_dropin_remove", fmt.Errorf("module %s unit %s: %w", moduleID, unit, err))
			} else {
				markChanged(unit, changed)
			}
			continue
		}

		if policy.SeccompProfile != "" {
			if changed, err := funcs.seccomp(unit, policy.SeccompProfile); err != nil {
				onError("seccomp_dropin", fmt.Errorf("module %s unit %s: %w", moduleID, unit, err))
				fail(unit)
			} else {
				markChanged(unit, changed)
			}
		} else if changed, err := funcs.removeSeccomp(unit); err != nil {
			// R7: no profile declared (or no longer declared) — remove any
			// STALE seccomp.conf a PRIOR policy left behind, so a manifest
			// edit that drops seccomp_profile actually takes effect on the
			// NEXT attach, not just "stop writing a new one" while the old
			// one stays loaded and enforced.
			onError("seccomp_dropin_remove", fmt.Errorf("module %s unit %s: %w", moduleID, unit, err))
		} else {
			markChanged(unit, changed)
		}

		allow := unitAllow[unit]
		if changed, err := funcs.capability(unit, allow); err != nil {
			// R5 (review round 14, SECURITY): the full-set exemption requires
			// BOTH the resolved shape (full capability set) AND a trusted
			// identity (qualifiesForFullSetExemption) — a module merely
			// shaped like the trusted case, with no operator approval and no
			// pinned recovery-channel name, fails closed like anything else.
			if security.IsFullCapabilitySet(allow) && qualifiesForFullSetExemption(moduleID, mf, privilegedAllow) {
				onError("capability_dropin_exempt",
					fmt.Errorf("module %s unit %s: %w — resolved set is the full known-capability ceiling for a trusted module, not failing closed", moduleID, unit, err))
			} else {
				onError("capability_dropin", fmt.Errorf("module %s unit %s: %w", moduleID, unit, err))
				fail(unit)
			}
		} else {
			markChanged(unit, changed)
		}
	}

	return changedUnits, failedUnits
}
