package runtime

import (
	"context"
	"encoding/json"
	"path/filepath"
	"testing"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/lifecycle"
	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// Round Y (IMP-caef5c00d63f, N4/N5 from the round-X confirm review): unit
// tests for reconfirmConfinementIfNeeded's own gate and per-module keying,
// called DIRECTLY (not through RunOnce) — the design's own test plan
// (section 6) separates these from the RunOnce-driven "reviewer probes",
// and RunOnce's own upgrade/revert machinery resolves PendingDigest before
// the recheck ever runs on every path reachable through it, which would
// make a PendingDigest-still-set-when-the-recheck-runs case unconstructable
// end-to-end. Testing the function in isolation is the correct scope, not
// a shortcut.

// parseManifestEnvelope unmarshals the SAME {"data": {...}} envelope shape
// every ManifestClient fixture in this package already returns over HTTP
// (manifest.FetchModuleManifest's own decode) into a real *manifest.Manifest,
// so these tests build fixtures with the exact same proven JSON shape
// (manifestFixtureWithCaps, manifestFixturePrivileged) instead of hand
// constructing the Config map layout a second, divergence-prone way.
func parseManifestEnvelope(t *testing.T, body string) *manifest.Manifest {
	t.Helper()
	var env struct {
		Data *manifest.Manifest `json:"data"`
	}
	if err := json.Unmarshal([]byte(body), &env); err != nil {
		t.Fatalf("parseManifestEnvelope: %v", err)
	}
	if env.Data == nil {
		t.Fatal("parseManifestEnvelope: empty data envelope")
	}
	return env.Data
}

// armConfinementRecheckBoot sets the same three seams confinementRecheckKey
// checks (pivotAwareRootModeChecked, the boot breadcrumb, currentBootID) so
// a direct reconfirmConfinementIfNeeded call sees a determinable, FRESH
// composition — mirrors TestReconfirmConfinement_ForcedFailureRetriesAndSkipsPull's
// own setup.
func armConfinementRecheckBoot(t *testing.T) {
	t.Helper()
	origMode, origChecked := pivotAwareRootMode, pivotAwareRootModeChecked
	pivotAwareRootMode = func() lifecycle.RootMode { return lifecycle.RootModeNative }
	pivotAwareRootModeChecked = func() (lifecycle.RootMode, error) { return lifecycle.RootModeNative, nil }
	origBoot := currentBootID
	const boot = "boot-a"
	currentBootID = func() string { return boot }
	t.Cleanup(func() {
		pivotAwareRootMode, pivotAwareRootModeChecked = origMode, origChecked
		currentBootID = origBoot
	})
	breadcrumbPath := filepath.Join(t.TempDir(), "boot-composed.json")
	t.Cleanup(SetBootBreadcrumbPathForTest(breadcrumbPath))
	if err := WriteBreadcrumb(breadcrumbPath, &BootComposedBreadcrumb{BootID: boot, ComposedAt: time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)}); err != nil {
		t.Fatalf("WriteBreadcrumb: %v", err)
	}
}

// TestReconfirmConfinement_N4Gate_SkipsPendingDigestModule pins N4: a module
// with an in-flight upgrade attempt (PendingDigest set) must not have its
// drop-ins re-decided against the STABLE digest's policy by this recheck —
// doing so would fight the upgrade rather than recheck anything (this
// file's own doc). The module's own ConfinementReconfirmed entry must stay
// unset so a LATER tick (once the upgrade resolves one way or the other)
// retries it.
func TestReconfirmConfinement_N4Gate_SkipsPendingDigestModule(t *testing.T) {
	r, _, _, _, _, _ := newConfinementReattachReconciler(t)
	armConfinementRecheckBoot(t)

	current := &mount.State{AttachedModules: []mount.Module{
		{ID: "m1", Digest: "abc123", Priority: 100, PendingDigest: "d2-inflight"},
	}}
	manifests := map[string]*manifest.Manifest{
		"m1": parseManifestEnvelope(t, manifestFixtureWithCaps("abc123", []string{"CAP_CHOWN"})),
	}

	var onErrors []string
	r.cfg.OnError = func(stage string, err error) { onErrors = append(onErrors, stage+": "+err.Error()) }

	r.reconfirmConfinementIfNeeded(context.Background(), current, manifests, false)

	if key := current.ConfinementReconfirmed["m1"]; key != "" {
		t.Errorf("N4 REGRESSION: expected m1 (PendingDigest set) to be skipped by the recheck, got ConfinementReconfirmed[m1]=%q", key)
	}
	if convergenceFailuresContain(onErrors, "confinement_recheck") {
		t.Errorf("N4 REGRESSION: expected the recheck to never even ATTEMPT a module with PendingDigest set, got onErrors=%v", onErrors)
	}
}

