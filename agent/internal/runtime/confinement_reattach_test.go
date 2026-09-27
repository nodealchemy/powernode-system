package runtime

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/lifecycle"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/security"
	"github.com/nodealchemy/powernode-system/agent/internal/verify"
)

// W1 (IMP-caef5c00d63f round W, HIGH): a live reconcile that changes ONLY a
// module's security policy (SAME digest — a manifest-only capabilities-list
// edit, exactly TestSecurityFailClosed_ReattachPathRefusalReachesSecurityFailClosedUnits'
// own fixture shape, which drives m1 into RunOnce's toReattach loop, not
// toAttach) previously did NO daemon-reload and NO restart at all: the
// drop-in write happens in attachModule/applyModuleSecurityPolicy, entirely
// invisible to AttachServicesModeOpts' own anyWritten/RestartChanged
// tracking (unit-BODY writes only). The reattach was still stamped
// converged. These two tests are the "before" of the "before/after" this
// round's own W1 fix must invert: a non-self-hosted node must actually
// RESTART the unit so the new confinement takes effect; a self-hosted node
// must reload without restarting and must NOT be stamped converged.
func newConfinementReattachReconciler(t *testing.T) (r *Reconciler, client *stubModulesClient, runner *mount.RecorderRunner, statePath, manifestRoot, dropIns string) {
	t.Helper()
	tmpRoot := t.TempDir()
	statePath = filepath.Join(tmpRoot, "state.json")
	manifestRoot = filepath.Join(tmpRoot, "manifests")
	dropIns = t.TempDir()
	t.Cleanup(security.SetSystemdDropInRootForTest(dropIns))
	t.Setenv("POWERNODE_LIFECYCLE_UNIT_DIR", t.TempDir())

	client = &stubModulesClient{responses: map[string]string{
		"/api/v1/system/node_api/modules": `{
			"success": true,
			"data": {"modules": [
				{"id":"m1", "name":"app-mod", "priority":100, "effective_priority":100, "has_data_file":true}
			]}
		}`,
		"/api/v1/system/node_api/modules/m1": manifestFixtureWithCaps("abc123", []string{"CAP_CHOWN"}),
	}}
	layout := mount.DefaultLayout()
	layout.Root = tmpRoot
	layout = layout.Resolve()
	runner = &mount.RecorderRunner{}
	var err error
	r, err = NewReconciler(ReconcilerConfig{
		ModulesClient:  client,
		ManifestClient: client,
		ManifestRoot:   manifestRoot,
		Puller:         &stubPuller{cacheDir: layout.ModulesCacheRoot},
		Verifier:       verify.AlwaysOK{},
		MountRunner:    runner,
		Layout:         layout,
		StatePath:      statePath,
	})
	if err != nil {
		t.Fatalf("NewReconciler: %v", err)
	}
	return r, client, runner, statePath, manifestRoot, dropIns
}

func TestReconcile_ConfinementOnlyChangeRestartsActiveUnitOnLiveReattach(t *testing.T) {
	r, client, runner, _, manifestRoot, _ := newConfinementReattachReconciler(t)
	unit := lifecycle.UnitName("m1", "app")

	// TICK 1: clean attach.
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 1: %v", err)
	}

	// TICK 2: SAME digest, capabilities list changes (attachStamp moves,
	// m1 goes into toReattach). The unit is ACTIVE and its BODY does not
	// change at all (services: block is identical) — only the drop-in does.
	if err := os.RemoveAll(filepath.Join(manifestRoot, "m1")); err != nil {
		t.Fatal(err)
	}
	client.responses["/api/v1/system/node_api/modules/m1"] = manifestFixtureWithCaps("abc123", []string{"CAP_CHOWN", "CAP_NET_ADMIN"})
	runner.StubOutput = map[string][]byte{"systemctl is-active " + unit: []byte("active\n")}
	preInvocations := len(runner.Invocations)

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 2: %v", err)
	}

	tick2 := runner.Invocations[preInvocations:]
	if !hasSystemctlOp(tick2, "restart", unit) {
		t.Errorf("W1 REGRESSION: a confinement-only change (capabilities list, no body change) on an ACTIVE unit must be restarted on a non-self-hosted node, got invocations=%v", tick2)
	}
}

