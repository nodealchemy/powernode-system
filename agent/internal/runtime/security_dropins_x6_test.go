package runtime

import (
	"errors"
	"strings"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/lifecycle"
	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/security"
)

// TestApplyModuleSecurityDropIns_LegacyAmbientRemovalFailureDoesNotFailClosedOrDiscardChanged
// is X6's own regression test at the orchestrator level (IMP-caef5c00d63f
// round X, HIGH, B1): a removeLegacyAmbientCapability failure (e.g. the
// legacy path exists as a non-empty directory rather than a regular file)
// must be reported non-fatally and must NOT discard the primary capability
// write's own changed=true — the pre-X6 shape merged the two into one
// error, which fail-closed the unit and left it running its OLD, WIDER
// capabilities forever, specifically because the refusal blocked the
// restart that would have applied the already-on-disk narrower write.
func TestApplyModuleSecurityDropIns_LegacyAmbientRemovalFailureDoesNotFailClosedOrDiscardChanged(t *testing.T) {
	mf := &manifest.Manifest{
		ID:       "m1",
		Services: []manifest.Service{{Name: "app", StartCommand: "/bin/true"}},
	}
	unit := lifecycle.UnitName("m1", "app")
	unitAllow := map[string][]string{unit: {"CAP_CHOWN"}}
	policy := &security.Policy{Capabilities: []string{"CAP_CHOWN"}}

	funcs := securityDropInFuncs{
		userNamespace:    func(string, bool) (bool, error) { return false, nil },
		seccomp:          func(string, string) (bool, error) { return false, nil },
		capability:       func(string, []string) (bool, error) { return true, nil }, // primary write succeeds and CHANGED
		removeSeccomp:    func(string) (bool, error) { return false, nil },
		removeCapability: func(string) (bool, error) { return false, nil },
		removeLegacyAmbientCapability: func(string) (bool, error) {
			return false, errors.New("remove ambient-capabilities.conf: is a directory")
		},
	}
	var onErrors []string
	changed, failed := applyModuleSecurityDropIns("m1", mf, policy, unitAllow, nil, funcs,
		func(stage string, err error) { onErrors = append(onErrors, stage+": "+err.Error()) })

	if len(failed) != 0 {
		t.Errorf("X6 REGRESSION: a legacy-ambient-removal failure must NEVER fail the unit closed, got failedUnits=%v", failed)
	}
	if !containsStr(changed, unit) {
		t.Errorf("X6 REGRESSION: the primary capability write's own changed=true must survive a legacy-removal failure, got changedUnits=%v", changed)
	}
	found := false
	for _, e := range onErrors {
		if strings.Contains(e, "legacy_ambient_capability_dropin_remove") {
			found = true
		}
	}
	if !found {
		t.Errorf("expected the legacy-removal failure to still be reported (non-fatally), got onErrors=%v", onErrors)
	}
}

func containsStr(list []string, s string) bool {
	for _, v := range list {
		if v == s {
			return true
		}
	}
	return false
}
