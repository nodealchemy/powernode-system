package runtime

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/lifecycle"
	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/security"
	"github.com/nodealchemy/powernode-system/agent/internal/verify"
)

// capMaskFor is a small test-only convenience over security.CapabilityMask
// for building an expected declared mask from a capability name list.
func capMaskFor(t *testing.T, allow []string) uint64 {
	t.Helper()
	mask, err := security.CapabilityMask(allow)
	if err != nil {
		t.Fatalf("capMaskFor: %v", err)
	}
	return mask
}

// withProcRoot points procRoot at a fresh temp dir for the duration of the
// test, restoring the real "/proc" default on cleanup.
func withProcRoot(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	orig := procRoot
	procRoot = dir
	t.Cleanup(func() { procRoot = orig })
	return dir
}

// fakeProcPID writes a minimal /proc/<pid>/status carrying only the two
// fields probeUnitConfinement reads.
func fakeProcPID(t *testing.T, root string, pid int, capBnd, capAmb uint64) {
	t.Helper()
	dir := filepath.Join(root, strconv.Itoa(pid))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	content := fmt.Sprintf("Name:\tfake\nState:\tS (sleeping)\nCapBnd:\t%016x\nCapAmb:\t%016x\n", capBnd, capAmb)
	if err := os.WriteFile(filepath.Join(dir, "status"), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func probeTestReconciler(t *testing.T) (*Reconciler, *mount.RecorderRunner) {
	t.Helper()
	runner := &mount.RecorderRunner{}
	tmpRoot := t.TempDir()
	layout := mount.DefaultLayout()
	layout.Root = tmpRoot
	layout = layout.Resolve()
	r, err := NewReconciler(ReconcilerConfig{
		ModulesClient:  &stubModulesClient{responses: map[string]string{}},
		ManifestClient: &stubModulesClient{responses: map[string]string{}},
		ManifestRoot:   filepath.Join(tmpRoot, "manifests"),
		Puller:         &stubPuller{cacheDir: layout.ModulesCacheRoot},
		Verifier:       verify.AlwaysOK{},
		MountRunner:    runner,
		Layout:         layout,
		StatePath:      filepath.Join(tmpRoot, "state.json"),
	})
	if err != nil {
		t.Fatalf("NewReconciler: %v", err)
	}
	return r, runner
}

func showPropsKey(unit string) string {
	return "systemctl show " + unit + " --property=ActiveState,MainPID,NeedDaemonReload"
}

// TestProbeUnitConfinement_RemainAfterExitNotStale pins the oneshot/
// RemainAfterExit case (design section 1): ActiveState=active but
// MainPID=0 means nothing is currently running under any confinement at
// all — not probed, never stale.
func TestProbeUnitConfinement_RemainAfterExitNotStale(t *testing.T) {
	r, runner := probeTestReconciler(t)
	unit := lifecycle.UnitName("m1", "setup")
	runner.StubOutput = map[string][]byte{
		showPropsKey(unit): []byte("ActiveState=active\nMainPID=0\nNeedDaemonReload=no\n"),
	}
	uc := r.probeUnitConfinement(context.Background(), unit, 0xF)
	if uc.Probed {
		t.Error("expected RemainAfterExit (MainPID=0) to not be probed")
	}
	if uc.wider() {
		t.Error("expected RemainAfterExit to never read as wider")
	}
}

// TestProbeUnitConfinement_InactiveNotStale covers inactive/failed/not-found
// (a renamed unit reads exactly like this — ShowProperties itself succeeds,
// reporting ActiveState=inactive, not an error).
func TestProbeUnitConfinement_InactiveNotStale(t *testing.T) {
	r, runner := probeTestReconciler(t)
	unit := lifecycle.UnitName("m1", "gone")
	runner.StubOutput = map[string][]byte{
		showPropsKey(unit): []byte("ActiveState=inactive\nMainPID=0\nNeedDaemonReload=no\n"),
	}
	uc := r.probeUnitConfinement(context.Background(), unit, 0xF)
	if uc.Probed || uc.wider() {
		t.Error("expected an inactive unit to be neither probed nor wider")
	}
}

// TestProbeUnitConfinement_RunningNarrower_NeverWider: a self-narrowed
// process (running bounding set is a STRICT SUBSET of declared) must never
// read as wider — round Z (Z3): narrower is silent, not even reported.
func TestProbeUnitConfinement_RunningNarrower_NeverWider(t *testing.T) {
	r, runner := probeTestReconciler(t)
	unit := lifecycle.UnitName("m1", "app")
	runner.StubOutput = map[string][]byte{
		showPropsKey(unit): []byte("ActiveState=active\nMainPID=4242\nNeedDaemonReload=no\n"),
	}
	fakeProcPID(t, withProcRoot(t), 4242, 0x3, 0x0)
	uc := r.probeUnitConfinement(context.Background(), unit, 0xF)
	if !uc.Probed {
		t.Fatal("expected an active unit with a live MainPID to be probed")
	}
	if uc.wider() {
		t.Error("REGRESSION: a self-narrowed process must never read as wider")
	}
}

// TestProbeUnitConfinement_RunningWider_IsWider: a running bounding set
// with bits OUTSIDE declared reads as wider.
func TestProbeUnitConfinement_RunningWider_IsWider(t *testing.T) {
	r, runner := probeTestReconciler(t)
	unit := lifecycle.UnitName("m1", "app")
	runner.StubOutput = map[string][]byte{
		showPropsKey(unit): []byte("ActiveState=active\nMainPID=4242\nNeedDaemonReload=no\n"),
	}
	fakeProcPID(t, withProcRoot(t), 4242, 0x1F, 0x0)
	uc := r.probeUnitConfinement(context.Background(), unit, 0xF)
	if !uc.wider() {
		t.Error("expected a wider-than-declared bounding set to read as wider")
	}
}

// TestProbeUnitConfinement_AmbientWiderSubsetCheck: ambient is compared as
// a SUBSET (design section 1) — a running ambient set with a bit outside
// declared is wider even when bounding matches exactly, but a running
// ambient set that is a (possibly proper) subset of declared is not wider
// on the ambient axis, regardless of bounding.
func TestProbeUnitConfinement_AmbientWiderSubsetCheck(t *testing.T) {
	r, runner := probeTestReconciler(t)
	unit := lifecycle.UnitName("m1", "app")
	runner.StubOutput = map[string][]byte{
		showPropsKey(unit): []byte("ActiveState=active\nMainPID=4242\nNeedDaemonReload=no\n"),
	}
	root := withProcRoot(t)
	fakeProcPID(t, root, 4242, 0xF, 0x10) // bounding matches; ambient has an extra bit
	uc := r.probeUnitConfinement(context.Background(), unit, 0xF)
	if !uc.wider() {
		t.Error("expected an ambient bit outside declared to read as wider even with bounding matching")
	}

	fakeProcPID(t, root, 4242, 0xF, 0x3) // ambient is a strict subset of declared
	uc = r.probeUnitConfinement(context.Background(), unit, 0xF)
	if uc.wider() {
		t.Error("expected an ambient subset of declared (with bounding matching) to not be wider")
	}
}

// TestHandleStaleUnit_NeverMutatesSystemdRegardlessOfNodeType is round Z's
// own replacement for the round-Y R2 tests (self-hosted-withholds,
// unknown-withholds, non-self-hosted-restarts-then-backs-off — R2 itself is
// deleted, Z1): a WIDER finding is reported on EVERY node type — self-
// hosted, detection Unknown, and a definite remote/non-self-hosted node —
// and NEVER issues systemctl restart, reload or stop. There is no longer a
// node-type-dependent branch in handleStaleUnit at all to distinguish.
func TestHandleStaleUnit_NeverMutatesSystemdRegardlessOfNodeType(t *testing.T) {
	unit := lifecycle.UnitName("m1", "app")
	uc := unitConfinement{Unit: unit, Probed: true, RunningBnd: 0x1F, Declared: 0xF}

	cases := []struct {
		name  string
		setup func(t *testing.T, r *Reconciler)
	}{
		{"self-hosted", func(t *testing.T, r *Reconciler) { r.selfHostLatched = true }},
		{"detection-unknown", func(t *testing.T, r *Reconciler) {
			r.cfg.PlatformURL = "https://ops-hub.example.test"
			withLookups(t, nil, []string{"192.0.2.1"}, fmt.Errorf("no such host"))
		}},
		{"definite-remote", func(t *testing.T, r *Reconciler) {
			r.cfg.PlatformURL = "https://ops-hub.example.test"
			withLookups(t, map[string][]string{"ops-hub.example.test": {"192.0.2.22"}}, []string{"192.0.2.99"}, nil)
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			r, runner := probeTestReconciler(t)
			tc.setup(t, r)
			var onErrors []string
			r.cfg.OnError = func(stage string, err error) { onErrors = append(onErrors, stage+": "+err.Error()) }

			r.handleStaleUnit(mount.Module{ID: "m1"}, uc)

			if len(runner.Invocations) != 0 {
				t.Errorf("Z1 REGRESSION: expected NO systemctl mutation of any kind on %s, got %v", tc.name, runner.Invocations)
			}
			if !convergenceFailuresContain(onErrors, "reconciler:confinement_stale") || !convergenceFailuresContain(onErrors, unit) {
				t.Errorf("expected a report naming %s, got %v", unit, onErrors)
			}
		})
	}
}

// TestReconcileStaleConfinement_FailClosedDropInPlusWiderNeverRestarts is
// the "previously looping case" round Z's operator decision names
// explicitly: reviewer A found round Y's own R2 could restart a unit
// FOREVER, on a 15-minute cadence, when its drop-in write kept failing
// closed — the restart never actually applied the narrower policy (the
// on-disk drop-in never changed), so R2 just kept restarting the same
// service, permanently, for a condition it had no way to fix. With R2
// deleted, this must simply never restart, reload or stop anything, on
// ANY tick, no matter how many times the write keeps failing while the
// running process stays wider.
func TestReconcileStaleConfinement_FailClosedDropInPlusWiderNeverRestarts(t *testing.T) {
	r, client, runner, _, manifestRoot, dropIns := newConfinementReattachReconciler(t)
	unit := lifecycle.UnitName("m1", "app")

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 1: %v", err)
	}

	// Force the drop-in write to fail closed from here on: block the exact
	// path capabilities.conf needs with a directory (security_fail_closed_
	// reattach_path_test.go's own established technique).
	unitDropInDir := filepath.Join(dropIns, unit+".d")
	blocked := filepath.Join(unitDropInDir, "capabilities.conf")
	if err := os.RemoveAll(blocked); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(blocked, 0o755); err != nil {
		t.Fatal(err)
	}

	// A capabilities-list edit (same digest) so the reattach loop actually
	// attempts (and fails) the write on every subsequent tick.
	if err := os.RemoveAll(filepath.Join(manifestRoot, "m1")); err != nil {
		t.Fatal(err)
	}
	client.responses["/api/v1/system/node_api/modules/m1"] = manifestFixtureWithCaps("abc123", []string{"CAP_CHOWN", "CAP_NET_ADMIN"})
	declared := capMaskFor(t, []string{"CAP_CHOWN", "CAP_NET_ADMIN"})
	root := withProcRoot(t)
	fakeProcPID(t, root, 4242, declared|testExtraCapBit, 0x0) // running process stays wider — the fix never lands
	runner.StubOutput = staleProbeStub(unit, "active", 4242, false)

	for i := 2; i <= 4; i++ {
		pre := len(runner.Invocations)
		if err := r.RunOnce(context.Background()); err != nil {
			t.Fatalf("RunOnce tick %d: %v", i, err)
		}
		tick := runner.Invocations[pre:]
		if hasSystemctlOp(tick, "restart", unit) || countSystemctlOp(tick, "daemon-reload") != 0 || hasSystemctlOp(tick, "stop", unit) {
			t.Errorf("Z1 REGRESSION: tick %d issued a systemctl mutation for a permanently fail-closed, wider unit — the exact restart loop round Z deleted R2 to close, invocations=%v", i, tick)
		}
		if got := r.SecurityFailClosedUnits(); !containsArg(got, unit) {
			t.Errorf("tick %d: precondition failed — expected the write to still be failing closed, SecurityFailClosedUnits()=%v", i, got)
		}
	}
}

// TestReconcileStaleConfinement_N4Gate_SkipsPendingDigestModule pins the
// probe's own copy of the N4 gate (identical reasoning to
// reconfirmConfinementIfNeeded's own, confinement_recheck_n4_n5_test.go): a
// module mid-upgrade must not be probed at all, wider or not — no
// systemctl call for its units, no restart, not named in the stale set.
func TestReconcileStaleConfinement_N4Gate_SkipsPendingDigestModule(t *testing.T) {
	r, runner := probeTestReconciler(t)
	unit := lifecycle.UnitName("m1", "app")
	runner.StubOutput = map[string][]byte{
		showPropsKey(unit): []byte("ActiveState=active\nMainPID=4242\nNeedDaemonReload=no\n"),
	}
	fakeProcPID(t, withProcRoot(t), 4242, 0x1F, 0x0) // would read as wider if ever probed

	mf := parseManifestEnvelope(t, manifestFixtureWithCaps("abc123", []string{"CAP_CHOWN"}))
	current := &mount.State{AttachedModules: []mount.Module{
		{ID: "m1", Digest: "abc123", PendingDigest: "d2-inflight"},
	}}
	manifests := map[string]*manifest.Manifest{"m1": mf}

	r.reconcileStaleConfinement(context.Background(), current, manifests)

	if got := r.ConfinementStaleUnits(); len(got) != 0 {
		t.Errorf("N4 REGRESSION: expected a PendingDigest module's units to never be probed, got stale=%v", got)
	}
	for _, inv := range runner.Invocations {
		if inv.Op == "Output" && inv.Name == "systemctl" {
			t.Errorf("N4 REGRESSION: expected NO systemctl show call for a PendingDigest module's unit, got %v", inv)
		}
	}
}

// TestReconcileStaleConfinement_ProbeFailureIsReported is round Z's Z6
// (reviewer A, LOW): a probe failure (systemctl show itself erroring, or
// /proc vanishing between the is-active read and the status read) must be
// visible — before this fix it was silently dropped (uc.Err set, Probed
// stays false, wider() reads false, the loop just moves on), so a unit
// that WAS actually wider this tick went completely unreported with no
// signal anything was even checked.
func TestReconcileStaleConfinement_ProbeFailureIsReported(t *testing.T) {
	mf := parseManifestEnvelope(t, manifestFixtureWithCaps("abc123", []string{"CAP_CHOWN"}))
	current := &mount.State{AttachedModules: []mount.Module{{ID: "m1", Digest: "abc123"}}}
	manifests := map[string]*manifest.Manifest{"m1": mf}
	unit := lifecycle.UnitName("m1", "app")

	t.Run("systemctl show fails", func(t *testing.T) {
		r, runner := probeTestReconciler(t)
		runner.StubErr = map[string]error{showPropsKey(unit): errors.New("connection refused to systemd bus")}
		var onErrors []string
		r.cfg.OnError = func(stage string, err error) { onErrors = append(onErrors, stage+": "+err.Error()) }

		r.reconcileStaleConfinement(context.Background(), current, manifests)

		if !convergenceFailuresContain(onErrors, "reconciler:confinement_probe_failed") || !convergenceFailuresContain(onErrors, unit) {
			t.Errorf("Z6 REGRESSION: expected a confinement_probe_failed report naming %s, got %v", unit, onErrors)
		}
	})

	t.Run("proc read fails (process vanished)", func(t *testing.T) {
		r, runner := probeTestReconciler(t)
		withProcRoot(t) // empty — no <pid>/status file at all
		runner.StubOutput = map[string][]byte{
			showPropsKey(unit): []byte("ActiveState=active\nMainPID=4242\nNeedDaemonReload=no\n"),
		}
		var onErrors []string
		r.cfg.OnError = func(stage string, err error) { onErrors = append(onErrors, stage+": "+err.Error()) }

		r.reconcileStaleConfinement(context.Background(), current, manifests)

		if !convergenceFailuresContain(onErrors, "reconciler:confinement_probe_failed") || !convergenceFailuresContain(onErrors, unit) {
			t.Errorf("Z6 REGRESSION: expected a confinement_probe_failed report naming %s, got %v", unit, onErrors)
		}
	})
}

// TestReconcileStaleConfinement_NarrowerIsCompletelySilent is Z3's own
// integration-level pin: a narrower-only finding must not appear in
// ConfinementStaleUnits() and must not report ANYTHING through OnError —
// not even the round-Y/Z1 "report only" message. Silent means silent.
// (Originally paired with Z3's own cap_last_cap fixture; that intersection
// was deleted in Z7 as provably inert, so this test no longer pins
// cap_last_cap at all — only the narrower-is-silent gate.)
func TestReconcileStaleConfinement_NarrowerIsCompletelySilent(t *testing.T) {
	r, runner := probeTestReconciler(t)
	unit := lifecycle.UnitName("m1", "app")
	root := withProcRoot(t)
	runner.StubOutput = map[string][]byte{
		showPropsKey(unit): []byte("ActiveState=active\nMainPID=4242\nNeedDaemonReload=no\n"),
	}
	fakeProcPID(t, root, 4242, 0x3, 0x0) // strictly narrower than declared (0xF)

	mf := parseManifestEnvelope(t, manifestFixtureWithCaps("abc123", []string{"CAP_CHOWN", "CAP_FOWNER", "CAP_DAC_OVERRIDE", "CAP_NET_ADMIN"}))
	current := &mount.State{AttachedModules: []mount.Module{{ID: "m1", Digest: "abc123"}}}
	manifests := map[string]*manifest.Manifest{"m1": mf}

	var onErrors []string
	r.cfg.OnError = func(stage string, err error) { onErrors = append(onErrors, stage+": "+err.Error()) }

	r.reconcileStaleConfinement(context.Background(), current, manifests)

	if got := r.ConfinementStaleUnits(); len(got) != 0 {
		t.Errorf("Z3 REGRESSION: expected a narrower-only finding to be completely absent from ConfinementStaleUnits(), got %v", got)
	}
	if convergenceFailuresContain(onErrors, "reconciler:confinement_stale") {
		t.Errorf("Z3 REGRESSION: expected NO confinement_stale report at all for a narrower-only finding, got %v", onErrors)
	}
}

// TestReconcileStaleConfinement_N4Gate_SkipsDigestMismatchModule is round
// Z's Z4 (Y8): the PROBE's own copy of the N4 gate's SECOND clause — a
// module whose attached digest no longer matches this tick's fetched
// manifest (PendingDigest itself empty) must be skipped exactly like the
// PendingDigest-set half already tested above.
// TestReconcileStaleConfinement_N4Gate_SkipsPendingDigestModule only
// exercised the first clause; this closes the gap on the second.
func TestReconcileStaleConfinement_N4Gate_SkipsDigestMismatchModule(t *testing.T) {
	r, runner := probeTestReconciler(t)
	unit := lifecycle.UnitName("m1", "app")
	runner.StubOutput = map[string][]byte{
		showPropsKey(unit): []byte("ActiveState=active\nMainPID=4242\nNeedDaemonReload=no\n"),
	}
	fakeProcPID(t, withProcRoot(t), 4242, 0x1F, 0x0) // would read as wider if ever probed

	mf := parseManifestEnvelope(t, manifestFixtureWithCaps("def456", []string{"CAP_CHOWN"})) // freshly fetched: def456
	current := &mount.State{AttachedModules: []mount.Module{
		{ID: "m1", Digest: "abc123"}, // attached: abc123 — mismatch, PendingDigest empty
	}}
	manifests := map[string]*manifest.Manifest{"m1": mf}

	r.reconcileStaleConfinement(context.Background(), current, manifests)

	if got := r.ConfinementStaleUnits(); len(got) != 0 {
		t.Errorf("Y8/N4 REGRESSION: expected a digest-mismatch module's units to never be probed, got stale=%v", got)
	}
	for _, inv := range runner.Invocations {
		if inv.Op == "Output" && inv.Name == "systemctl" {
			t.Errorf("Y8/N4 REGRESSION: expected NO systemctl show call for a digest-mismatch module's unit, got %v", inv)
		}
	}
}

// TestDeclaredCapMasks_PrivilegedModuleIsSkipped is round Z's Z4 (Y6): a
// privileged module must never be probed. Confirms EQUIVALENCE too: the
// explicit policy.Privileged early return in declaredCapMasks is actually
// REDUNDANT with the natural behaviour — decideModuleSecurityPolicy skips
// its own capability-resolution loop entirely under Privileged (see that
// function's own `if !policy.Privileged` guard), so unitAllow (and
// therefore the returned masks map) is ALREADY EMPTY for a privileged
// module even without this function's own explicit check — the per-unit
// loop's own `declared, ok := masks[unit]; if !ok { continue }` would skip
// every one of its units regardless. Both facts are asserted here.
func TestDeclaredCapMasks_PrivilegedModuleIsSkipped(t *testing.T) {
	r, runner := probeTestReconciler(t)
	unit := lifecycle.UnitName("m1", "app")
	runner.StubOutput = map[string][]byte{
		showPropsKey(unit): []byte("ActiveState=active\nMainPID=4242\nNeedDaemonReload=no\n"),
	}
	fakeProcPID(t, withProcRoot(t), 4242, 0x1F, 0x0) // would read as wider if ever probed

	mod := mount.Module{ID: "m1", Digest: "abc123"}
	mf := parseManifestEnvelope(t, manifestFixturePrivileged("abc123"))
	r.privilegedAllow = []string{"m1"} // approved, so this is a genuinely privileged, non-refused module

	masks, ok := r.declaredCapMasks(mod, mf)
	if ok {
		t.Errorf("expected declaredCapMasks to return ok=false for a privileged module, got masks=%v", masks)
	}
	if len(masks) != 0 {
		t.Errorf("EQUIVALENCE CHECK: expected the underlying unitAllow to already be empty for a privileged module regardless of the explicit early return, got %v", masks)
	}

	// End-to-end: the stale probe must never issue a single systemctl call
	// for this module's units.
	current := &mount.State{AttachedModules: []mount.Module{mod}}
	manifests := map[string]*manifest.Manifest{"m1": mf}
	r.reconcileStaleConfinement(context.Background(), current, manifests)
	if got := r.ConfinementStaleUnits(); len(got) != 0 {
		t.Errorf("Y6 REGRESSION: expected a privileged module's units to never be probed, got stale=%v", got)
	}
	for _, inv := range runner.Invocations {
		if inv.Op == "Output" && inv.Name == "systemctl" {
			t.Errorf("Y6 REGRESSION: expected NO systemctl show call for a privileged module's unit, got %v", inv)
		}
	}
}

// TestReconcileStaleConfinement_PublishesForHeartbeat pins the heartbeat
// wiring end to end: ConfinementStaleUnits() reflects the most recently
// completed pass, and clears once the unit reads clean.
func TestReconcileStaleConfinement_PublishesForHeartbeat(t *testing.T) {
	r, runner := probeTestReconciler(t)
	unit := lifecycle.UnitName("m1", "app")
	runner.StubOutput = map[string][]byte{
		showPropsKey(unit): []byte("ActiveState=active\nMainPID=4242\nNeedDaemonReload=no\n"),
	}
	root := withProcRoot(t)
	fakeProcPID(t, root, 4242, 0x1F, 0x0)

	mf := parseManifestEnvelope(t, manifestFixtureWithCaps("abc123", []string{"CAP_CHOWN"}))
	current := &mount.State{AttachedModules: []mount.Module{{ID: "m1", Digest: "abc123"}}}
	manifests := map[string]*manifest.Manifest{"m1": mf}

	r.reconcileStaleConfinement(context.Background(), current, manifests)
	if got := r.ConfinementStaleUnits(); len(got) != 1 || got[0] != unit {
		t.Fatalf("ConfinementStaleUnits() = %v, want [%s]", got, unit)
	}

	// Clean pass: rewrite the fixture to match declared exactly.
	declaredMask := capMaskFor(t, []string{"CAP_CHOWN"})
	fakeProcPID(t, root, 4242, declaredMask, 0x0)
	r.reconcileStaleConfinement(context.Background(), current, manifests)
	if got := r.ConfinementStaleUnits(); len(got) != 0 {
		t.Errorf("expected ConfinementStaleUnits() to clear once the unit matches declared, got %v", got)
	}
}
