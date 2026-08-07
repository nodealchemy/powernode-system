package runtime

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/lifecycle"
	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// leaverFixture builds a Reconciler on a pivot-mode sandbox: Layout.Root
// redirects the live-root and pending-prune paths into a temp dir, and
// pivotAwareRootMode is pinned to native for the test's duration.
func leaverFixture(t *testing.T) (*Reconciler, mount.Layout, *[]string) {
	t.Helper()
	layout := mount.Layout{
		Root:             t.TempDir(),
		ModulesMountRoot: t.TempDir(),
	}
	var signals []string
	r := &Reconciler{cfg: ReconcilerConfig{
		Layout: layout,
		OnError: func(stage string, err error) {
			signals = append(signals, stage+": "+err.Error())
		},
	}}
	orig := pivotAwareRootMode
	pivotAwareRootMode = func() lifecycle.RootMode { return lifecycle.RootModeNative }
	t.Cleanup(func() { pivotAwareRootMode = orig })
	return r, layout, &signals
}

func pendingRecordPath(r *Reconciler, moduleID string) string {
	return filepath.Join(r.pendingPruneDir(), moduleID+".json")
}

func TestCaptureLeaverInventories_CapturesTrueLeaversOnly(t *testing.T) {
	r, layout, signals := leaverFixture(t)
	leaver := mount.Module{ID: "retired", Digest: "sha256:gone"}
	bumped := mount.Module{ID: "dev-cell", Digest: "sha256:old"}
	rebooty := mount.Module{ID: "base-os", Digest: "sha256:base"}
	hpWriteFile(t, layout.ModuleMountPath(leaver.Digest), "usr/bin/left-behind", "x")
	hpWriteFile(t, layout.ModuleMountPath(bumped.Digest), "usr/bin/bumped", "y")
	hpWriteFile(t, layout.ModuleMountPath(rebooty.Digest), "usr/bin/kernel-ish", "z")

	got := r.captureLeaverInventories(
		mount.ModuleStack{leaver, bumped, rebooty},
		mount.ModuleStack{{ID: "dev-cell", Digest: "sha256:new"}},
		map[string]*manifest.Manifest{
			"retired": {ProtectedSpec: []string{"/etc/keep/**"}},
			"base-os": {RebootRequired: true},
		},
	)

	if len(got) != 1 {
		t.Fatalf("captured %d records, want exactly the true leaver: %+v", len(got), got)
	}
	rec := got[0]
	if rec.ModuleID != "retired" {
		t.Errorf("captured %q, want the leaver", rec.ModuleID)
	}
	if len(rec.Files) != 1 || rec.Files[0] != "/usr/bin/left-behind" {
		t.Errorf("inventory = %v, want the leaver's file", rec.Files)
	}
	if len(rec.Protected) != 1 || rec.Protected[0] != "/etc/keep/**" {
		t.Errorf("protected spec not carried: %v", rec.Protected)
	}
	if rec.Armed {
		t.Error("a fresh record must be unarmed — arming is the deferral")
	}
	found := false
	for _, s := range *signals {
		if strings.Contains(s, "reboot_pending") && strings.Contains(s, "base-os") {
			found = true
		}
	}
	if !found {
		t.Errorf("a reboot_required leaver must surface reboot_pending, got %v", *signals)
	}
}

func TestCaptureLeaverInventories_NonNativeModeCapturesNothing(t *testing.T) {
	r, layout, _ := leaverFixture(t)
	pivotAwareRootMode = func() lifecycle.RootMode { return lifecycle.RootModeChroot }
	leaver := mount.Module{ID: "retired", Digest: "sha256:gone"}
	hpWriteFile(t, layout.ModuleMountPath(leaver.Digest), "usr/bin/x", "x")

	if got := r.captureLeaverInventories(mount.ModuleStack{leaver}, nil, nil); got != nil {
		t.Errorf("chroot mode remounts the union on every change — nothing to capture, got %+v", got)
	}
}

// The full lifecycle: write at tick T, arm at the first process pass,
// execute at the second — and only then does the file leave the live root.
func TestPendingPrune_OneTickDeferralThenExecution(t *testing.T) {
	r, layout, _ := leaverFixture(t)
	liveFile := filepath.Join(layout.Root, "usr/bin/left-behind")
	hpWriteFile(t, layout.Root, "usr/bin/left-behind", "stale")

	r.writePendingPrunes([]pendingPruneRecord{{
		ModuleID: "retired",
		Digest:   "sha256:gone",
		Files:    []string{"/usr/bin/left-behind"},
	}})

	// Pass 1: arms, prunes nothing.
	r.processPendingPrunes(nil)
	if _, err := os.Stat(liveFile); err != nil {
		t.Fatalf("first pass must only ARM — the live file was already touched: %v", err)
	}
	if _, err := os.Stat(pendingRecordPath(r, "retired")); err != nil {
		t.Fatalf("armed record must persist for the next tick: %v", err)
	}

	// Pass 2: executes and consumes.
	r.processPendingPrunes(nil)
	if _, err := os.Stat(liveFile); !os.IsNotExist(err) {
		t.Errorf("armed record must prune the leaver's file, stat err = %v", err)
	}
	if _, err := os.Stat(pendingRecordPath(r, "retired")); !os.IsNotExist(err) {
		t.Errorf("executed record must be consumed, stat err = %v", err)
	}
}

