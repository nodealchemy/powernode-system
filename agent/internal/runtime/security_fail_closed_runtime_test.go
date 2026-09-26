package runtime

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/lifecycle"
	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/security"
	"github.com/nodealchemy/powernode-system/agent/internal/verify"
)

// IMP-caef5c00d63f phase 4 — F1 (HIGH, round-3 review): attachModule (the
// LIVE cloud-init/pivot-reconcile path) wrote the same drop-ins renderPivotUnits
// does but treated a write failure as NON-FATAL, then the caller went on to
// call attachModuleServices, which WRITES the unit and STARTS it — unconfined,
// because the drop-in never landed. Operator decision (round 3): fail closed
// identically on BOTH paths. See security_dropins.go's applyModuleSecurityDropIns
// (the ONE decision both paths now share) and reconcile.go's attachModule.

func liveReconciler(t *testing.T, rec *mount.RecorderRunner) *Reconciler {
	t.Helper()
	layout := mount.DefaultLayout()
	layout.Root = t.TempDir()
	layout = layout.Resolve()
	return &Reconciler{cfg: ReconcilerConfig{
		Puller:      &stubPuller{cacheDir: layout.ModulesCacheRoot},
		Verifier:    verify.AlwaysOK{},
		MountRunner: rec,
		Layout:      layout,
		OnError:     func(string, error) {},
	}}
}

// RED-FIRST: this fixture (rails Requires= rails-setup via start_before) is
// the SAME one that proves the pivot-path redesign; used here because the
// live path's caller (RunOnce) skips attachModuleServices on ANY attachModule
// error — the exact same refusal shape "invalid policy" and "privileged
// unapproved" already use — so a Requires= edge is not the live path's own
// risk the way it was compose.go's. What WAS the live path's risk, before
// this fix: attachModule returned nil on a drop-in write failure, so the
// caller proceeded to attachModuleServices and started the unit unconfined.
func TestAttachModule_RefusesWholeModuleWhenAUnitsSecurityDropInFailsToWrite(t *testing.T) {
	dropIns := t.TempDir()
	t.Cleanup(security.SetSystemdDropInRootForTest(dropIns))

	rec := &mount.RecorderRunner{}
	r := liveReconciler(t, rec)

	mf := hubBackendLikeWithStartBefore(t)
	failingUnit := lifecycle.UnitName(mf.ID, "rails-setup")
	dropInDir := filepath.Join(dropIns, failingUnit+".d")
	if err := os.MkdirAll(filepath.Dir(dropInDir), 0o755); err != nil {
		t.Fatal(err)
	}
	// The .d path exists as a FILE, not a directory — forces MkdirAll to fail,
	// exactly like the pivot-path test.
	if err := os.WriteFile(dropInDir, []byte("not a directory"), 0o644); err != nil {
		t.Fatal(err)
	}

	var onErrors []string
	r.cfg.OnError = func(stage string, err error) { onErrors = append(onErrors, stage) }

	err := r.attachModule(context.Background(), mount.Module{ID: mf.ID, Digest: "d1", Priority: 1}, mf)
	if err == nil {
		t.Fatal("attachModule must return an error when a non-exempt security drop-in fails to write (fail closed)")
	}

	if !containsArg(onErrors, "reconciler:capability_dropin") {
		t.Errorf("expected an OnError(\"reconciler:capability_dropin\", ...) report, got stages: %v", onErrors)
	}
	if !containsArg(onErrors, "reconciler:security_dropin_fail_closed") {
		t.Errorf("expected the module-level fail-closed refusal signal, got stages: %v", onErrors)
	}

	got := r.SecurityFailClosedUnits()
	if !containsArg(got, failingUnit) {
		t.Errorf("Reconciler.SecurityFailClosedUnits() must name %s, got %v", failingUnit, got)
	}
}