// TestReconfirmConfinement_N4Gate_SkipsDigestMismatchModule pins N4's other
// clause: a module whose attached digest no longer matches this tick's
// fetched manifest (the fetch loop resolved a newer digest that the
// attach/upgrade path has not committed yet) is skipped for the identical
// reason, independent of whether PendingDigest itself happens to be set.
func TestReconfirmConfinement_N4Gate_SkipsDigestMismatchModule(t *testing.T) {
	r, _, _, _, _, _ := newConfinementReattachReconciler(t)
	armConfinementRecheckBoot(t)

	current := &mount.State{AttachedModules: []mount.Module{
		{ID: "m1", Digest: "abc123", Priority: 100},
	}}
	manifests := map[string]*manifest.Manifest{
		// Freshly fetched content reports a DIFFERENT digest than what is
		// attached — the mid-transition shape N4 also guards.
		"m1": parseManifestEnvelope(t, manifestFixtureWithCaps("def456", []string{"CAP_CHOWN"})),
	}

	var onErrors []string
	r.cfg.OnError = func(stage string, err error) { onErrors = append(onErrors, stage+": "+err.Error()) }

	r.reconfirmConfinementIfNeeded(context.Background(), current, manifests, false)

	if key := current.ConfinementReconfirmed["m1"]; key != "" {
		t.Errorf("N4 REGRESSION: expected m1 (digest mismatch) to be skipped by the recheck, got ConfinementReconfirmed[m1]=%q", key)
	}
}

// TestReconfirmConfinement_N5_PerModuleIndependence pins N5: TWO modules on
// the SAME tick, one whose own policy decision fails (m2, privileged but
// unapproved) and one that succeeds cleanly (m1) — m1's own
// ConfinementReconfirmed entry must be set on THIS pass regardless of m2's
// failure, and m2's own entry must stay unset so only IT is retried next
// tick. Before round Y, a single shared allOK flag meant m2's failure alone
// would have kept m1's key unset too, re-forcing m1 through this stage on
// every tick for as long as m2 stayed broken.
func TestReconfirmConfinement_N5_PerModuleIndependence(t *testing.T) {
	r, _, _, _, _, _ := newConfinementReattachReconciler(t)
	armConfinementRecheckBoot(t)
	r.privilegedAllow = nil // m2 is privileged but nothing approves it

	current := &mount.State{AttachedModules: []mount.Module{
		{ID: "m1", Digest: "abc123", Priority: 100},
		{ID: "m2", Digest: "def456", Priority: 50},
	}}
	manifests := map[string]*manifest.Manifest{
		"m1": parseManifestEnvelope(t, manifestFixtureWithCaps("abc123", []string{"CAP_CHOWN"})),
		"m2": parseManifestEnvelope(t, manifestFixturePrivileged("def456")),
	}
	manifests["m2"].ID = "m2"

	var onErrors []string
	r.cfg.OnError = func(stage string, err error) { onErrors = append(onErrors, stage+": "+err.Error()) }

	r.reconfirmConfinementIfNeeded(context.Background(), current, manifests, false)

	if key := current.ConfinementReconfirmed["m1"]; key == "" {
		t.Error("N5 REGRESSION: expected m1's own recheck to succeed and be marked reconfirmed independently of m2's failure")
	}
	if key := current.ConfinementReconfirmed["m2"]; key != "" {
		t.Errorf("expected m2 (privileged, unapproved) to stay unreconfirmed, got %q", key)
	}
	if !convergenceFailuresContain(onErrors, "m2") {
		t.Errorf("expected m2's own policy-decision failure to be reported, got onErrors=%v", onErrors)
	}
}
