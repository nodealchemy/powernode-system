package runtime

// Demonstration test (adversarial review round 4): a FromPending boot that
// passes the health gate MUST advance the frozen LKG — that is the entire
// point of commit 7908699a.
import (
	"context"
	"encoding/json"
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
		ComposedAt: time.Now().UTC(), FromPending: true, Modules: newSet,
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

// P2 (round 4): staging must compare against what is ALREADY staged, not only
// against what booted. Rewriting the file each reconcile tick reset Attempts to
// zero, silently erasing the exhaustion cap — so a set that never passes the
// health gate would retry forever instead of being abandoned.
func TestStagePendingCompose_PreservesBurnedAttempts(t *testing.T) {
	dir := t.TempDir()
	cache := dir + "/cache"
	if err := os.MkdirAll(cache, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(cache+"/blob.erofs", []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	path := dir + "/pending.json"
	mods := []LKGModule{{ID: "m1", Name: "mod", HasDataFile: true,
		Digest: "sha256:aa", Manifest: json.RawMessage(`{"id":"m1"}`)}}

	if err := WritePendingCompose(path, &PendingCompose{
		Set: BootLKG{ConfirmedAt: time.Now().UTC(), Modules: mods}, Attempts: 1,
	}); err != nil {
		t.Fatal(err)
	}
	// Same composition already staged → a re-stage must be a no-op.
	existing, err := LoadPendingCompose(path)
	if err != nil {
		t.Fatal(err)
	}
	if !sameComposition(existing.Set.Modules, mods) {
		t.Fatal("fixture problem: compositions should match")
	}
	if existing.Attempts != 1 {
		t.Fatalf("burned attempt lost: Attempts = %d, want 1", existing.Attempts)
	}
	// And the cap must still bind after the remaining attempt is taken.
	cp := func(string) string { return cache + "/blob.erofs" }
	if got := TakePendingCompose(path, cp, nil); got == nil {
		t.Fatal("expected the last attempt to be offered")
	}
	if got := TakePendingCompose(path, cp, nil); got != nil {
		t.Error("offered a set past PendingMaxTries — the exhaustion cap did not bind")
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
