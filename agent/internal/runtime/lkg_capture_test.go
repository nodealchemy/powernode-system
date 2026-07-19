package runtime

import (
	"context"
	"os"
	"sync"
	"testing"
	"time"
)

// scriptedProber returns a scripted sequence of health results; the last entry
// repeats. Thread-safe for the capturer's single-goroutine use.
type scriptedProber struct {
	mu      sync.Mutex
	results []bool
	idx     int
}

func (p *scriptedProber) Healthy(ctx context.Context) (bool, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	i := p.idx
	if i >= len(p.results) {
		i = len(p.results) - 1
	}
	p.idx++
	return p.results[i], nil
}

func writeTestBreadcrumb(t *testing.T, path string, fromLKG bool, digest string) {
	t.Helper()
	bc := &BootComposedBreadcrumb{
		ComposedAt: time.Now().UTC(),
		FromLKG:    fromLKG,
		Source:     "https://dev.example.test",
		Hostname:   "ops-hub",
		Modules: []LKGModule{
			{ID: "hub-backend", Name: "hub-backend", EffectivePriority: 100, HasDataFile: true, Digest: digest, Manifest: []byte(`{"id":"hub-backend"}`)},
		},
	}
	if err := WriteBreadcrumb(path, bc); err != nil {
		t.Fatal(err)
	}
}