func TestReconcile_ConfinementOnlyChangeSelfHostedStaysUnconvergedAndPending(t *testing.T) {
	r, client, runner, statePath, manifestRoot, _ := newConfinementReattachReconciler(t)
	unit := lifecycle.UnitName("m1", "app")
	var onErrors []string
	r.cfg.OnError = func(stage string, err error) { onErrors = append(onErrors, stage+": "+err.Error()) }

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 1: %v", err)
	}
	r.selfHostLatched = true

	if err := os.RemoveAll(filepath.Join(manifestRoot, "m1")); err != nil {
		t.Fatal(err)
	}
	client.responses["/api/v1/system/node_api/modules/m1"] = manifestFixtureWithCaps("abc123", []string{"CAP_CHOWN", "CAP_NET_ADMIN"})
	runner.StubOutput = map[string][]byte{"systemctl is-active " + unit: []byte("active\n")}
	onErrors = nil
	preInvocations := len(runner.Invocations)

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 2 (self-hosted): %v", err)
	}

	tick2 := runner.Invocations[preInvocations:]
	if hasSystemctlOp(tick2, "restart", unit) {
		t.Errorf("W1 REGRESSION (rule 1): a self-hosted node must NEVER restart on a confinement-only change, got invocations=%v", tick2)
	}
	if !convergenceFailuresContain(onErrors, "reconciler:confinement_pending_restart") || !convergenceFailuresContain(onErrors, unit) {
		t.Errorf("W1 REGRESSION: expected reconciler:confinement_pending_restart naming %s, got onErrors=%v", unit, onErrors)
	}

	st, err := mount.LoadState(statePath)
	if err != nil {
		t.Fatalf("LoadState: %v", err)
	}
	// The stamp already written earlier in this SAME tick (before
	// attachModuleServices ran) must have been UNDONE — a self-hosted
	// confinement-pending-restart module is NOT converged, so it must stay
	// queued for a retry on the very next tick.
	if _, stamped := st.LastAttachedManifestHashes["m1"]; stamped {
		t.Errorf("W1 REGRESSION: expected m1's attach stamp to be cleared while a confinement restart is pending — got %q", st.LastAttachedManifestHashes["m1"])
	}
}

