package runtime

// Demonstration test (adversarial review round 4): a FromPending boot that
// passes the health gate MUST advance the frozen LKG — that is the entire
// point of commit 7908699a.
import (
	"context"
	"encoding/json"
	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"os"
	"testing"
	"time"
)

type rpAlwaysHealthy struct{}

func (rpAlwaysHealthy) Healthy(context.Context) (bool, error) { return true, nil }

func TestCapturer_PromotesAFromPendingBootOverAFrozenLKG(t *testing.T) {
	dir := t.TempDir()
	lkgPath := dir + "/assignment-lkg.json"
	bcPath := dir + "/boot-composed.json"

	oldSet := []LKGModule{{ID: "m1", Name: "mod", HasDataFile: true,
		Digest: "sha256:old", Manifest: json.RawMessage(`{"id":"m1"}`)}}
	newSet := []LKGModule{{ID: "m1", Name: "mod", HasDataFile: true,
		Digest: "sha256:new", Manifest: json.RawMessage(`{"id":"m1"}`)}}

	// The node HAS a frozen LKG — the defining property of the self-hosted
	// control plane this feature was built for.
	if err := WriteBootLKG(lkgPath, &BootLKG{ConfirmedAt: time.Now().UTC(), Modules: oldSet}); err != nil {
		t.Fatal(err)
	}
	// This boot composed the STAGED set (TakePendingCompose already burned the
	// attempt) and recorded FromPending pre-pivot.
	if err := WriteBreadcrumb(bcPath, &BootComposedBreadcrumb{
		ComposedAt: time.Now().UTC(), FromPending: true,
		BootID:  CurrentBootID(), // exercise the MATCHING-id accept path, not the empty-id bypass
		Modules: newSet,
	}); err != nil {
		t.Fatal(err)
	}

	c := &LKGCapturer{
		Prober:              rpAlwaysHealthy{},
		BreadcrumbPath:      bcPath,
		LKGPath:             lkgPath,
		RequiredConsecutive: 1,
		PollInterval:        time.Millisecond,
	}
	if err := c.Run(context.Background()); err != nil {
		t.Fatalf("Run: %v", err)
	}

	got, err := LoadBootLKG(lkgPath)
	if err != nil {
		t.Fatal(err)
	}
	if got.Modules[0].Digest != "sha256:new" {
		t.Fatalf("frozen LKG did NOT advance after a healthy FromPending boot: "+
			"still %s — the promotion path is unreachable (Run's frozen-LKG early "+
			"return fires before the breadcrumb is ever read)", got.Modules[0].Digest)
	}
}

// P2 (round 4/5): the guard lives in stagePendingCompose, so the test must
// DRIVE stagePendingCompose. The previous version of this test wrote a file,
// reloaded it and asserted the field it had just written — it passed with the
// P2 fix reverted, i.e. it covered nothing.
func TestStagePendingCompose_SecondStageDoesNotResetAttempts(t *testing.T) {
	dir := t.TempDir()
	defer SetPendingComposePathForTest(dir + "/pending.json")()
	cache := dir + "/cache"
	if err := os.MkdirAll(cache, 0o755); err != nil {
		t.Fatal(err)
	}
	lay := mount.Layout{ModulesCacheRoot: cache}
	if err := os.WriteFile(lay.ModuleCachePath("sha256:new"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	bcPath := dir + "/boot-composed.json"
	// What THIS boot composed — deliberately different from desired below.
	if err := WriteBreadcrumb(bcPath, &BootComposedBreadcrumb{
		ComposedAt: time.Now().UTC(),
		Modules:    []LKGModule{{ID: "m1", HasDataFile: true, Digest: "sha256:old"}},
	}); err != nil {
		t.Fatal(err)
	}
	defer SetBootBreadcrumbPathForTest(bcPath)()

	r := &Reconciler{cfg: ReconcilerConfig{
		Layout:  mount.Layout{ModulesCacheRoot: cache},
		OnError: func(string, error) {},
	}}
	assigned := []AssignedModule{{ID: "m1", Name: "mod", HasDataFile: true}}
	manifests := map[string]*manifest.Manifest{"m1": {ID: "m1", Digest: "sha256:new"}}

	r.stagePendingCompose(assigned, manifests, AssignmentMeta{})
	first, err := LoadPendingCompose(PendingComposePath)
	if err != nil {
		t.Fatalf("first stage wrote nothing: %v", err)
	}
	if first.Attempts != 0 {
		t.Fatalf("fresh stage should start at 0 attempts, got %d", first.Attempts)
	}

	// A boot consumes it, burning an attempt.
	if got := TakePendingCompose(PendingComposePath, lay.ModuleCachePath, nil); got == nil {
		t.Fatal("staged set was not offered")
	}

	// The reconciler ticks again with the SAME desired set. It must not rewrite.
	r.stagePendingCompose(assigned, manifests, AssignmentMeta{})
	after, err := LoadPendingCompose(PendingComposePath)
	if err != nil {
		t.Fatal(err)
	}
	if after.Attempts != 1 {
		t.Errorf("re-stage reset the attempt counter to %d — the exhaustion cap is defeated "+
			"and a never-healthy set would retry forever", after.Attempts)
	}
}

// P3 (round 4): the breadcrumb write is best-effort, so a failed write leaves the
// PREVIOUS boot's file on disk. Once FromPending can authorise overwriting a
// proven LKG, a stale breadcrumb could promote a set that already failed.
func TestCapturer_RefusesABreadcrumbFromAnotherBoot(t *testing.T) {
	if CurrentBootID() == "" {
		t.Skip("no kernel boot_id available on this host")
	}
	dir := t.TempDir()
	lkgPath := dir + "/assignment-lkg.json"
	bcPath := dir + "/boot-composed.json"

	good := []LKGModule{{ID: "m1", Name: "mod", HasDataFile: true,
		Digest: "sha256:proven", Manifest: json.RawMessage(`{"id":"m1"}`)}}
	failed := []LKGModule{{ID: "m1", Name: "mod", HasDataFile: true,
		Digest: "sha256:failed", Manifest: json.RawMessage(`{"id":"m1"}`)}}

	if err := WriteBootLKG(lkgPath, &BootLKG{ConfirmedAt: time.Now().UTC(), Modules: good}); err != nil {
		t.Fatal(err)
	}
	// A breadcrumb left behind by an EARLIER boot, marked FromPending.
	if err := WriteBreadcrumb(bcPath, &BootComposedBreadcrumb{
		ComposedAt: time.Now().UTC(), FromPending: true,
		BootID: "00000000-0000-0000-0000-000000000000", Modules: failed,
	}); err != nil {
		t.Fatal(err)
	}

	c := &LKGCapturer{
		BreadcrumbPath: bcPath, LKGPath: lkgPath,
		Prober: rpAlwaysHealthy{}, RequiredConsecutive: 1, PollInterval: time.Millisecond,
		CachePath: func(string) string { return dir },
		OnError:   func(string, error) {},
	}
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	_ = c.Run(ctx)

	after, err := LoadBootLKG(lkgPath)
	if err != nil {
		t.Fatal(err)
	}
	if after.Modules[0].Digest != "sha256:proven" {
		t.Errorf("a STALE breadcrumb overwrote the proven LKG with %q", after.Modules[0].Digest)
	}
}
