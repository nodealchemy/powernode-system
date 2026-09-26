package runtime

import (
	"context"
	"errors"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/security"
)

// Round 9, point 7: renderPivotUnits (compose.go, the pivot boot-compose
// path) used to carry its OWN inline copy of the policy decision
// (buildPolicy, DropUnknownCapabilities, the privileged-approval gate,
// Validate, per-service capability resolution) — a second implementation
// that could silently drift from applyModuleSecurityPolicy's (reconcile.go,
// the live cloud-init reconcile path). Both now call the SAME
// decideModuleSecurityPolicy. These tests prove the two production call
// sites still AGREE on the same manifest, for the two refusal classes that
// were genuinely duplicated logic (capabilities-outside-ceiling and
// unapproved-privileged) — not just that each individually still works,
// which the pre-existing per-path tests already covered.

// ceilingViolationManifest declares a service asking for a capability
// outside the module's own ceiling — ResolveServiceCapabilities' "outside
// the ceiling" error, the one case decideModuleSecurityPolicy's capability
// resolution can itself refuse the whole module over
// (PolicyDecisionCapabilitiesInvalid).
func ceilingViolationManifest(id string) *manifest.Manifest {
	return &manifest.Manifest{
		ID:                          id,
		Name:                        id,
		ServiceCapabilitiesPresence: true,
		Config:                      map[string]any{"security": map[string]any{"capabilities": []any{"CAP_CHOWN"}}},
		Services: []manifest.Service{
			{
				Name:         "app",
				StartCommand: "/bin/true",
				Capabilities: manifest.ServiceCapabilities{Declared: true, Names: []string{"CAP_CHOWN", "CAP_SYS_ADMIN"}},
			},
		},
	}
}

// TestSecurityPolicyDecision_LiveAndPivotAgreeOnCapabilitiesCeilingViolation
// feeds the SAME manifest — a service declaring a capability outside the
// module's ceiling — to both applyModuleSecurityPolicy (live) and
// renderPivotUnits (pivot) and asserts both refuse the module rather than
// letting the unit start unconfined. A regression that reintroduced pivot's
// own inline (and potentially looser) copy of this check would surface here
// even if pivot's own per-path tests still passed.
func TestSecurityPolicyDecision_LiveAndPivotAgreeOnCapabilitiesCeilingViolation(t *testing.T) {
	mod := mount.Module{ID: "m1", Priority: 100}
	mf := ceilingViolationManifest("m1")

	// LIVE: applyModuleSecurityPolicy must refuse before ever reaching a
	// drop-in write (a non-nil error, not merely an empty failedUnits list).
	t.Cleanup(security.SetSystemdDropInRootForTest(t.TempDir()))
	t.Setenv("POWERNODE_LIFECYCLE_UNIT_DIR", t.TempDir())
	liveR := &Reconciler{cfg: ReconcilerConfig{MountRunner: &mount.RecorderRunner{}, OnError: func(string, error) {}}}
	if _, err := liveR.applyModuleSecurityPolicy(context.Background(), mod, mf); err == nil {
		t.Fatal("live path: expected applyModuleSecurityPolicy to refuse a per-service capability outside the module ceiling")
	} else {
		var pde *PolicyDecisionError
		if !errors.As(err, &pde) || pde.Reason != PolicyDecisionCapabilitiesInvalid {
			t.Errorf("live path: expected a PolicyDecisionCapabilitiesInvalid reason, got %v", err)
		}
	}

	// PIVOT: renderPivotUnits must never enable the unit.
	sysroot := t.TempDir()
	pivotRunner := &mount.RecorderRunner{}
	pivotR := newPivotReconciler(pivotRunner)
	pivotR.renderPivotUnits(context.Background(), sysroot, mount.ModuleStack{mod}, map[string]*manifest.Manifest{"m1": mf}, nil)
	if unitEnabled(t, sysroot, pivotRunner, "m1") {
		t.Error("pivot path REGRESSION: a service capability outside the module ceiling must not be enabled post-pivot")
	}
}

// TestSecurityPolicyDecision_LiveAndPivotAgreeOnUnapprovedPrivileged is the
// same parity proof for the OTHER refusal class the two paths used to
// duplicate: security.privileged=true with no operator grant. Pivot's own
// enforcePrivileged is exercised via a frozen breadcrumb allowlist that does
// NOT include the module (compose_privileged_gate_test.go's own fixture
// shape); the live side has no such conditional (always enforced).
func TestSecurityPolicyDecision_LiveAndPivotAgreeOnUnapprovedPrivileged(t *testing.T) {
	mod, mf := privModule("priv-unapproved-parity")

	t.Cleanup(security.SetSystemdDropInRootForTest(t.TempDir()))
	t.Setenv("POWERNODE_LIFECYCLE_UNIT_DIR", t.TempDir())
	liveR := &Reconciler{cfg: ReconcilerConfig{MountRunner: &mount.RecorderRunner{}, OnError: func(string, error) {}}}
	// privilegedAllow left nil — no operator grant, matching pivot's frozen
	// allowlist below (neither names the module).
	if _, err := liveR.applyModuleSecurityPolicy(context.Background(), mod, mf); err == nil {
		t.Fatal("live path: expected applyModuleSecurityPolicy to refuse an unapproved privileged request")
	} else {
		var pde *PolicyDecisionError
		if !errors.As(err, &pde) || pde.Reason != PolicyDecisionPrivilegedUnapproved {
			t.Errorf("live path: expected a PolicyDecisionPrivilegedUnapproved reason, got %v", err)
		}
	}

	sysroot := t.TempDir()
	pivotRunner := &mount.RecorderRunner{}
	pivotR := newPivotReconciler(pivotRunner)
	bc := &BootComposedBreadcrumb{PrivilegedAllowlistFrozen: true, PrivilegedModuleIDs: nil}
	pivotR.renderPivotUnits(context.Background(), sysroot, mount.ModuleStack{mod}, map[string]*manifest.Manifest{mod.ID: mf}, bc)
	if unitEnabled(t, sysroot, pivotRunner, mod.ID) {
		t.Error("pivot path REGRESSION: an unapproved privileged module must not be enabled post-pivot")
	}
}
