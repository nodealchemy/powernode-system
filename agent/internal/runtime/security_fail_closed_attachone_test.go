package runtime

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/lifecycle"
	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/security"
	"github.com/nodealchemy/powernode-system/agent/internal/verify"
)

// H1 (review round 5, HIGH) bracketed AttachOne's attachModule call with a
// reset/publish cycle so a fail-closed refusal would reach
// SecurityFailClosedUnits(). J2 (the REPLACEMENT review) found that dead in
// production: AttachOne (the `powernode-agent attach <id>` CLI hot-add path)
// runs inside that CLI's own short-lived process — BuildReconciler
// (attach_cmd.go) constructs a Reconciler fresh for the call and the process
// exits right after — so publishing into ITS atomic pointer has no reader.
// The long-running daemon that actually serves buildHeartbeat/
// SecurityFailClosedSensor is a SEPARATE process with its OWN Reconciler.
// The two tests below originally asserted on SecurityFailClosedUnits() after
// calling AttachOne on the SAME in-process Reconciler — a shape that can
// only happen in a test, never in production, and is exactly why they kept
// passing after H1 shipped a change with no real effect. Rewritten here to
// assert on what AttachOne ACTUALLY gives its caller: a typed
// *SecurityFailClosedError naming the refused units (see
// SecurityFailClosedError, reconcile.go, and RunAttach's use of it,
// attach_cmd.go) — the real, durable signal for this CLI-process caller.

func attachOneFixtureReconciler(t *testing.T, tmpRoot, statePath string, client *stubModulesClient, runner *mount.RecorderRunner) *Reconciler {
	t.Helper()
	layout := mount.DefaultLayout()
	layout.Root = tmpRoot
	layout = layout.Resolve()
	r, err := NewReconciler(ReconcilerConfig{
		ModulesClient:  client,
		ManifestClient: client,
		ManifestRoot:   filepath.Join(tmpRoot, "manifests"),
		Puller:         &stubPuller{cacheDir: layout.ModulesCacheRoot},
		Verifier:       verify.AlwaysOK{},
		MountRunner:    runner,
		Layout:         layout,
		StatePath:      statePath,
	})
	if err != nil {
		t.Fatalf("NewReconciler: %v", err)
	}
	return r
}

func narrowCapModuleResponse(digest string) string {
	return `{
		"success": true,
		"data": {
			"id":"m1", "name":"app-mod",
			"priority":100, "effective_priority":100,
			"digest":"` + digest + `",
			"config": {"security": {"capabilities": ["CAP_CHOWN"], "user_namespace": false}},
			"services": [
				{"name":"app", "start_command":"/bin/true", "restart_policy":"always"}
			]
		}
	}`
}

func TestAttachOne_FailClosedRefusalReturnsTypedError(t *testing.T) {
	tmpRoot := t.TempDir()
	statePath := filepath.Join(tmpRoot, "state.json")
	t.Setenv("POWERNODE_LIFECYCLE_UNIT_DIR", t.TempDir())
	dropIns := t.TempDir()
	t.Cleanup(security.SetSystemdDropInRootForTest(dropIns))

	client := &stubModulesClient{responses: map[string]string{
		"/api/v1/system/node_api/modules/m1": narrowCapModuleResponse("abc123"),
	}}
	runner := &mount.RecorderRunner{}
	r := attachOneFixtureReconciler(t, tmpRoot, statePath, client, runner)

	unit := lifecycle.UnitName("m1", "app")
	unitDropInDir := filepath.Join(dropIns, unit+".d")
	if err := os.MkdirAll(unitDropInDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(unitDropInDir, "capabilities.conf"), 0o755); err != nil {
		t.Fatal(err)
	}

	_, err := r.AttachOne(context.Background(), "m1")
	if err == nil {
		t.Fatal("AttachOne must return an error when the security drop-in fails to write (fail closed)")
	}

	var secErr *SecurityFailClosedError
	if !errors.As(err, &secErr) {
		t.Fatalf("J2: AttachOne's fail-closed refusal must be a *SecurityFailClosedError so the CLI caller (attach_cmd.go) can name the refused units and choose a distinct exit code; got %T: %v", err, err)
	}
	if !containsArg(secErr.Units, unit) {
		t.Errorf("expected %s in SecurityFailClosedError.Units, got %v", unit, secErr.Units)
	}

	// J2: this Reconciler instance is exactly what AttachOne runs against
	// inside the CLI process — and that process has no reader for this.
	// Asserting it stays EMPTY documents the fix, not a gap: publishing here
	// was H1's dead-in-production behavior, reverted.
	if got := r.SecurityFailClosedUnits(); len(got) != 0 {
		t.Errorf("J2: AttachOne must NOT publish into SecurityFailClosedUnits() (no daemon-side reader ever sees this process's Reconciler) — got %v", got)
	}
}

