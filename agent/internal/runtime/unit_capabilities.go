package runtime

import (
	"errors"
	"fmt"

	"github.com/nodealchemy/powernode-system/agent/internal/lifecycle"
	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/security"
)

// resolveUnitCapabilities is the ONE per-service capability resolver
// (IMP-caef5c00d63f). Both attach paths — attachModule on the cloud-init
// reconcile and ComposeForPivot on the pivot path — and the re-attach stamp
// resolve through it, so a running node and a composed node cannot disagree
// about which capabilities a unit holds. The rule itself lives in
// security.ResolveServiceCapabilities: the module's security.capabilities is a
// ceiling, an absent service key inherits it, a declared key (including [])
// is that unit's exact set and must fit under the ceiling.
//
// MIXED-VERSION RULE (review finding F1). A declared [] is honoured as ZERO
// only when the payload carries the server's presence marker
// (mf.ServiceCapabilitiesPresence). A server that predates stage 1
// (IMP-074fcd68284f), or a module not yet republished under it (stage 1 ships
// no backfill), sends [] for EVERY service — an absent key and a deliberate
// zero are indistinguishable there, and reading [] as zero would strip
// rails-setup, the root hub-worker units and vault of the ceiling they run on
// today. So without the marker ("legacy"), [] inherits the ceiling exactly as
// an absent key does. This is the one place emptiness decides anything, and
// only because the marker says the payload's [] carries no intent. A
// non-empty declared list is honoured as a subset in both modes. Legacy is
// therefore never wider than today's module-wide behaviour: each unit gets
// the ceiling or a subset of it.
//
// Returns one entry per service, in declaration order, ALWAYS — including on
// error, where a service that failed to resolve carries its raw declared list
// (or the raw ceiling when it declared none). The attach callers refuse the
// module on a non-nil error and never write those entries; the stamp still
// needs them so a fix to the offending manifest moves it.
func resolveUnitCapabilities(mf *manifest.Manifest, policy *security.Policy, moduleID string) ([]security.UnitCapabilities, error) {
	out := make([]security.UnitCapabilities, 0, len(mf.Services))
	var errs []error
	for _, svc := range mf.Services {
		unit := lifecycle.UnitName(moduleID, svc.Name)
		declared := svc.Capabilities.Declared
		if declared && len(svc.Capabilities.Names) == 0 && !mf.ServiceCapabilitiesPresence {
			declared = false // legacy payload: its [] carries no intent
		}
		allow, err := security.ResolveServiceCapabilities(policy.Capabilities, declared, svc.Capabilities.Names)
		if err != nil {
			errs = append(errs, fmt.Errorf("service %s: %w", svc.Name, err))
			allow = policy.Capabilities
			if declared {
				allow = svc.Capabilities.Names
			}
		}
		out = append(out, security.UnitCapabilities{Unit: unit, Allow: allow})
	}
	return out, errors.Join(errs...)
}

// attachCapabilityWrites is the reconcile path's view: units are named from
// the manifest's own id, exactly as mf.UnitNames() names them.
func attachCapabilityWrites(mf *manifest.Manifest, policy *security.Policy) ([]security.UnitCapabilities, error) {
	return resolveUnitCapabilities(mf, policy, mf.ID)
}

// composeCapabilityWrites is the pivot-compose path's view: units are named
// from the stack entry's module id, as ComposeForPivot names them.
func composeCapabilityWrites(moduleID string, mf *manifest.Manifest, policy *security.Policy) ([]security.UnitCapabilities, error) {
	return resolveUnitCapabilities(mf, policy, moduleID)
}