// A module that reappears in desired before its prune fires was an
// assignment flap — the record is dropped and the live root untouched.
func TestPendingPrune_ReappearedModuleCancels(t *testing.T) {
	r, layout, _ := leaverFixture(t)
	liveFile := filepath.Join(layout.Root, "usr/bin/left-behind")
	hpWriteFile(t, layout.Root, "usr/bin/left-behind", "still wanted")
	back := mount.Module{ID: "retired", Digest: "sha256:back"}
	hpWriteFile(t, layout.ModuleMountPath(back.Digest), "usr/bin/left-behind", "still wanted")

	r.writePendingPrunes([]pendingPruneRecord{{
		ModuleID: "retired", Digest: "sha256:gone",
		Files: []string{"/usr/bin/left-behind"},
	}})
	r.processPendingPrunes(mount.ModuleStack{back}) // would normally arm
	r.processPendingPrunes(mount.ModuleStack{back}) // would normally execute

	if got := readTestFile(t, liveFile); got != "still wanted" {
		t.Errorf("live file = %q — a reappeared module's files must never be pruned", got)
	}
	if _, err := os.Stat(pendingRecordPath(r, "retired")); !os.IsNotExist(err) {
		t.Errorf("record for a reappeared module must be dropped, stat err = %v", err)
	}
}

// A leaver's contested path is REWRITTEN from the surviving provider, not
// removed — the same resolution version-bump prunes use.
func TestPendingPrune_ContestedPathRestoredFromSurvivor(t *testing.T) {
	r, layout, signals := leaverFixture(t)
	hpWriteFile(t, layout.Root, "usr/bin/shared", "leaver's copy")
	survivor := mount.Module{ID: "keeper", Digest: "sha256:keeper", Priority: 50}
	hpWriteFile(t, layout.ModuleMountPath(survivor.Digest), "usr/bin/shared", "survivor's copy")

	r.writePendingPrunes([]pendingPruneRecord{{
		ModuleID: "retired", Digest: "sha256:gone",
		Files: []string{"/usr/bin/shared"},
	}})
	r.processPendingPrunes(mount.ModuleStack{survivor}) // arm
	r.processPendingPrunes(mount.ModuleStack{survivor}) // execute

	if got := readTestFile(t, filepath.Join(layout.Root, "usr/bin/shared")); got != "survivor's copy" {
		t.Errorf("contested path = %q, want the survivor's content", got)
	}
	found := false
	for _, s := range *signals {
		if strings.Contains(s, "hot_prune_contested") {
			found = true
		}
	}
	if !found {
		t.Errorf("a restored path must surface the contested-composition smell, got %v", *signals)
	}
}

// Protected paths carried on the record survive the deferred prune.
func TestPendingPrune_ProtectedPathsSurvive(t *testing.T) {
	r, layout, _ := leaverFixture(t)
	hpWriteFile(t, layout.Root, "etc/keep/config.yml", "operator data")

	r.writePendingPrunes([]pendingPruneRecord{{
		ModuleID: "retired", Digest: "sha256:gone",
		Files:     []string{"/etc/keep/config.yml"},
		Protected: []string{"/etc/keep/**"},
	}})
	r.processPendingPrunes(nil)
	r.processPendingPrunes(nil)

	if got := readTestFile(t, filepath.Join(layout.Root, "etc/keep/config.yml")); got != "operator data" {
		t.Errorf("protected path = %q — protected_spec must survive into the deferred prune", got)
	}
}

// A desired module whose tree is not mounted defers the WHOLE pass:
// resolving against a partial stack would misread contested as sole-owned.
func TestPendingPrune_MissingSurvivingLayerDefersPass(t *testing.T) {
	r, layout, _ := leaverFixture(t)
	liveFile := filepath.Join(layout.Root, "usr/bin/left-behind")
	hpWriteFile(t, layout.Root, "usr/bin/left-behind", "stale")
	unmounted := mount.Module{ID: "keeper", Digest: "sha256:not-mounted"}

	r.writePendingPrunes([]pendingPruneRecord{{
		ModuleID: "retired", Digest: "sha256:gone",
		Files: []string{"/usr/bin/left-behind"},
		Armed: true,
	}})
	r.processPendingPrunes(mount.ModuleStack{unmounted})

	if _, err := os.Stat(liveFile); err != nil {
		t.Errorf("pass must defer while a desired layer is unmounted; live file err = %v", err)
	}
	if _, err := os.Stat(pendingRecordPath(r, "retired")); err != nil {
		t.Errorf("record must survive a deferred pass: %v", err)
	}
}
