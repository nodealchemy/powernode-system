package runtime

import (
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/lifecycle"
	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/security"
)

// TestApplyModuleSecurityDropIns_UserNamespaceOnlyChangeIsReportedAsChanged
// is X8 (IMP-caef5c00d63f round X — kills mutant M11, which survived the
// round-W review: markChanged(unit, changed) in the userNamespace branch
// silently replaced with a no-op still passed every existing test). Isolates
// the userns signal by holding capabilities and seccomp identical across
// both attaches — only PrivateUsers= flips.
func TestApplyModuleSecurityDropIns_UserNamespaceOnlyChangeIsReportedAsChanged(t *testing.T) {
	dropIns := t.TempDir()
	t.Cleanup(security.SetSystemdDropInRootForTest(dropIns))

	mf := &manifest.Manifest{
		ID:       "m1",
		Services: []manifest.Service{{Name: "app", StartCommand: "/bin/true"}},
	}
	unit := lifecycle.UnitName("m1", "app")
	unitAllow := map[string][]string{unit: {"CAP_CHOWN"}}

	first := &security.Policy{Capabilities: []string{"CAP_CHOWN"}, UserNamespace: true}
	if _, failed := applyModuleSecurityDropIns("m1", mf, first, unitAllow, nil, liveSecurityDropInFuncs(), func(string, error) {}); len(failed) != 0 {
		t.Fatalf("precondition: first attach must not fail, got %v", failed)
	}

	second := &security.Policy{Capabilities: []string{"CAP_CHOWN"}, UserNamespace: false}
	changed, failed := applyModuleSecurityDropIns("m1", mf, second, unitAllow, nil, liveSecurityDropInFuncs(), func(string, error) {})
	if len(failed) != 0 {
		t.Fatalf("second attach must not fail, got %v", failed)
	}
	if !containsStr(changed, unit) {
		t.Errorf("M11 REGRESSION: a user-namespace-only change (capabilities and seccomp unchanged) must report %s in changedUnits, got %v", unit, changed)
	}
}

// TestApplyModuleSecurityDropIns_RemoveSeccompOnlyChangeIsReportedAsChanged
// is X8's sibling, killing mutant M12: the "no profile declared" cleanup
// branch's own markChanged(unit, changed) call, exercised on a NON-privileged
// unit (TestApplyModuleSecurityDropIns_RemovesStaleSeccompWhenProfileDropped
// already covers the FILE removal but discards changedUnits with `_`, so it
// could not have caught this). Isolates the signal by holding capabilities
// and user-namespace identical across both attaches — only the seccomp
// profile is dropped.
func TestApplyModuleSecurityDropIns_RemoveSeccompOnlyChangeIsReportedAsChanged(t *testing.T) {
	dropIns := t.TempDir()
	t.Cleanup(security.SetSystemdDropInRootForTest(dropIns))

	mf := &manifest.Manifest{
		ID:       "m1",
		Services: []manifest.Service{{Name: "app", StartCommand: "/bin/true"}},
	}
	unit := lifecycle.UnitName("m1", "app")
	unitAllow := map[string][]string{unit: {"CAP_CHOWN"}}

	withProfile := &security.Policy{Capabilities: []string{"CAP_CHOWN"}, SeccompProfile: "system-service"}
	if _, failed := applyModuleSecurityDropIns("m1", mf, withProfile, unitAllow, nil, liveSecurityDropInFuncs(), func(string, error) {}); len(failed) != 0 {
		t.Fatalf("precondition: first attach must not fail, got %v", failed)
	}

	withoutProfile := &security.Policy{Capabilities: []string{"CAP_CHOWN"}}
	changed, failed := applyModuleSecurityDropIns("m1", mf, withoutProfile, unitAllow, nil, liveSecurityDropInFuncs(), func(string, error) {})
	if len(failed) != 0 {
		t.Fatalf("second attach must not fail, got %v", failed)
	}
	if !containsStr(changed, unit) {
		t.Errorf("M12 REGRESSION: dropping the seccomp profile (capabilities and user-namespace unchanged) must report %s in changedUnits, got %v", unit, changed)
	}
}
