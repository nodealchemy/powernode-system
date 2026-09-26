package runtime

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/lifecycle"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/security"
	"github.com/nodealchemy/powernode-system/agent/internal/verify"
)

// J4 (review round 5 REPLACEMENT review, mutant M4 — "most important"):
// recordSecurityFailClosed lives INSIDE attachModule, which both of RunOnce's
// loops call — the toAttach (first attach / digest bump) loop and the
// toReattach (manifest-only change, SAME digest, re-materialize + re-apply
// policy) loop. Every existing fail-closed test up to this round drove the
// toAttach path; nothing proved the SAME recording actually reaches
// SecurityFailClosedUnits() when the refusal is discovered via a REATTACH —
// a mutant that made attachModule's fail-closed branch a no-op only on the
// path the toReattach loop takes would have passed every prior test in this
// package.
func manifestFixtureWithCaps(digest string, caps []string) string {
	quoted := make([]string, len(caps))
	for i, c := range caps {
		quoted[i] = `"` + c + `"`
	}
	return fmt.Sprintf(`{
		"success": true,
		"data": {
			"id":"m1", "name":"app-mod",
			"priority":100, "effective_priority":100,
			"digest":"%s",
			"config": {"security": {"capabilities": [%s], "user_namespace": false}},
			"services": [
				{"name":"app", "start_command":"/bin/true", "restart_policy":"always"}
			]
		}
	}`, digest, strings.Join(quoted, ","))
}

func TestSecurityFailClosed_ReattachPathRefusalReachesSecurityFailClosedUnits(t *testing.T) {
	tmpRoot := t.TempDir()
	statePath := filepath.Join(tmpRoot, "state.json")
	dropIns := t.TempDir()
	t.Cleanup(security.SetSystemdDropInRootForTest(dropIns))
	t.Setenv("POWERNODE_LIFECYCLE_UNIT_DIR", t.TempDir())

	client := &stubModulesClient{responses: map[string]string{
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
	runner := &mount.RecorderRunner{}
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

	unit := lifecycle.UnitName("m1", "app")

	// TICK 1: clean attach.
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 1: %v", err)
	}
	if got := r.SecurityFailClosedUnits(); len(got) != 0 {
		t.Fatalf("tick 1: expected a clean attach, got SecurityFailClosedUnits()=%v", got)
	}

	// TICK 2: SAME digest, but the manifest's capabilities list changes —
	// attachStamp (services/security-block hash) moves, which puts m1 in
	// toReattach, NOT toAttach (mount.Reconcile's digest-based diff sees no
	// digest change at all). Force the drop-in write to fail on this tick.
	if err := os.RemoveAll(filepath.Join(tmpRoot, "manifests", "m1")); err != nil {
		t.Fatal(err)
	}
	client.responses["/api/v1/system/node_api/modules/m1"] = manifestFixtureWithCaps("abc123", []string{"CAP_CHOWN", "CAP_NET_ADMIN"})

	unitDropInDir := filepath.Join(dropIns, unit+".d")
	blocked := filepath.Join(unitDropInDir, "capabilities.conf")
	if err := os.RemoveAll(blocked); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(blocked, 0o755); err != nil {
		t.Fatal(err)
	}

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 2: %v", err)
	}

	if got := r.SecurityFailClosedUnits(); !containsArg(got, unit) {
		t.Errorf("J4/M4 REGRESSION: a security drop-in failure discovered via the REATTACH path (manifest-only change, same digest) must reach SecurityFailClosedUnits() exactly like the toAttach path does, got %v", got)
	}
}