// TestReconcile_NewBootCompositionRewritesADivergentDropInAndW1ThenApplies is
// W2 (IMP-caef5c00d63f round W, HIGH): a stamp that matches (NO manifest
// change at all — same capabilities list, same digest) but whose on-disk
// drop-in has DIVERGED (simulated here as an older initramfs agent's own
// compose overwriting it with different content) must get rewritten on the
// first live reconcile tick of a NEW boot composition, and W1's own
// changed-units plumbing must then apply it to the running unit.
func TestReconcile_NewBootCompositionRewritesADivergentDropInAndW1ThenApplies(t *testing.T) {
	r, _, runner, statePath, _, dropIns := newConfinementReattachReconciler(t)
	unit := lifecycle.UnitName("m1", "app")

	// Pin this test to a NATIVE (pivot) root and a controllable boot
	// breadcrumb — confinementRecheckKey (confinement_recheck.go) declines
	// to force anything at all on a chroot/cloud_init node or with no
	// usable breadcrumb, exactly like rebaseStateAgainstBoot's own identical
	// checks.
	origMode, origChecked := pivotAwareRootMode, pivotAwareRootModeChecked
	pivotAwareRootMode = func() lifecycle.RootMode { return lifecycle.RootModeNative }
	pivotAwareRootModeChecked = func() (lifecycle.RootMode, error) { return lifecycle.RootModeNative, nil }
	origBoot := currentBootID
	const bootA, bootB = "boot-a", "boot-b"
	boot := bootA
	currentBootID = func() string { return boot }
	t.Cleanup(func() {
		pivotAwareRootMode, pivotAwareRootModeChecked = origMode, origChecked
		currentBootID = origBoot
	})
	breadcrumbPath := filepath.Join(t.TempDir(), "boot-composed.json")
	t.Cleanup(SetBootBreadcrumbPathForTest(breadcrumbPath))
	writeBreadcrumb := func(bootID string, at time.Time) {
		t.Helper()
		if err := WriteBreadcrumb(breadcrumbPath, &BootComposedBreadcrumb{BootID: bootID, ComposedAt: at}); err != nil {
			t.Fatalf("WriteBreadcrumb: %v", err)
		}
	}
	composedAt := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	writeBreadcrumb(bootA, composedAt)

	// TICK 1: clean attach under boot A. Writes the correct drop-in and
	// marks ConfinementReconfirmedAgainst for boot A's own composition key
	// (nothing to force yet — m1 is a fresh attach this tick).
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 1 (boot A): %v", err)
	}
	dropInPath := filepath.Join(dropIns, unit+".d", "capabilities.conf")
	original, err := os.ReadFile(dropInPath)
	if err != nil {
		t.Fatalf("precondition: expected a drop-in after tick 1: %v", err)
	}

	// SIMULATE: an older initramfs agent's own compose step (or a manual
	// edit) overwrites the drop-in with DIFFERENT content — the manifest
	// itself (capabilities list) is UNCHANGED, so the attach stamp still
	// matches and the ordinary reattach gate alone would never notice.
	stale := "# stale drop-in from an older compose\n[Service]\nCapabilityBoundingSet=\n"
	if err := os.WriteFile(dropInPath, []byte(stale), 0o644); err != nil {
		t.Fatal(err)
	}

	// NEW BOOT: a DIFFERENT composition (boot B, a later ComposedAt) — same
	// manifest, same digest, same capabilities list, nothing an ordinary
	// stamp-diff would ever catch.
	boot = bootB
	writeBreadcrumb(bootB, composedAt.Add(time.Hour))
	runner.StubOutput = map[string][]byte{"systemctl is-active " + unit: []byte("active\n")}
	preInvocations := len(runner.Invocations)

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 2 (boot B, divergent on-disk drop-in): %v", err)
	}

	rewritten, err := os.ReadFile(dropInPath)
	if err != nil {
		t.Fatalf("read drop-in after tick 2: %v", err)
	}
	if string(rewritten) == stale {
		t.Fatalf("W2 REGRESSION: expected the divergent drop-in to be rewritten on the first tick of a NEW boot composition, still reads the stale content: %s", rewritten)
	}
	if string(rewritten) != string(original) {
		t.Errorf("expected the rewritten drop-in to match the manifest's own (unchanged) policy, got %s want %s", rewritten, original)
	}

	// W1: the rewrite is a genuine confinement change (stale -> correct) on
	// an ACTIVE unit, on a non-self-hosted node — must be restarted.
	tick2 := runner.Invocations[preInvocations:]
	if !hasSystemctlOp(tick2, "restart", unit) {
		t.Errorf("W1/W2 REGRESSION: expected the rewritten confinement to restart the active unit, got invocations=%v", tick2)
	}

	st, err := mount.LoadState(statePath)
	if err != nil {
		t.Fatalf("LoadState: %v", err)
	}
	if st.ConfinementReconfirmedAgainst == "" {
		t.Error("expected ConfinementReconfirmedAgainst to be set after a tick that determined the current composition")
	}

	// ONCE PER COMPOSITION: a THIRD tick, still under boot B, with the
	// drop-in manually corrupted again but the composition UNCHANGED, must
	// NOT force a rewrite this time — the recheck already ran for boot B.
	if err := os.WriteFile(dropInPath, []byte(stale), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 3 (same boot B composition): %v", err)
	}
	stillStale, err := os.ReadFile(dropInPath)
	if err != nil {
		t.Fatalf("read drop-in after tick 3: %v", err)
	}
	if string(stillStale) != stale {
		t.Errorf("W2: expected NO forced rewrite on a later tick of the SAME already-reconfirmed composition, got %s", stillStale)
	}
}

// TestConfinementRecheckKey_DeclinesOnChrootOrMissingBreadcrumb documents
// confinementRecheckKey's own fail-closed-to-"decline" behavior — errors.New
// is imported here only to build the sentinel error the chroot test forces
// pivotAwareRootModeChecked to answer, matching rebaseStateAgainstBoot's own
// established test pattern (state_rebase_test.go) for the identical checks.
func TestConfinementRecheckKey_DeclinesOnChrootOrMissingBreadcrumb(t *testing.T) {
	r, _, _, _, _, _ := newConfinementReattachReconciler(t)

	origMode, origChecked := pivotAwareRootMode, pivotAwareRootModeChecked
	t.Cleanup(func() { pivotAwareRootMode, pivotAwareRootModeChecked = origMode, origChecked })
	breadcrumbPath := filepath.Join(t.TempDir(), "boot-composed.json")
	t.Cleanup(SetBootBreadcrumbPathForTest(breadcrumbPath))

	pivotAwareRootModeChecked = func() (lifecycle.RootMode, error) { return lifecycle.RootModeChroot, nil }
	if _, ok := r.confinementRecheckKey(); ok {
		t.Error("expected a chroot node (no boot-fixed root to have drifted) to decline")
	}

	pivotAwareRootModeChecked = func() (lifecycle.RootMode, error) { return lifecycle.RootModeNative, nil }
	if _, ok := r.confinementRecheckKey(); ok {
		t.Error("expected a missing boot breadcrumb to decline")
	}

	pivotAwareRootModeChecked = func() (lifecycle.RootMode, error) {
		return lifecycle.RootModeNative, errors.New("statfs /: input/output error")
	}
	if _, ok := r.confinementRecheckKey(); ok {
		t.Error("expected a root-mode probe error to decline")
	}
}
