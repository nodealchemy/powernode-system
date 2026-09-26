package runtime

import (
	"context"
	"errors"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/security"
	"github.com/nodealchemy/powernode-system/agent/internal/verify"
)

// K6 (review round 6): mutant-driven tests for the version-bump deferral
// path — each of the three err/failure causes filterUnsafeVersionBumpDetaches
// treats identically (defer, don't detach), and the diagnostics that must
// fire alongside the deferral.

func deferralTestReconciler(t *testing.T) *Reconciler {
	t.Helper()
	layout := mount.DefaultLayout()
	layout.Root = t.TempDir()
	layout = layout.Resolve()
	return &Reconciler{cfg: ReconcilerConfig{
		Puller:      &stubPuller{cacheDir: layout.ModulesCacheRoot},
		Verifier:    verify.AlwaysOK{},
		MountRunner: &mount.RecorderRunner{},
		Layout:      layout,
		OnError:     func(string, error) {},
	}}
}

func TestApplyVersionBumpDeferrals_UnapprovedPrivilegedDefersDetach(t *testing.T) {
	r := deferralTestReconciler(t)
	var stages []string
	r.cfg.OnError = func(stage string, err error) { stages = append(stages, stage) }

	oldMod := mount.Module{ID: "m1", Digest: "abc123", Priority: 1}
	newMod := mount.Module{ID: "m1", Digest: "def456", Priority: 1}
	newMf := &manifest.Manifest{
		ID:       "m1",
		Digest:   "def456",
		Config:   map[string]any{"security": map[string]any{"privileged": true}},
		Services: []manifest.Service{{Name: "app", StartCommand: "/bin/true"}},
	}
	manifests := map[string]*manifest.Manifest{"m1": newMf}
	artifactReady := map[string]bool{"m1": true}

	safe, deferredIDs := r.applyVersionBumpDeferrals(mount.ModuleStack{oldMod}, mount.ModuleStack{newMod}, manifests, artifactReady)

	if len(safe) != 0 {
		t.Errorf("K6 REGRESSION: an unapproved privileged request on the new manifest must defer the detach, got safe=%v", safe)
	}
	if len(deferredIDs) != 1 || deferredIDs[0] != "m1" {
		t.Errorf("expected deferredIDs=[m1], got %v", deferredIDs)
	}
	if !containsArg(stages, "reconciler:version_bump_detach_deferred_would_fail_closed") {
		t.Errorf("K6: expected the deferral diagnostic to fire, got stages: %v", stages)
	}
	if !containsArg(stages, "reconciler:version_bump_deferred") {
		t.Errorf("K6: expected the per-module noteUnconverged diagnostic to fire, got stages: %v", stages)
	}
	if len(r.SecurityFailClosedUnits()) != 0 {
		t.Errorf("a privileged-unapproved deferral names no specific failing units — it must NOT touch SecurityFailClosedUnits(), got %v", r.SecurityFailClosedUnits())
	}
}

func TestApplyVersionBumpDeferrals_InvalidPolicyDefersDetach(t *testing.T) {
	r := deferralTestReconciler(t)
	var stages []string
	r.cfg.OnError = func(stage string, err error) { stages = append(stages, stage) }

	oldMod := mount.Module{ID: "m1", Digest: "abc123", Priority: 1}
	newMod := mount.Module{ID: "m1", Digest: "def456", Priority: 1}
	// A control character in seccomp_profile — Validate still flags this
	// (K5b only relaxed the CAPABILITY-name check; seccomp/SELinux/AppArmor
	// profile-name validation is unrelated and stays exactly as strict).
	newMf := &manifest.Manifest{
		ID:       "m1",
		Digest:   "def456",
		Config:   map[string]any{"security": map[string]any{"seccomp_profile": "bad\x01profile"}},
		Services: []manifest.Service{{Name: "app", StartCommand: "/bin/true"}},
	}
	manifests := map[string]*manifest.Manifest{"m1": newMf}
	artifactReady := map[string]bool{"m1": true}

	safe, deferredIDs := r.applyVersionBumpDeferrals(mount.ModuleStack{oldMod}, mount.ModuleStack{newMod}, manifests, artifactReady)

	if len(safe) != 0 {
		t.Errorf("K6 REGRESSION: an invalid policy (a malformed seccomp_profile name) on the new manifest must defer the detach, got safe=%v", safe)
	}
	if len(deferredIDs) != 1 || deferredIDs[0] != "m1" {
		t.Errorf("expected deferredIDs=[m1], got %v", deferredIDs)
	}
	if !containsArg(stages, "reconciler:version_bump_detach_deferred_would_fail_closed") {
		t.Errorf("K6: expected the deferral diagnostic to fire, got stages: %v", stages)
	}
}

// K6: attachModule's typed error names the right module — the ONE field a
// caller (AttachOne's CLI, or a test) actually reads to know WHICH module
// refused, when several might be in flight.
func TestSecurityFailClosedError_NamesTheCorrectModuleID(t *testing.T) {
	dropIns := t.TempDir()
	t.Cleanup(security.SetSystemdDropInRootForTest(dropIns))
	r := liveReconciler(t, &mount.RecorderRunner{})

	mf := &manifest.Manifest{
		ID:     "very-specific-module-id",
		Digest: "d1",
		Config: map[string]any{"security": map[string]any{"privileged": true}},
	}
	err := r.attachModule(context.Background(), mount.Module{ID: mf.ID, Digest: "d1", Priority: 1}, mf)
	var secErr *SecurityFailClosedError
	if !errors.As(err, &secErr) {
		t.Fatalf("expected a *SecurityFailClosedError, got %T: %v", err, err)
	}
	if secErr.ModuleID != "very-specific-module-id" {
		t.Errorf("K6 REGRESSION: SecurityFailClosedError.ModuleID = %q, want %q", secErr.ModuleID, "very-specific-module-id")
	}
}
