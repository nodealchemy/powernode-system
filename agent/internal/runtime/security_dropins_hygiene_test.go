package runtime

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/lifecycle"
	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/security"
)

// liveSecurityDropInFuncs mirrors reconcile.go's own applyModuleSecurityPolicy
// wiring — the real security package writers, targeting the process's own
// systemdDropInRoot (SetSystemdDropInRootForTest points that at a tempdir).
func liveSecurityDropInFuncs() securityDropInFuncs {
	return securityDropInFuncs{
		userNamespace:    security.WriteUserNamespaceDropIn,
		seccomp:          security.WriteSeccompDropIn,
		capability:       security.WriteCapabilityDropIn,
		removeSeccomp:    security.RemoveSeccompDropIn,
		removeCapability: security.RemoveCapabilityDropIn,
	}
}

// TestApplyModuleSecurityDropIns_RemovesStaleSeccompWhenProfileDropped is R7
// (review round 14, hygiene): a manifest edit that stops declaring
// seccomp_profile previously left the OLD profile's seccomp.conf on disk
// forever — the writer only ever ran when policy.SeccompProfile != "", and
// nothing removed it when that became false again. The next attach must
// actually take the edit into effect, not just stop writing a NEW file
// while the OLD one stays loaded and enforced.
func TestApplyModuleSecurityDropIns_RemovesStaleSeccompWhenProfileDropped(t *testing.T) {
	dropIns := t.TempDir()
	t.Cleanup(security.SetSystemdDropInRootForTest(dropIns))

	mf := &manifest.Manifest{
		ID:       "m1",
		Services: []manifest.Service{{Name: "app", StartCommand: "/bin/true"}},
	}
	unit := lifecycle.UnitName("m1", "app")
	unitAllow := map[string][]string{unit: {"CAP_CHOWN"}}
	seccompPath := filepath.Join(dropIns, unit+".d", "seccomp.conf")

	// First attach: seccomp_profile declared.
	withProfile := &security.Policy{Capabilities: []string{"CAP_CHOWN"}, SeccompProfile: "system-service"}
	if failed := applyModuleSecurityDropIns("m1", mf, withProfile, unitAllow, nil, liveSecurityDropInFuncs(), func(string, error) {}); len(failed) != 0 {
		t.Fatalf("precondition: first attach must not fail, got %v", failed)
	}
	if _, err := os.Stat(seccompPath); err != nil {
		t.Fatalf("precondition: expected %s after the first attach: %v", seccompPath, err)
	}

	// Second attach: the manifest edit drops seccomp_profile entirely.
	withoutProfile := &security.Policy{Capabilities: []string{"CAP_CHOWN"}}
	if failed := applyModuleSecurityDropIns("m1", mf, withoutProfile, unitAllow, nil, liveSecurityDropInFuncs(), func(string, error) {}); len(failed) != 0 {
		t.Fatalf("second attach must not fail, got %v", failed)
	}
	if _, err := os.Stat(seccompPath); !os.IsNotExist(err) {
		t.Errorf("R7 REGRESSION: expected the stale %s to be removed once the manifest stops declaring a profile, stat err=%v", seccompPath, err)
	}
}

// TestApplyModuleSecurityDropIns_RemovesStaleCapabilityAndSeccompWhenPrivileged
// is R7's second case: a unit becoming privileged opts out of the
// capability/seccomp WRITES entirely — before this fix, a stale
// capabilities.conf/seccomp.conf from a PRIOR non-privileged state was never
// removed either, silently narrowing a "privileged" unit below what its
// manifest now grants, forever (nothing ever re-writes or removes either
// file once that branch is taken).
func TestApplyModuleSecurityDropIns_RemovesStaleCapabilityAndSeccompWhenPrivileged(t *testing.T) {
	dropIns := t.TempDir()
	t.Cleanup(security.SetSystemdDropInRootForTest(dropIns))

	mf := &manifest.Manifest{
		ID:       "m1",
		Services: []manifest.Service{{Name: "app", StartCommand: "/bin/true"}},
	}
	unit := lifecycle.UnitName("m1", "app")
	unitAllow := map[string][]string{unit: {"CAP_CHOWN"}}
	capPath := filepath.Join(dropIns, unit+".d", "capabilities.conf")
	seccompPath := filepath.Join(dropIns, unit+".d", "seccomp.conf")

	// First attach: non-privileged, narrow capabilities + a seccomp profile.
	nonPrivileged := &security.Policy{Capabilities: []string{"CAP_CHOWN"}, SeccompProfile: "system-service"}
	if failed := applyModuleSecurityDropIns("m1", mf, nonPrivileged, unitAllow, nil, liveSecurityDropInFuncs(), func(string, error) {}); len(failed) != 0 {
		t.Fatalf("precondition: first attach must not fail, got %v", failed)
	}
	if _, err := os.Stat(capPath); err != nil {
		t.Fatalf("precondition: expected %s after the first attach: %v", capPath, err)
	}
	if _, err := os.Stat(seccompPath); err != nil {
		t.Fatalf("precondition: expected %s after the first attach: %v", seccompPath, err)
	}

	// Second attach: the module is now operator-approved privileged.
	privileged := &security.Policy{Privileged: true}
	if failed := applyModuleSecurityDropIns("m1", mf, privileged, unitAllow, nil, liveSecurityDropInFuncs(), func(string, error) {}); len(failed) != 0 {
		t.Fatalf("second attach must not fail, got %v", failed)
	}
	if _, err := os.Stat(capPath); !os.IsNotExist(err) {
		t.Errorf("R7 REGRESSION: expected the stale %s to be removed once the unit becomes privileged, stat err=%v", capPath, err)
	}
	if _, err := os.Stat(seccompPath); !os.IsNotExist(err) {
		t.Errorf("R7 REGRESSION: expected the stale %s to be removed once the unit becomes privileged, stat err=%v", seccompPath, err)
	}
}