// The other half: a unit that RECOVERED once (a prior successful attach
// marked it in SecurityFailClosedRecovered, which G5 uses to suppress a
// STALE boot-time pivot entry) must still REFUSE via a typed error if
// AttachOne fails on it again — recovered is a historical fact about the
// past, never a standing exemption from a new failure. Unlike the pre-J2
// version of this test, this does NOT go through SecurityFailClosedUnits()
// (see the file doc comment above for why that channel is not AttachOne's).
func TestAttachOne_PreviouslyRecoveredUnitFailingAgainStillRefuses(t *testing.T) {
	tmpRoot := t.TempDir()
	statePath := filepath.Join(tmpRoot, "state.json")
	t.Setenv("POWERNODE_LIFECYCLE_UNIT_DIR", t.TempDir())
	dropIns := t.TempDir()
	t.Cleanup(security.SetSystemdDropInRootForTest(dropIns))

	client := &stubModulesClient{responses: map[string]string{
		"/api/v1/system/node_api/modules/m1": narrowCapModuleResponse("abc123"),
	}}
	runner := &mount.RecorderRunner{}
	r := attachOneFixtureReconciler(t, tmpRoot, statePath, client, runner)

	unit := lifecycle.UnitName("m1", "app")

	// Step 1: a SUCCESSFUL attach, direct through attachModule (not
	// AttachOne, so state.json's AttachedModules stays empty and the
	// upcoming AttachOne call below does not short-circuit on
	// "already_attached") — marks the unit RECOVERED (G5).
	mf := &manifest.Manifest{
		ID:                          "m1",
		Name:                        "app-mod",
		Digest:                      "abc123",
		ServiceCapabilitiesPresence: true,
		Config:                      map[string]any{"security": map[string]any{"capabilities": []any{"CAP_CHOWN"}, "user_namespace": false}},
		Services:                    []manifest.Service{{Name: "app", StartCommand: "/bin/true"}},
	}
	if err := r.attachModule(context.Background(), mount.Module{ID: "m1", Digest: "abc123", Priority: 1}, mf); err != nil {
		t.Fatalf("test setup: attachModule (first, successful) must succeed: %v", err)
	}
	if recovered := r.SecurityFailClosedRecovered(); !recovered[unit] {
		t.Fatalf("test setup: expected %s marked recovered after the first successful attach, got %v", unit, recovered)
	}

	// Step 2: force the drop-in write to fail, then attach again through
	// AttachOne (a fresh digest so it does not read as "already_attached" —
	// AttachOne's own state.json bookkeeping was never touched by step 1).
	unitDropInDir := filepath.Join(dropIns, unit+".d")
	blocked := filepath.Join(unitDropInDir, "capabilities.conf")
	// The first (successful) attach already wrote capabilities.conf as a
	// regular FILE — remove it before turning the same path into a
	// directory, or MkdirAll fails with "not a directory".
	if err := os.RemoveAll(blocked); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(blocked, 0o755); err != nil {
		t.Fatal(err)
	}
	client.responses["/api/v1/system/node_api/modules/m1"] = narrowCapModuleResponse("def456")

	_, err := r.AttachOne(context.Background(), "m1")
	if err == nil {
		t.Fatal("AttachOne must fail closed on the second attempt")
	}

	var secErr *SecurityFailClosedError
	if !errors.As(err, &secErr) {
		t.Fatalf("expected a *SecurityFailClosedError on the second, refused attempt; got %T: %v", err, err)
	}
	if !containsArg(secErr.Units, unit) {
		t.Errorf("H1/G5: a unit marked recovered must still be named in a NEW SecurityFailClosedError when it fails again, got %v", secErr.Units)
	}
	if recovered := r.SecurityFailClosedRecovered(); !recovered[unit] {
		t.Fatalf("recovered marker must still be set (it is a historical fact, not cleared by a later failure), got %v", recovered)
	}
}
