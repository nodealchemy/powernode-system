package runtime

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/lifecycle"
)

// Round Z, Z4: reviewer probe #3 at the RunOnce level, explicitly reproduced
// (round Y had scoped this out, citing the pre-existing
// TestReconcile_NewBootCompositionRewritesADivergentDropInAndW1ThenApplies
// as equivalent coverage — that test simulates a divergent capabilities.conf
// directly, not the LEGACY ambient-capabilities.conf cleanup path (X6/X7),
// which is a distinct writer with its own changed-signal contribution; team-
// lead asked for the exact scenario named in the original design). A reboot
// with a legacy ambient-capabilities.conf file still present and a NEW
// composition key: the first tick removes the legacy file and rewrites the
// drop-ins.

// armBootComposition wires the three seams confinementRecheckKey checks
// (pivotAwareRootModeChecked, the boot breadcrumb, currentBootID) — same
// pattern as TestReconcile_NewBootCompositionRewritesADivergentDropInAndW1ThenApplies
// — and returns a writeBreadcrumb helper plus the boot-id setter.
func armBootComposition(t *testing.T) (writeBreadcrumb func(bootID string, at time.Time), setBoot func(string)) {
	t.Helper()
	origMode, origChecked := pivotAwareRootMode, pivotAwareRootModeChecked
	pivotAwareRootMode = func() lifecycle.RootMode { return lifecycle.RootModeNative }
	pivotAwareRootModeChecked = func() (lifecycle.RootMode, error) { return lifecycle.RootModeNative, nil }
	origBoot := currentBootID
	boot := ""
	currentBootID = func() string { return boot }
	t.Cleanup(func() {
		pivotAwareRootMode, pivotAwareRootModeChecked = origMode, origChecked
		currentBootID = origBoot
	})
	breadcrumbPath := filepath.Join(t.TempDir(), "boot-composed.json")
	t.Cleanup(SetBootBreadcrumbPathForTest(breadcrumbPath))
	writeBreadcrumb = func(bootID string, at time.Time) {
		t.Helper()
		if err := WriteBreadcrumb(breadcrumbPath, &BootComposedBreadcrumb{BootID: bootID, ComposedAt: at}); err != nil {
			t.Fatalf("WriteBreadcrumb: %v", err)
		}
	}
	setBoot = func(id string) { boot = id }
	return writeBreadcrumb, setBoot
}

// TestConfinementReboot_LegacyAmbientFileRemoved_SelfHostedReloadsNoRestart
// is probe #3's self-hosted half: the legacy file is removed, drop-ins
// rewritten, daemon-reload issued — but rule 1 withholds the restart.
func TestConfinementReboot_LegacyAmbientFileRemoved_SelfHostedReloadsNoRestart(t *testing.T) {
	r, _, runner, _, _, dropIns := newConfinementReattachReconciler(t)
	r.selfHostLatched = true
	unit := lifecycle.UnitName("m1", "app")

	writeBreadcrumb, setBoot := armBootComposition(t)
	const bootA, bootB = "boot-a", "boot-b"
	setBoot(bootA)
	composedAt := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	writeBreadcrumb(bootA, composedAt)

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 1 (boot A): %v", err)
	}

	// An OLDER initramfs agent's own compose left a legacy per-unit ambient
	// drop-in behind — X6/X7's own cleanup target.
	legacyPath := filepath.Join(dropIns, unit+".d", "ambient-capabilities.conf")
	if err := os.WriteFile(legacyPath, []byte("[Service]\nAmbientCapabilities=CAP_CHOWN\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	setBoot(bootB)
	writeBreadcrumb(bootB, composedAt.Add(time.Hour))
	runner.StubOutput = map[string][]byte{"systemctl is-active " + unit: []byte("active\n")}
	pre := len(runner.Invocations)

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 2 (boot B): %v", err)
	}

	if _, err := os.Stat(legacyPath); !os.IsNotExist(err) {
		t.Errorf("expected the legacy ambient-capabilities.conf to be removed on the new composition's first tick, stat err=%v", err)
	}
	tick2 := runner.Invocations[pre:]
	if countSystemctlOp(tick2, "daemon-reload") == 0 {
		t.Errorf("expected a daemon-reload for the legacy-file removal, invocations=%v", tick2)
	}
	if hasSystemctlOp(tick2, "restart", unit) {
		t.Errorf("invariant 1 REGRESSION: a self-hosted node must never restart, even for a legacy-ambient-file cleanup, invocations=%v", tick2)
	}
}

// TestConfinementReboot_LegacyAmbientFileRemoved_NonSelfHostedRestartsChangedUnitOnly
// is probe #3's non-self-hosted half: the SAME cleanup, on an ordinary node
// (no hub modules attached either — Z2's own positive-proof gate must not
// interfere), restarts the changed unit.
func TestConfinementReboot_LegacyAmbientFileRemoved_NonSelfHostedRestartsChangedUnitOnly(t *testing.T) {
	r, _, runner, _, _, dropIns := newConfinementReattachReconciler(t)
	unit := lifecycle.UnitName("m1", "app")

	// Round Z (Z2): an explicit, clearly-remote platform, and no hub module
	// attached (this fixture's only module is "app-mod").
	r.cfg.PlatformURL = "https://ops-hub.example.test"
	withLookups(t, map[string][]string{"ops-hub.example.test": {"192.0.2.22"}}, []string{"192.0.2.99"}, nil)

	writeBreadcrumb, setBoot := armBootComposition(t)
	const bootA, bootB = "boot-a", "boot-b"
	setBoot(bootA)
	composedAt := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	writeBreadcrumb(bootA, composedAt)

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 1 (boot A): %v", err)
	}

	legacyPath := filepath.Join(dropIns, unit+".d", "ambient-capabilities.conf")
	if err := os.WriteFile(legacyPath, []byte("[Service]\nAmbientCapabilities=CAP_CHOWN\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	setBoot(bootB)
	writeBreadcrumb(bootB, composedAt.Add(time.Hour))
	runner.StubOutput = map[string][]byte{"systemctl is-active " + unit: []byte("active\n")}
	pre := len(runner.Invocations)

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 2 (boot B): %v", err)
	}

	if _, err := os.Stat(legacyPath); !os.IsNotExist(err) {
		t.Errorf("expected the legacy ambient-capabilities.conf to be removed, stat err=%v", err)
	}
	tick2 := runner.Invocations[pre:]
	if n := countSystemctlOp(tick2, "restart"); n != 1 {
		t.Errorf("expected exactly ONE restart (the changed unit) on a non-self-hosted node with no hub modules, got %d, invocations=%v", n, tick2)
	}
	if !hasSystemctlOp(tick2, "restart", unit) {
		t.Errorf("expected the restart to name %s specifically, invocations=%v", unit, tick2)
	}
}
