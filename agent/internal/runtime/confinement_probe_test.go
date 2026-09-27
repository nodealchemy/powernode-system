package runtime

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"

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
	if uc.stale() || uc.wider() {
		t.Error("expected RemainAfterExit to be neither stale nor wider")
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
	if uc.Probed || uc.stale() {
		t.Error("expected an inactive unit to be neither probed nor stale")
	}
}

// TestProbeUnitConfinement_RunningNarrower_StaleNotWider: a self-narrowed
// process (running bounding set is a STRICT SUBSET of declared) is stale
// (it diverges) but never wider — the direction R2 must not restart for.
func TestProbeUnitConfinement_RunningNarrower_StaleNotWider(t *testing.T) {
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
	if !uc.stale() {
		t.Error("expected a narrower-than-declared bounding set to read as stale")
	}
	if uc.wider() {
		t.Error("REGRESSION: a self-narrowed process must never read as wider")
	}
}

// TestProbeUnitConfinement_RunningWider_StaleAndWider: a running bounding
// set with bits OUTSIDE declared is both stale and wider — the shape R2
// self-heals.
func TestProbeUnitConfinement_RunningWider_StaleAndWider(t *testing.T) {
	r, runner := probeTestReconciler(t)
	unit := lifecycle.UnitName("m1", "app")
	runner.StubOutput = map[string][]byte{
		showPropsKey(unit): []byte("ActiveState=active\nMainPID=4242\nNeedDaemonReload=no\n"),
	}
	fakeProcPID(t, withProcRoot(t), 4242, 0x1F, 0x0)
	uc := r.probeUnitConfinement(context.Background(), unit, 0xF)
	if !uc.stale() || !uc.wider() {
		t.Errorf("expected a wider-than-declared bounding set to be both stale and wider, got stale=%v wider=%v", uc.stale(), uc.wider())
	}
}

// TestProbeUnitConfinement_AmbientWiderSubsetCheck: ambient is compared as
// a SUBSET (design section 1) — a running ambient set with a bit outside
// declared is wider even when bounding matches exactly, but a running
// ambient set that is a (possibly proper) subset of declared is neither
// stale nor wider on the ambient axis, regardless of bounding.
func TestProbeUnitConfinement_AmbientWiderSubsetCheck(t *testing.T) {
	r, runner := probeTestReconciler(t)
	unit := lifecycle.UnitName("m1", "app")
	runner.StubOutput = map[string][]byte{
		showPropsKey(unit): []byte("ActiveState=active\nMainPID=4242\nNeedDaemonReload=no\n"),
	}
	root := withProcRoot(t)
	fakeProcPID(t, root, 4242, 0xF, 0x10) // bounding matches; ambient has an extra bit
	uc := r.probeUnitConfinement(context.Background(), unit, 0xF)
	if !uc.stale() || !uc.wider() {
		t.Errorf("expected an ambient bit outside declared to be stale+wider even with bounding matching, got stale=%v wider=%v", uc.stale(), uc.wider())
	}

	fakeProcPID(t, root, 4242, 0xF, 0x3) // ambient is a strict subset of declared
	uc = r.probeUnitConfinement(context.Background(), unit, 0xF)
	if uc.stale() || uc.wider() {
		t.Errorf("expected an ambient subset of declared (with bounding matching) to be neither stale nor wider, got stale=%v wider=%v", uc.stale(), uc.wider())
	}
}