// The failed units must be STOPPED if currently running, not merely left
// un-restarted — a re-attach whose manifest NARROWED the ceiling this pass,
// and whose drop-in write then failed, must not leave the OLDER (wider)
// drop-in's unit running just because the refresh could not land.
func TestAttachModule_StopsARunningUnitWhenItFailsClosed(t *testing.T) {
	dropIns := t.TempDir()
	t.Cleanup(security.SetSystemdDropInRootForTest(dropIns))

	mf := hubBackendLike(t)
	failingUnit := lifecycle.UnitName(mf.ID, "rails-setup")
	dropInDir := filepath.Join(dropIns, failingUnit+".d")
	if err := os.MkdirAll(filepath.Dir(dropInDir), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(dropInDir, []byte("not a directory"), 0o644); err != nil {
		t.Fatal(err)
	}

	rec := &mount.RecorderRunner{
		StubOutput: map[string][]byte{
			"systemctl is-active " + failingUnit: []byte("active\n"),
		},
	}
	r := liveReconciler(t, rec)

	if err := r.attachModule(context.Background(), mount.Module{ID: mf.ID, Digest: "d1", Priority: 1}, mf); err == nil {
		t.Fatal("test setup problem: attachModule must fail closed for this to be meaningful")
	}

	sawStop := false
	for _, inv := range rec.Invocations {
		if inv.Name == "systemctl" && containsArg(inv.Args, "stop") && containsArg(inv.Args, failingUnit) {
			sawStop = true
		}
	}
	if !sawStop {
		t.Errorf("expected `systemctl stop %s` after a fail-closed refusal of an ACTIVE unit, got invocations: %v", failingUnit, rec.Invocations)
	}
}

// A unit that is NOT running when it fails closed must not get a spurious
// stop call — IsActive reads it as inactive (RecorderRunner's zero-value
// Output is empty, which systemd.IsActive treats as not-active) and nothing
// else should be issued for it.
func TestAttachModule_DoesNotStopAnAlreadyInactiveUnit(t *testing.T) {
	dropIns := t.TempDir()
	t.Cleanup(security.SetSystemdDropInRootForTest(dropIns))

	mf := hubBackendLike(t)
	failingUnit := lifecycle.UnitName(mf.ID, "rails-setup")
	dropInDir := filepath.Join(dropIns, failingUnit+".d")
	if err := os.MkdirAll(filepath.Dir(dropInDir), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(dropInDir, []byte("not a directory"), 0o644); err != nil {
		t.Fatal(err)
	}

	rec := &mount.RecorderRunner{}
	r := liveReconciler(t, rec)

	if err := r.attachModule(context.Background(), mount.Module{ID: mf.ID, Digest: "d1", Priority: 1}, mf); err == nil {
		t.Fatal("test setup problem: attachModule must fail closed for this to be meaningful")
	}

	for _, inv := range rec.Invocations {
		if inv.Name == "systemctl" && containsArg(inv.Args, "stop") {
			t.Errorf("unexpected systemctl stop for a unit IsActive reported as inactive: %v", inv)
		}
	}
}

// F1 parity, mirroring TestRenderPivotUnits_FullCapabilitySetExemptFromFailClosed
// on the live path — a unit resolved to the full known-capability ceiling
// must not fail closed here either.
func TestAttachModule_FullCapabilitySetExemptFromFailClosed(t *testing.T) {
	dropIns := t.TempDir()
	t.Cleanup(security.SetSystemdDropInRootForTest(dropIns))

	full := make([]any, 0, len(security.KnownCapabilities))
	for c := range security.KnownCapabilities {
		full = append(full, c)
	}
	mf := &manifest.Manifest{
		ID:                          "full-cap-mod",
		Name:                        "full-cap-mod",
		ServiceCapabilitiesPresence: true,
		Config:                      map[string]any{"security": map[string]any{"capabilities": full, "user_namespace": false}},
		Services:                    []manifest.Service{{Name: "app", StartCommand: "/bin/true"}},
	}
	unit := lifecycle.UnitName(mf.ID, "app")
	dropInDir := filepath.Join(dropIns, unit+".d")
	if err := os.MkdirAll(filepath.Dir(dropInDir), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(dropInDir, []byte("not a directory"), 0o644); err != nil {
		t.Fatal(err)
	}

	rec := &mount.RecorderRunner{}
	r := liveReconciler(t, rec)

	var onErrors []string
	r.cfg.OnError = func(stage string, err error) { onErrors = append(onErrors, stage) }

	if err := r.attachModule(context.Background(), mount.Module{ID: mf.ID, Digest: "d1", Priority: 1}, mf); err != nil {
		t.Errorf("a full-known-capability-set write failure must NOT fail closed attachModule, got: %v", err)
	}
	if containsArg(onErrors, "reconciler:security_dropin_fail_closed") {
		t.Errorf("must not fail closed, got stages: %v", onErrors)
	}
	if got := r.SecurityFailClosedUnits(); len(got) != 0 {
		t.Errorf("SecurityFailClosedUnits() must stay empty, got %v", got)
	}
}

// EXPLICIT PARITY (review round 3): the SAME manifest, forced the SAME way,
// through BOTH real call sites — attachModule (live) and renderPivotUnits
// (boot/pivot-compose) — must reach the SAME refuse-or-exempt verdict. Both
// already share applyModuleSecurityDropIns, so this is a wiring guarantee
// (neither caller quietly overrides the shared decision), not a re-test of
// the decision itself.
func TestSecurityFailClosedParity_BothPathsAgree(t *testing.T) {
	full := make([]any, 0, len(security.KnownCapabilities))
	for c := range security.KnownCapabilities {
		full = append(full, c)
	}

	cases := []struct {
		name        string
		mf          func() *manifest.Manifest
		wantRefused bool
	}{
		{
			name: "narrow ceiling refuses on both paths",
			mf: func() *manifest.Manifest {
				return &manifest.Manifest{
					ID:                          "parity-narrow",
					Name:                        "parity-narrow",
					ServiceCapabilitiesPresence: true,
					Config: map[string]any{"security": map[string]any{
						"capabilities":   []any{"CAP_CHOWN"},
						"user_namespace": false,
					}},
					Services: []manifest.Service{{Name: "app", StartCommand: "/bin/true"}},
				}
			},
			wantRefused: true,
		},
		{
			name: "full ceiling is exempt on both paths",
			mf: func() *manifest.Manifest {
				return &manifest.Manifest{
					ID:                          "parity-full",
					Name:                        "parity-full",
					ServiceCapabilitiesPresence: true,
					Config:                      map[string]any{"security": map[string]any{"capabilities": full, "user_namespace": false}},
					Services:                    []manifest.Service{{Name: "app", StartCommand: "/bin/true"}},
				}
			},
			wantRefused: false,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// Live path.
			liveDropIns := t.TempDir()
			t.Cleanup(security.SetSystemdDropInRootForTest(liveDropIns))
			liveMf := tc.mf()
			unit := lifecycle.UnitName(liveMf.ID, "app")
			liveDropInDir := filepath.Join(liveDropIns, unit+".d")
			if err := os.MkdirAll(filepath.Dir(liveDropInDir), 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(liveDropInDir, []byte("not a directory"), 0o644); err != nil {
				t.Fatal(err)
			}
			liveRec := &mount.RecorderRunner{}
			liveR := liveReconciler(t, liveRec)
			liveErr := liveR.attachModule(context.Background(), mount.Module{ID: liveMf.ID, Digest: "d1", Priority: 1}, liveMf)
			liveRefused := liveErr != nil

			// Pivot path.
			sysroot := t.TempDir()
			pivotRec := &mount.RecorderRunner{}
			pivotR := newPivotReconciler(pivotRec)
			pivotMf := tc.mf()
			pivotDropInDir := filepath.Join(sysroot, "etc", "systemd", "system", unit+".d")
			if err := os.MkdirAll(filepath.Dir(pivotDropInDir), 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(pivotDropInDir, []byte("not a directory"), 0o644); err != nil {
				t.Fatal(err)
			}
			stack := mount.ModuleStack{{ID: pivotMf.ID, Priority: 1}}
			pivotR.renderPivotUnits(context.Background(), sysroot, stack, map[string]*manifest.Manifest{pivotMf.ID: pivotMf}, &BootComposedBreadcrumb{})
			pivotRefused := !unitEnabledNamed(t, sysroot, pivotRec, pivotMf.ID, "app")

			if liveRefused != tc.wantRefused {
				t.Errorf("live path: refused=%v, want %v", liveRefused, tc.wantRefused)
			}
			if pivotRefused != tc.wantRefused {
				t.Errorf("pivot path: refused=%v, want %v", pivotRefused, tc.wantRefused)
			}
			if liveRefused != pivotRefused {
				t.Errorf("PARITY VIOLATION: live refused=%v but pivot refused=%v for the same manifest/failure", liveRefused, pivotRefused)
			}
		})
	}
}

// unitEnabledNamed is unitEnabled (compose_privileged_gate_test.go) with an
// explicit service name — that helper hardcodes "app", which happens to
// match every fixture here, but naming it explicitly keeps this file's own
// intent readable without relying on a sibling file's hardcoded assumption.
func unitEnabledNamed(t *testing.T, sysroot string, rec *mount.RecorderRunner, modID, serviceName string) bool {
	t.Helper()
	unit := lifecycle.UnitName(modID, serviceName)
	_, statErr := os.Stat(filepath.Join(sysroot, "etc", "systemd", "system", unit))
	fileWritten := statErr == nil
	enableRan := false
	for _, inv := range rec.Invocations {
		if inv.Name != "systemctl" || !containsArg(inv.Args, "enable") {
			continue
		}
		if containsArg(inv.Args, unit) {
			enableRan = true
		}
	}
	if fileWritten != enableRan {
		t.Fatalf("module %s: unit file written=%v but enable ran=%v (inconsistent)", modID, fileWritten, enableRan)
	}
	return fileWritten
}
