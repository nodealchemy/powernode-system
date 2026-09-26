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
	userNamespace func(unit string, enabled bool) error
	seccomp       func(unit, profilePath string) error
	capability    func(unit string, allow []string) error
}

// applyModuleSecurityDropIns writes every one of mf's services' security
// drop-ins (PrivateUsers=, SystemCallFilter=, CapabilityBoundingSet=/
// AmbientCapabilities=) through funcs, and returns the DEDUPED set of units
// that must FAIL CLOSED (IMP-caef5c00d63f phase 3/4 — see compose.go's
// redesign doc comment on renderPivotUnits for the full reasoning, restated
// briefly here since attachModule shares it):
//
//   - a capability write failure fails closed UNLESS the resolved allow set
//     already equals security.KnownCapabilities in full (a write failure
//     changes nothing security-wise for a unit already at the ceiling —
//     e.g. qemu-guest-agent, this control plane's host-root recovery
//     channel);
//   - a user-namespace write failure fails closed UNLESS policy.UserNamespace
//     is already false (PrivateUsers=no is systemd's own default absent the
//     directive, so a false-policy write failure leaves the SAME posture);
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
func applyModuleSecurityDropIns(moduleID string, mf *manifest.Manifest, policy *security.Policy, unitAllow map[string][]string, funcs securityDropInFuncs, onError func(stage string, err error)) []string {
	seen := make(map[string]bool)
	var failedUnits []string
	fail := func(unit string) {
		if seen[unit] {
			return
		}
		seen[unit] = true
		failedUnits = append(failedUnits, unit)
	}

	for _, svc := range mf.Services {
		unit := lifecycle.UnitName(moduleID, svc.Name)

		if err := funcs.userNamespace(unit, policy.UserNamespace); err != nil {
			onError("userns_dropin", fmt.Errorf("module %s unit %s: %w", moduleID, unit, err))
			if policy.UserNamespace {
				fail(unit)
			}
		}

		if policy.Privileged {
			continue
		}

		if policy.SeccompProfile != "" {
			if err := funcs.seccomp(unit, policy.SeccompProfile); err != nil {
				onError("seccomp_dropin", fmt.Errorf("module %s unit %s: %w", moduleID, unit, err))
				fail(unit)
			}
		}

		allow := unitAllow[unit]
		if err := funcs.capability(unit, allow); err != nil {
			if security.IsFullCapabilitySet(allow) {
				onError("capability_dropin_exempt",
					fmt.Errorf("module %s unit %s: %w — resolved set is the full known-capability ceiling, not failing closed", moduleID, unit, err))
			} else {
				onError("capability_dropin", fmt.Errorf("module %s unit %s: %w", moduleID, unit, err))
				fail(unit)
			}
		}
	}

	return failedUnits
}