// TestHandleStaleUnit_SelfHostedNeverRestarts pins invariant 1: a wider
// unit on a self-hosted node is reported but NEVER restarted.
func TestHandleStaleUnit_SelfHostedNeverRestarts(t *testing.T) {
	r, runner := probeTestReconciler(t)
	r.selfHostLatched = true
	unit := lifecycle.UnitName("m1", "app")
	var onErrors []string
	r.cfg.OnError = func(stage string, err error) { onErrors = append(onErrors, stage+": "+err.Error()) }

	uc := unitConfinement{Unit: unit, Probed: true, RunningBnd: 0x1F, Declared: 0xF}
	r.handleStaleUnit(context.Background(), mount.Module{ID: "m1"}, uc)

	if hasSystemctlOp(runner.Invocations, "restart", unit) {
		t.Error("invariant 1 REGRESSION: a self-hosted node must never restart on a wider confinement finding")
	}
	if !convergenceFailuresContain(onErrors, "reconciler:confinement_stale") || !convergenceFailuresContain(onErrors, unit) {
		t.Errorf("expected a withheld-restart report naming %s, got %v", unit, onErrors)
	}
}

// TestHandleStaleUnit_UnknownNeverRestarts pins N2's own extension into R2:
// Unknown detection must withhold a level restart exactly like Yes does.
func TestHandleStaleUnit_UnknownNeverRestarts(t *testing.T) {
	r, runner := probeTestReconciler(t)
	r.cfg.PlatformURL = "https://ops-hub.example.test"
	withLookups(t, nil, []string{"192.0.2.1"}, fmt.Errorf("no such host"))

	unit := lifecycle.UnitName("m1", "app")
	uc := unitConfinement{Unit: unit, Probed: true, RunningBnd: 0x1F, Declared: 0xF}
	r.handleStaleUnit(context.Background(), mount.Module{ID: "m1"}, uc)

	if hasSystemctlOp(runner.Invocations, "restart", unit) {
		t.Error("invariant 1 REGRESSION: Unknown detection must withhold a level restart, same as Yes")
	}
}

// TestHandleStaleUnit_NonSelfHostedRestartsThenBacksOff pins R2 itself: a
// non-self-hosted node restarts a wider unit once, and a SECOND finding
// within the 15-minute backoff window does not restart it again.
func TestHandleStaleUnit_NonSelfHostedRestartsThenBacksOff(t *testing.T) {
	r, runner := probeTestReconciler(t)
	unit := lifecycle.UnitName("m1", "app")
	runner.StubOutput = map[string][]byte{"systemctl is-active " + unit: []byte("active\n")}
	var onErrors []string
	r.cfg.OnError = func(stage string, err error) { onErrors = append(onErrors, stage+": "+err.Error()) }

	fixedNow := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	origNow := nowForConfinementBackoff
	now := fixedNow
	nowForConfinementBackoff = func() time.Time { return now }
	t.Cleanup(func() { nowForConfinementBackoff = origNow })

	uc := unitConfinement{Unit: unit, Probed: true, RunningBnd: 0x1F, Declared: 0xF}
	r.handleStaleUnit(context.Background(), mount.Module{ID: "m1"}, uc)
	if !hasSystemctlOp(runner.Invocations, "restart", unit) {
		t.Fatalf("expected the first wider finding to issue a restart, invocations=%v", runner.Invocations)
	}

	preSecond := len(runner.Invocations)
	now = fixedNow.Add(5 * time.Minute) // inside the 15-minute backoff
	r.handleStaleUnit(context.Background(), mount.Module{ID: "m1"}, uc)
	if hasSystemctlOp(runner.Invocations[preSecond:], "restart", unit) {
		t.Errorf("R2 REGRESSION: expected the second finding (5 min later) to be backed off, invocations=%v", runner.Invocations[preSecond:])
	}
	if !convergenceFailuresContain(onErrors, "backed off") {
		t.Errorf("expected a backoff report, got %v", onErrors)
	}

	preThird := len(runner.Invocations)
	now = fixedNow.Add(16 * time.Minute) // past the 15-minute backoff
	r.handleStaleUnit(context.Background(), mount.Module{ID: "m1"}, uc)
	if !hasSystemctlOp(runner.Invocations[preThird:], "restart", unit) {
		t.Errorf("expected a THIRD finding past the backoff window to restart again, invocations=%v", runner.Invocations[preThird:])
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
