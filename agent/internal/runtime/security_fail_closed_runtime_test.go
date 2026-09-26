package runtime

import (
	"context"
	"fmt"
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

	// G4: attachModule only accumulates into the pending set; RunOnce
	// publishes it once, after the attach/reattach loops finish. Called
	// directly here (this test calls attachModule, not the full RunOnce
	// pass) to observe what a real pass would publish.
	r.publishSecurityFailClosed(nil, nil)
	got := r.SecurityFailClosedUnits()
	if !containsArg(got, failingUnit) {
		t.Errorf("Reconciler.SecurityFailClosedUnits() must name %s, got %v", failingUnit, got)
	}
}

// TestAttachModule_UnapprovedPrivilegedRecordsSecurityFailClosed is R6
// (review round 14): applyModuleSecurityPolicy's OWN refusals — unapproved
// privileged, invalid policy, a Policy.Apply failure — never called
// recordSecurityFailClosed at all before this fix, despite K5a's own doc
// (a few lines above the fix) already stating they are "the SAME kind of
// event as a drop-in write failure". A module requesting security.privileged
// with no operator approval reached ONLY the SecurityFailClosedError return
// (attachModule's own caller sees it refused), never SecurityFailClosedUnits()
// / the heartbeat's RuntimeSecurityFailClosedUnits.
func TestAttachModule_UnapprovedPrivilegedRecordsSecurityFailClosed(t *testing.T) {
	rec := &mount.RecorderRunner{}
	r := liveReconciler(t, rec)

	mf := &manifest.Manifest{
		ID:                          "unapproved-privileged-mod",
		Name:                        "unapproved-privileged-mod",
		ServiceCapabilitiesPresence: true,
		Config:                      map[string]any{"security": map[string]any{"privileged": true}},
		Services:                    []manifest.Service{{Name: "app", StartCommand: "/bin/true"}},
	}
	unit := lifecycle.UnitName(mf.ID, "app")

	err := r.attachModule(context.Background(), mount.Module{ID: mf.ID, Digest: "d1", Priority: 1}, mf)
	if err == nil {
		t.Fatal("attachModule must refuse an unapproved privileged request")
	}

	r.publishSecurityFailClosed(nil, nil)
	got := r.SecurityFailClosedUnits()
	if !containsArg(got, unit) {
		t.Errorf("R6 REGRESSION: Reconciler.SecurityFailClosedUnits() must name %s after an unapproved-privileged refusal, got %v", unit, got)
	}
}

// TestPublishSecurityFailClosed_PersistsToStateAndNewReconcilerSeedsFromIt is
// R6's own persistence test (review round 14): publishSecurityFailClosed
// must write the published set into state.json (mount.State.
// SecurityFailClosedUnits), and NewReconciler must seed the in-memory
// atomic from it — without this, a fresh process (a real agent restart, or
// this process simply exiting and a new one starting) reports a CLEAN node
// on its very first heartbeat until the first RunOnce pass re-decides every
// module, even for a module that was refused, unconfined, right up until
// the restart.
func TestPublishSecurityFailClosed_PersistsToStateAndNewReconcilerSeedsFromIt(t *testing.T) {
	statePath := filepath.Join(t.TempDir(), "state.json")
	unit := lifecycle.UnitName("m1", "app")

	first, err := NewReconciler(ReconcilerConfig{
		ModulesClient:  &stubModulesClient{},
		ManifestClient: &stubModulesClient{},
		Puller:         &stubPuller{},
		Verifier:       verify.AlwaysOK{},
		MountRunner:    &mount.RecorderRunner{},
		StatePath:      statePath,
	})
	if err != nil {
		t.Fatal(err)
	}
	if got := first.SecurityFailClosedUnits(); len(got) != 0 {
		t.Fatalf("precondition: expected a fresh reconciler with no state.json to start clean, got %v", got)
	}

	current := &mount.State{LastAttachedManifestHashes: map[string]string{}}
	first.securityFailClosedPending = []string{unit}
	first.securityPolicyAttemptedUnits = []string{unit}
	first.publishSecurityFailClosed(current, map[string]bool{unit: true})

	st, err := mount.LoadState(statePath)
	if err != nil {
		t.Fatalf("LoadState: %v", err)
	}
	if !containsArg(st.SecurityFailClosedUnits, unit) {
		t.Fatalf("R6 REGRESSION: expected state.json's own SecurityFailClosedUnits to name %s, got %v", unit, st.SecurityFailClosedUnits)
	}

	// A SECOND, freshly-constructed reconciler — simulating a process
	// restart — pointed at the SAME state.json, with no RunOnce pass ever
	// run against it.
	second, err := NewReconciler(ReconcilerConfig{
		ModulesClient:  &stubModulesClient{},
		ManifestClient: &stubModulesClient{},
		Puller:         &stubPuller{},
		Verifier:       verify.AlwaysOK{},
		MountRunner:    &mount.RecorderRunner{},
		StatePath:      statePath,
	})
	if err != nil {
		t.Fatal(err)
	}
	if got := second.SecurityFailClosedUnits(); !containsArg(got, unit) {
		t.Errorf("R6 REGRESSION: a freshly-constructed Reconciler must seed SecurityFailClosedUnits() from state.json (not report clean before its first RunOnce pass), got %v", got)
	}
}