func TestLKGCapturer_PromotesBreadcrumbAfterAppHealthy(t *testing.T) {
	dir := t.TempDir()
	bcPath := dir + "/boot-composed.json"
	lkgPath := dir + "/assignment-lkg.json"
	writeTestBreadcrumb(t, bcPath, false, "sha256:good")

	c := &LKGCapturer{
		Prober:              &scriptedProber{results: []bool{true}},
		BreadcrumbPath:      bcPath,
		LKGPath:             lkgPath,
		RequiredConsecutive: 2,
		PollInterval:        time.Millisecond,
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := c.Run(ctx); err != nil {
		t.Fatalf("Run: %v", err)
	}

	lkg, err := LoadBootLKG(lkgPath)
	if err != nil {
		t.Fatalf("expected a promoted LKG: %v", err)
	}
	if !lkg.Frozen {
		t.Fatal("promoted LKG must be frozen")
	}
	if len(lkg.Modules) != 1 || lkg.Modules[0].Digest != "sha256:good" {
		t.Fatalf("LKG did not capture the breadcrumb set: %+v", lkg.Modules)
	}
	if lkg.Checksum == "" {
		t.Fatal("promoted LKG must carry a checksum")
	}
}

func TestLKGCapturer_UnhealthyNeverPromotes(t *testing.T) {
	dir := t.TempDir()
	bcPath := dir + "/boot-composed.json"
	lkgPath := dir + "/assignment-lkg.json"
	writeTestBreadcrumb(t, bcPath, false, "sha256:good")

	c := &LKGCapturer{
		Prober:              &scriptedProber{results: []bool{false}},
		BreadcrumbPath:      bcPath,
		LKGPath:             lkgPath,
		RequiredConsecutive: 2,
		PollInterval:        time.Millisecond,
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Millisecond)
	defer cancel()
	_ = c.Run(ctx)

	if _, err := LoadBootLKG(lkgPath); err == nil {
		t.Fatal("app never healthy → no LKG must be promoted")
	}
}

func TestLKGCapturer_RequiresConsecutiveHealthy(t *testing.T) {
	dir := t.TempDir()
	bcPath := dir + "/boot-composed.json"
	lkgPath := dir + "/assignment-lkg.json"
	writeTestBreadcrumb(t, bcPath, false, "sha256:good")

	// healthy, UNhealthy (resets), healthy, healthy → promotes only on the two
	// trailing consecutive trues.
	c := &LKGCapturer{
		Prober:              &scriptedProber{results: []bool{true, false, true, true}},
		BreadcrumbPath:      bcPath,
		LKGPath:             lkgPath,
		RequiredConsecutive: 2,
		PollInterval:        time.Millisecond,
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := c.Run(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadBootLKG(lkgPath); err != nil {
		t.Fatalf("expected promotion after two trailing consecutive healthy probes: %v", err)
	}
}

func TestLKGCapturer_SkipsWhenFrozenExists(t *testing.T) {
	dir := t.TempDir()
	cacheDir := dir + "/cache"
	bcPath := dir + "/boot-composed.json"
	lkgPath := dir + "/assignment-lkg.json"

	// Pre-existing frozen LKG (captured on an earlier boot) = "G0".
	g0 := validLKG(t, cacheDir)
	if err := WriteBootLKG(lkgPath, g0); err != nil {
		t.Fatal(err)
	}
	// A DIFFERENT breadcrumb this boot.
	writeTestBreadcrumb(t, bcPath, false, "sha256:different")

	c := &LKGCapturer{
		Prober:         &scriptedProber{results: []bool{true}},
		BreadcrumbPath: bcPath,
		LKGPath:        lkgPath,
		PollInterval:   time.Millisecond,
	}
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	if err := c.Run(ctx); err != nil {
		t.Fatal(err)
	}
	after, _ := LoadBootLKG(lkgPath)
	if after.Modules[0].Digest != "sha256:abc123" {
		t.Fatalf("frozen LKG must not be overwritten; got %s", after.Modules[0].Digest)
	}
}

// TestLKGCapturer_Correction1_NeverPromotesPostBootDrift is the load-bearing
// regression for correction-#1 (hot-mount != code-active). A module the
// reconciler hot-mounts post-boot (whose new code runs only after a FUTURE
// reboot) must NEVER become the last-known-good, or the next cold boot would
// compose an unproven set and brick. Here: this boot composed + app-health-
// confirmed the GOOD set G0; the capturer freezes G0. We then simulate a
// post-boot hot-reconcile to a would-fail-cold-boot set B1 (mutating BOTH the
// reconcile state.json AND, adversarially, the breadcrumb) and assert the LKG
// still holds G0 — the capturer promotes the boot-composed breadcrumb once,
// then freezes, and never consults reconcile state.
func TestLKGCapturer_Correction1_NeverPromotesPostBootDrift(t *testing.T) {
	dir := t.TempDir()
	bcPath := dir + "/boot-composed.json"
	lkgPath := dir + "/assignment-lkg.json"
	statePath := dir + "/state.json"

	// Boot composed G0 → capturer promotes it after app-health.
	writeTestBreadcrumb(t, bcPath, false, "sha256:G0-good")
	c := &LKGCapturer{
		Prober:              &scriptedProber{results: []bool{true}},
		BreadcrumbPath:      bcPath,
		LKGPath:             lkgPath,
		RequiredConsecutive: 1,
		PollInterval:        time.Millisecond,
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := c.Run(ctx); err != nil {
		t.Fatal(err)
	}
	if lkg, _ := LoadBootLKG(lkgPath); lkg == nil || lkg.Modules[0].Digest != "sha256:G0-good" {
		t.Fatalf("precondition: LKG should be G0, got %+v", lkg)
	}

	// Post-boot hot-reconcile to a bad set B1: the reconciler would rewrite
	// state.json; adversarially also rewrite the breadcrumb.
	if err := mountSaveStateBad(statePath); err != nil {
		t.Fatal(err)
	}
	writeTestBreadcrumb(t, bcPath, false, "sha256:B1-bad-cold-boot")

	// Re-run the capturer (as if a new tick / a fresh goroutine): frozen LKG
	// exists → it must NOT re-promote.
	c2 := &LKGCapturer{
		Prober:              &scriptedProber{results: []bool{true}},
		BreadcrumbPath:      bcPath,
		LKGPath:             lkgPath,
		RequiredConsecutive: 1,
		PollInterval:        time.Millisecond,
	}
	ctx2, cancel2 := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel2()
	if err := c2.Run(ctx2); err != nil {
		t.Fatal(err)
	}

	final, err := LoadBootLKG(lkgPath)
	if err != nil {
		t.Fatal(err)
	}
	if final.Modules[0].Digest != "sha256:G0-good" {
		t.Fatalf("correction-#1 violated: LKG advanced to a post-boot hot-reconciled set %q (must stay G0-good)", final.Modules[0].Digest)
	}
}

func TestLKGCapturer_FromLKGBoot_DoesNotRepromote(t *testing.T) {
	dir := t.TempDir()
	lkgPath := dir + "/assignment-lkg.json"
	// This boot itself fell back to the LKG (FromLKG=true) → promote() must no-op.
	bc := &BootComposedBreadcrumb{FromLKG: true, Modules: []LKGModule{{ID: "hub-backend", HasDataFile: true, Digest: "sha256:whatever"}}}
	c := &LKGCapturer{LKGPath: lkgPath}
	if err := c.promote(bc); err != nil {
		t.Fatalf("promote from a FromLKG breadcrumb should be a no-op, got %v", err)
	}
	if _, err := LoadBootLKG(lkgPath); err == nil {
		t.Fatal("a FromLKG breadcrumb must not produce a new LKG")
	}
}

func TestLKGCapturer_ResolveGate_BreadcrumbOverridesDefaults(t *testing.T) {
	// SiteSetting-delivered gate config rode in on the breadcrumb snapshot.
	bc := &BootComposedBreadcrumb{
		AppHealth: AppHealthCfg{URL: "https://127.0.0.1/api/v1/system/health", RequiredConsecutive: 5, PollIntervalSeconds: 2},
	}
	c := &LKGCapturer{DefaultAppHealthURL: "https://127.0.0.1/up", RequiredConsecutive: 1, PollInterval: 15 * time.Second}
	prober, required, interval := c.resolveGate(bc)
	if required != 5 {
		t.Fatalf("required: got %d want 5 (breadcrumb override)", required)
	}
	if interval != 2*time.Second {
		t.Fatalf("interval: got %s want 2s (breadcrumb override)", interval)
	}
	hp, ok := prober.(*HTTPHealthProber)
	if !ok || hp.URL != "https://127.0.0.1/api/v1/system/health" {
		t.Fatalf("prober URL not taken from breadcrumb: %+v", prober)
	}
	if hp.Client == nil {
		t.Fatal("resolveGate must build the health client once (reused across probes)")
	}
}

func TestLKGCapturer_ResolveGate_DefaultsWhenBreadcrumbHasNoGateConfig(t *testing.T) {
	c := &LKGCapturer{DefaultAppHealthURL: "https://127.0.0.1/up", RequiredConsecutive: 2, PollInterval: 5 * time.Second}
	prober, required, interval := c.resolveGate(&BootComposedBreadcrumb{})
	if required != 2 || interval != 5*time.Second {
		t.Fatalf("compile defaults not used: required=%d interval=%s", required, interval)
	}
	if hp := prober.(*HTTPHealthProber); hp.URL != "https://127.0.0.1/up" {
		t.Fatalf("default URL not used: %s", hp.URL)
	}
}

func TestLKGCapturer_CaptureTimeBlobValidation_FailsOnMissingBlob(t *testing.T) {
	dir := t.TempDir()
	cacheDir := dir + "/cache"
	lkgPath := dir + "/lkg.json"
	// Breadcrumb has a data module whose blob was never staged in the cache.
	bc := &BootComposedBreadcrumb{
		Modules: []LKGModule{{ID: "m1", HasDataFile: true, Digest: "sha256:missing", Manifest: []byte(`{"id":"m1"}`)}},
	}
	c := &LKGCapturer{LKGPath: lkgPath, CachePath: testCachePath(cacheDir)}
	if err := c.promote(bc); err == nil {
		t.Fatal("promote must fail-loud when a breadcrumb data-module blob is absent")
	}
	if _, err := LoadBootLKG(lkgPath); err == nil {
		t.Fatal("no LKG may be written when capture-time blob validation fails")
	}
}

func TestLKGCapturer_Promote_CarriesAppHealthAndValidatesPresentBlob(t *testing.T) {
	dir := t.TempDir()
	cacheDir := dir + "/cache"
	lkgPath := dir + "/lkg.json"
	stageBlob(t, cacheDir, "sha256:present")
	bc := &BootComposedBreadcrumb{
		AppHealth: AppHealthCfg{URL: "https://127.0.0.1/up", RequiredConsecutive: 3},
		Modules:   []LKGModule{{ID: "m1", HasDataFile: true, Digest: "sha256:present", Manifest: []byte(`{"id":"m1"}`)}},
	}
	c := &LKGCapturer{LKGPath: lkgPath, CachePath: testCachePath(cacheDir)}
	if err := c.promote(bc); err != nil {
		t.Fatalf("promote with present blob should succeed: %v", err)
	}
	lkg, err := LoadBootLKG(lkgPath)
	if err != nil {
		t.Fatal(err)
	}
	if lkg.AppHealth.RequiredConsecutive != 3 || lkg.AppHealth.URL != "https://127.0.0.1/up" {
		t.Fatalf("LKG must carry the app-health gate config for the record: %+v", lkg.AppHealth)
	}
}

// mutatingProber runs onFirstCall the first time Healthy is invoked (used to
// rewrite the on-disk breadcrumb mid-gate), then always reports healthy.
type mutatingProber struct {
	mu          sync.Mutex
	calls       int
	onFirstCall func()
}

func (p *mutatingProber) Healthy(ctx context.Context) (bool, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.calls++
	if p.calls == 1 && p.onFirstCall != nil {
		p.onFirstCall()
	}
	return true, nil
}

// HIGH-2: the capturer snapshots the breadcrumb at Run() ENTRY and promotes that
// in-memory copy. Even if the on-disk breadcrumb is rewritten DURING the gate
// window (before the LKG freezes), the ORIGINAL set must freeze — otherwise a
// future post-boot breadcrumb writer would silently re-open the correction-#1
// poison across the pre-freeze window.
func TestLKGCapturer_HIGH2_PromotesEntrySnapshotNotRewrittenBreadcrumb(t *testing.T) {
	dir := t.TempDir()
	cacheDir := dir + "/cache"
	bcPath := dir + "/bc.json"
	lkgPath := dir + "/lkg.json"
	stageBlob(t, cacheDir, "sha256:G0-good")
	if err := WriteBreadcrumb(bcPath, &BootComposedBreadcrumb{
		Modules: []LKGModule{{ID: "m1", HasDataFile: true, Digest: "sha256:G0-good", Manifest: []byte(`{"id":"m1"}`)}},
	}); err != nil {
		t.Fatal(err)
	}
	prober := &mutatingProber{onFirstCall: func() {
		// Something rewrites the on-disk breadcrumb to a bad set mid-gate.
		_ = WriteBreadcrumb(bcPath, &BootComposedBreadcrumb{
			Modules: []LKGModule{{ID: "m1", HasDataFile: true, Digest: "sha256:B1-bad", Manifest: []byte(`{"id":"m1"}`)}},
		})
	}}
	c := &LKGCapturer{
		Prober: prober, BreadcrumbPath: bcPath, LKGPath: lkgPath, CachePath: testCachePath(cacheDir),
		RequiredConsecutive: 2, PollInterval: time.Millisecond,
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := c.Run(ctx); err != nil {
		t.Fatal(err)
	}
	lkg, err := LoadBootLKG(lkgPath)
	if err != nil {
		t.Fatal(err)
	}
	if lkg.Modules[0].Digest != "sha256:G0-good" {
		t.Fatalf("HIGH-2 violated: froze the mid-gate rewritten breadcrumb %q instead of the entry snapshot G0", lkg.Modules[0].Digest)
	}
}

func TestLKGCapturer_NoBreadcrumb_GracefulNoPromote(t *testing.T) {
	dir := t.TempDir()
	c := &LKGCapturer{
		Prober: &scriptedProber{results: []bool{true}}, BreadcrumbPath: dir + "/absent.json", LKGPath: dir + "/lkg.json",
		RequiredConsecutive: 1, PollInterval: time.Millisecond,
	}
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	if err := c.Run(ctx); err != nil {
		t.Fatalf("Run must not error when the breadcrumb is absent (compose wrote none): %v", err)
	}
	if _, err := LoadBootLKG(dir + "/lkg.json"); err == nil {
		t.Fatal("no breadcrumb → the gate must not run and no LKG may be written")
	}
}

// MED-4: a boot that composed an INCOMPLETE assigned set must never freeze an LKG.
func TestLKGCapturer_IncompleteBoot_SkipsCapture(t *testing.T) {
	dir := t.TempDir()
	bcPath := dir + "/bc.json"
	lkgPath := dir + "/lkg.json"
	if err := WriteBreadcrumb(bcPath, &BootComposedBreadcrumb{
		Incomplete: true,
		Modules:    []LKGModule{{ID: "m1", HasDataFile: true, Digest: "sha256:x", Manifest: []byte(`{"id":"m1"}`)}},
	}); err != nil {
		t.Fatal(err)
	}
	c := &LKGCapturer{
		Prober: &scriptedProber{results: []bool{true}}, BreadcrumbPath: bcPath, LKGPath: lkgPath,
		RequiredConsecutive: 1, PollInterval: time.Millisecond,
	}
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	if err := c.Run(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadBootLKG(lkgPath); err == nil {
		t.Fatal("an incomplete boot must not freeze an LKG")
	}
}

// mountSaveStateBad writes a state.json representing a post-boot hot-reconcile
// to a set the capturer must never promote. Its contents are irrelevant to the
// capturer (which never reads it) — its mere presence models the drift.
func mountSaveStateBad(path string) error {
	return os.WriteFile(path, []byte(`{"attached_modules":[{"id":"hub-backend","digest":"sha256:B1-bad-cold-boot","priority":100}]}`), 0o644)
}
