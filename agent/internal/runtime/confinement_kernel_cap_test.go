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
)

// fakeCapLastCap writes /proc/sys/kernel/cap_last_cap (under procRoot,
// withProcRoot's own seam) so tests can pin the running kernel's own
// highest supported capability bit.
func fakeCapLastCap(t *testing.T, root string, n int) {
	t.Helper()
	dir := filepath.Join(root, "sys", "kernel")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "cap_last_cap"), []byte(itoaTest(n)+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
}

// TestCapLastCapMask_ReadsAndBuildsTheRange pins capLastCapMask's own
// parsing directly: cap_last_cap=39 yields a 40-bit mask (bits 0-39).
func TestCapLastCapMask_ReadsAndBuildsTheRange(t *testing.T) {
	root := withProcRoot(t)
	fakeCapLastCap(t, root, 39)
	want := (uint64(1) << 40) - 1 // bits 0..39
	if got := capLastCapMask(); got != want {
		t.Errorf("capLastCapMask() = %#x, want %#x", got, want)
	}
}

// TestCapLastCapMask_FailsOpenWhenUnreadable pins the fail-open default: an
// unreadable/missing cap_last_cap must not silently suppress every
// genuine widening finding by pretending the kernel supports zero
// capabilities.
func TestCapLastCapMask_FailsOpenWhenUnreadable(t *testing.T) {
	withProcRoot(t) // empty temp dir — no cap_last_cap file at all
	if got := capLastCapMask(); got != ^uint64(0) {
		t.Errorf("capLastCapMask() = %#x, want all-ones (fail open) when unreadable", got)
	}
}

// TestConfinementProbe_QgaFullSetOnOlderKernelIsNotWider is round Z's first
// named Z3 test: qga's own "full known capability set" exemption declares
// ALL 41 names this AGENT BINARY knows, including CAP_CHECKPOINT_RESTORE
// (bit 40) — on a kernel whose own cap_last_cap is 39 (one fewer; it does
// not implement CAP_CHECKPOINT_RESTORE at all), the running process can
// never actually hold bit 40 (the kernel has no such capability to grant),
// so its own CapBnd is exactly the 40-bit range this kernel supports. This
// must never read as wider.
func TestConfinementProbe_QgaFullSetOnOlderKernelIsNotWider(t *testing.T) {
	r, runner := probeTestReconciler(t)
	unit := lifecycle.UnitName("m1", "qga")
	root := withProcRoot(t)
	fakeCapLastCap(t, root, 39)

	allKnown := make([]string, 0, len(security.KnownCapabilities))
	for name := range security.KnownCapabilities {
		allKnown = append(allKnown, name)
	}
	declared := capMaskFor(t, allKnown) // all 41 known bits, 0-40

	runner.StubOutput = map[string][]byte{
		showPropsKey(unit): []byte("ActiveState=active\nMainPID=4242\nNeedDaemonReload=no\n"),
	}
	// Exactly what this OLDER kernel can actually grant: every bit up to
	// its own cap_last_cap, and nothing above it — bit 40 is physically
	// impossible here.
	runningOnOlderKernel := (uint64(1) << 40) - 1 // bits 0-39
	fakeProcPID(t, root, 4242, runningOnOlderKernel, 0x0)

	uc := r.probeUnitConfinement(context.Background(), unit, declared&capLastCapMask())
	if uc.wider() {
		t.Errorf("Z3 REGRESSION: qga's full-known-set grant on an older kernel (cap_last_cap=39) must not read as wider, got RunningBnd=%#x Declared=%#x", uc.RunningBnd, uc.Declared)
	}
}

// TestConfinementProbe_SelfNarrowedDaemonIsNotWider is round Z's second
// named Z3 test: a daemon that drops its OWN capabilities at runtime
// (self-narrowing, independent of what systemd granted) must never read as
// wider — this is the narrower direction Z3 makes entirely silent.
func TestConfinementProbe_SelfNarrowedDaemonIsNotWider(t *testing.T) {
	r, runner := probeTestReconciler(t)
	unit := lifecycle.UnitName("m1", "app")
	root := withProcRoot(t)
	fakeCapLastCap(t, root, 40)

	declared := capMaskFor(t, []string{"CAP_CHOWN", "CAP_NET_ADMIN", "CAP_DAC_OVERRIDE"})
	runner.StubOutput = map[string][]byte{
		showPropsKey(unit): []byte("ActiveState=active\nMainPID=4242\nNeedDaemonReload=no\n"),
	}
	selfNarrowed := capMaskFor(t, []string{"CAP_CHOWN"}) // dropped the other two itself
	fakeProcPID(t, root, 4242, selfNarrowed, 0x0)

	uc := r.probeUnitConfinement(context.Background(), unit, declared&capLastCapMask())
	if uc.wider() {
		t.Errorf("Z3 REGRESSION: a self-narrowed daemon must not read as wider, got RunningBnd=%#x Declared=%#x", uc.RunningBnd, uc.Declared)
	}
}

// TestReconcileStaleConfinement_NarrowerIsCompletelySilent is Z3's own
// integration-level pin: a narrower-only finding must not appear in
// ConfinementStaleUnits() and must not report ANYTHING through OnError —
// not even the round-Y/Z1 "report only" message. Silent means silent.
func TestReconcileStaleConfinement_NarrowerIsCompletelySilent(t *testing.T) {
	r, runner := probeTestReconciler(t)
	unit := lifecycle.UnitName("m1", "app")
	root := withProcRoot(t)
	fakeCapLastCap(t, root, 40)
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