// REMOVED (review round 5, G1, CRITICAL — both reviewers): a fail-closed
// refusal must NOT stop an already-running unit. Two independent reasons:
//
//  1. UNRECOVERABLE ON A SELF-HOSTED NODE. ops-hub reconciles ITSELF — if the
//     failing unit is rails or postgres, stopping it here takes down the
//     control plane THIS RunOnce needs: the next tick's FetchAssignedModules
//     call goes to the now-dead rails and returns before ever reaching
//     attachModule again, so nothing on this node ever restarts the unit.
//  2. IT ENFORCED SOMETHING SUCCESS DOESN'T. attachModuleServices only
//     restarts a unit whose BODY changed this pass AND the node is not
//     self-hosted — a security drop-in write SUCCEEDING does not itself
//     restart anything. Stopping the unit specifically when the write FAILS
//     enforced a stricter guarantee than a successful write ever gives.
//
// This test pins the removal on BOTH self-hosted and non-self-hosted nodes —
// the self-host distinction mattered only to the stop logic this replaces;
// a regression that reintroduces the stop conditionally on self-hosted would
// still be wrong for reason 2 regardless of which arm it ran on.
func TestAttachModule_DoesNotStopARunningUnitOnFailedReattach(t *testing.T) {
	for _, selfHosted := range []bool{false, true} {
		t.Run(fmt.Sprintf("selfHosted=%v", selfHosted), func(t *testing.T) {
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

			// Stubbed as ACTIVE — if a stop call were (re)issued, this is the
			// shape that would trigger it.
			rec := &mount.RecorderRunner{
				StubOutput: map[string][]byte{
					"systemctl is-active " + failingUnit: []byte("active\n"),
				},
			}
			r := liveReconciler(t, rec)
			r.selfHostLatched = selfHosted

			if err := r.attachModule(context.Background(), mount.Module{ID: mf.ID, Digest: "d1", Priority: 1}, mf); err == nil {
				t.Fatal("test setup problem: attachModule must fail closed for this to be meaningful")
			}

			for _, inv := range rec.Invocations {
				if inv.Name == "systemctl" && containsArg(inv.Args, "stop") {
					t.Errorf("unexpected systemctl stop for unit %v on a fail-closed refusal: %v", failingUnit, inv)
				}
			}
		})
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
	// R5 (review round 14): the full-capability-set exemption is now
	// identity-gated — put this module on the privileged allowlist so this
	// test keeps isolating the SHAPE (full set) from that identity check.
	r.privilegedAllow = []string{mf.ID}

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

// G5 wiring: a FULLY successful attachModule must mark its units recovered —
// this is the write side of buildHeartbeat's pivot-suppression read
// (security_fail_closed_heartbeat_test.go pins the read side directly).
func TestAttachModule_SuccessRecordsUnitsAsRecovered(t *testing.T) {
	dropIns := t.TempDir()
	t.Cleanup(security.SetSystemdDropInRootForTest(dropIns))

	mf := hubBackendLike(t) // rails-setup, rails, chowner — no forced failure
	rec := &mount.RecorderRunner{}
	r := liveReconciler(t, rec)

	if err := r.attachModule(context.Background(), mount.Module{ID: mf.ID, Digest: "d1", Priority: 1}, mf); err != nil {
		t.Fatalf("attachModule: %v", err)
	}

	recovered := r.SecurityFailClosedRecovered()
	for _, name := range []string{"rails-setup", "rails", "chowner"} {
		unit := lifecycle.UnitName(mf.ID, name)
		if !recovered[unit] {
			t.Errorf("expected %s marked recovered after a successful attach, got %v", unit, recovered)
		}
	}
}

// H2 (review round 5, proven by mutation): recordSecurityFailClosedRecovered
// must NOT run on the fail-closed branch — a mutant moving that call earlier
// (unconditional, before the failedUnits check) would mark a unit that just
// FAILED as "recovered", which G5's buildHeartbeat filter would then read as
// license to suppress a boot-time pivot entry for a unit that never actually
// succeeded. Every OTHER test in this file already exercises success and
// failure separately without asserting their absence in one another, which
// is exactly why this mutant survived until now.
func TestAttachModule_FailureDoesNotRecordUnitsAsRecovered(t *testing.T) {
	dropIns := t.TempDir()
	t.Cleanup(security.SetSystemdDropInRootForTest(dropIns))

	mf := hubBackendLikeWithStartBefore(t)
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

	recovered := r.SecurityFailClosedRecovered()
	for _, name := range []string{"rails-setup", "rails", "chowner"} {
		unit := lifecycle.UnitName(mf.ID, name)
		if recovered[unit] {
			t.Errorf("H2 REGRESSION: %s must NOT be marked recovered after a fail-closed refusal, got %v", unit, recovered)
		}
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
		name string
		mf   func() *manifest.Manifest
		// blockFile is the ONE drop-in file made a pre-existing directory —
		// isolating that single write failure, not the whole <unit>.d dir
		// (review round 5, G3: a whole-dir block can't distinguish "the live
		// path ignores userns/seccomp errors" from "it fails closed
		// correctly", since the capability failure alone is enough to trip
		// refusal on a narrow ceiling either way).
		blockFile   string
		wantRefused bool
		// R5 (review round 14): the full-capability-set exemption is now
		// identity-gated (qualifiesForFullSetExemption) — a case relying on
		// it must put its own module ID on the privileged allowlist to keep
		// isolating the SHAPE (full set) from the identity check, which has
		// its own dedicated tests.
		privilegedAllow []string
	}{
		{
			name: "narrow capability ceiling refuses on both paths",
			mf: func() *manifest.Manifest {
				return &manifest.Manifest{
					ID:                          "parity-narrow",
					Name:                        "parity-narrow",
					ServiceCapabilitiesPresence: true,
					Config: map[string]any{"security": map[string]any{
						"capabilities":   []any{"CAP_CHOWN"},
						"user_namespace": false, // exempt on its own — isolates capabilities
					}},
					Services: []manifest.Service{{Name: "app", StartCommand: "/bin/true"}},
				}
			},
			blockFile:   "capabilities.conf",
			wantRefused: true,
		},
		{
			name: "full capability ceiling is exempt on both paths",
			mf: func() *manifest.Manifest {
				return &manifest.Manifest{
					ID:                          "parity-full",
					Name:                        "parity-full",
					ServiceCapabilitiesPresence: true,
					Config:                      map[string]any{"security": map[string]any{"capabilities": full, "user_namespace": false}},
					Services:                    []manifest.Service{{Name: "app", StartCommand: "/bin/true"}},
				}
			},
			blockFile:       "capabilities.conf",
			wantRefused:     false,
			privilegedAllow: []string{"parity-full"},
		},
		{
			// R5 (review round 14, SECURITY): the SAME full-capability-set
			// shape, but this module is NEITHER on the privileged allowlist
			// NOR named qga — before R5, ANY module resolving to the full
			// set got the identical free pass regardless of identity. Must
			// now fail closed like an ordinary narrow-ceiling module.
			name: "full capability ceiling without a qualifying identity refuses on both paths",
			mf: func() *manifest.Manifest {
				return &manifest.Manifest{
					ID:                          "parity-full-unqualified",
					Name:                        "parity-full-unqualified",
					ServiceCapabilitiesPresence: true,
					Config:                      map[string]any{"security": map[string]any{"capabilities": full, "user_namespace": false}},
					Services:                    []manifest.Service{{Name: "app", StartCommand: "/bin/true"}},
				}
			},
			blockFile:   "capabilities.conf",
			wantRefused: true,
		},
		{
			// R5: the SAME shape and NO privileged-allowlist entry, but
			// named exactly qgaModuleName — the pinned recovery-channel
			// identity path qualifies on its own, independent of the
			// allowlist.
			name: "full capability ceiling named qemu-guest-agent is exempt on both paths",
			mf: func() *manifest.Manifest {
				return &manifest.Manifest{
					ID:                          "parity-qga",
					Name:                        qgaModuleName,
					ServiceCapabilitiesPresence: true,
					Config:                      map[string]any{"security": map[string]any{"capabilities": full, "user_namespace": false}},
					Services:                    []manifest.Service{{Name: "app", StartCommand: "/bin/true"}},
				}
			},
			blockFile:   "capabilities.conf",
			wantRefused: false,
		},
		{
			// G3: neither path may silently ignore a userns write failure.
			// No security block at all -> policy.UserNamespace defaults to
			// TRUE (non-exempt); capabilities/seccomp are absent, so their
			// own writes succeed trivially and cannot be what trips refusal.
			name: "user_namespace:true (default) failure refuses on both paths",
			mf: func() *manifest.Manifest {
				return &manifest.Manifest{
					ID:                          "parity-userns",
					Name:                        "parity-userns",
					ServiceCapabilitiesPresence: true,
					Services:                    []manifest.Service{{Name: "app", StartCommand: "/bin/true"}},
				}
			},
			blockFile:   "userns.conf",
			wantRefused: true,
		},
		{
			// G3: neither path may silently ignore a seccomp write failure —
			// seccomp has NO exemption at all, unlike the other two branches.
			name: "seccomp failure refuses on both paths",
			mf: func() *manifest.Manifest {
				return &manifest.Manifest{
					ID:                          "parity-seccomp",
					Name:                        "parity-seccomp",
					ServiceCapabilitiesPresence: true,
					Config: map[string]any{"security": map[string]any{
						"seccomp_profile": "system-service",
						"user_namespace":  false, // exempt on its own — isolates seccomp
					}},
					Services: []manifest.Service{{Name: "app", StartCommand: "/bin/true"}},
				}
			},
			blockFile:   "seccomp.conf",
			wantRefused: true,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			// Live path.
			liveDropIns := t.TempDir()
			t.Cleanup(security.SetSystemdDropInRootForTest(liveDropIns))
			liveMf := tc.mf()
			unit := lifecycle.UnitName(liveMf.ID, "app")
			liveUnitDir := filepath.Join(liveDropIns, unit+".d")
			if err := os.MkdirAll(liveUnitDir, 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.MkdirAll(filepath.Join(liveUnitDir, tc.blockFile), 0o755); err != nil {
				t.Fatal(err)
			}
			liveRec := &mount.RecorderRunner{}
			liveR := liveReconciler(t, liveRec)
			liveR.privilegedAllow = tc.privilegedAllow
			liveErr := liveR.attachModule(context.Background(), mount.Module{ID: liveMf.ID, Digest: "d1", Priority: 1}, liveMf)
			liveRefused := liveErr != nil

			// Pivot path.
			sysroot := t.TempDir()
			pivotRec := &mount.RecorderRunner{}
			pivotR := newPivotReconciler(pivotRec)
			pivotMf := tc.mf()
			pivotUnitDir := filepath.Join(sysroot, "etc", "systemd", "system", unit+".d")
			if err := os.MkdirAll(pivotUnitDir, 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.MkdirAll(filepath.Join(pivotUnitDir, tc.blockFile), 0o755); err != nil {
				t.Fatal(err)
			}
			stack := mount.ModuleStack{{ID: pivotMf.ID, Priority: 1}}
			// R5 (review round 14): renderPivotUnits sources r.privilegedAllow
			// from the breadcrumb's own PrivilegedModuleIDs (overwriting
			// anything set directly on r), so tc.privilegedAllow must travel
			// through there, not a direct field assignment.
			pivotR.renderPivotUnits(context.Background(), sysroot, stack, map[string]*manifest.Manifest{pivotMf.ID: pivotMf}, &BootComposedBreadcrumb{PrivilegedModuleIDs: tc.privilegedAllow})
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
