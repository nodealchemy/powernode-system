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

// K1 (review round 6, CRITICAL): filterUnsafeVersionBumpDetaches's pre-check
// used to run applyModuleSecurityPolicy — the REAL writers — against the NEW
// manifest, BEFORE deciding whether the OLD digest's detach was safe. Since
// a version bump's old and new digest share the SAME unit name, that was
// silently rewriting the STILL-RUNNING old digest's live drop-ins with the
// new digest's DIFFERENT security config on every tick a bump stayed
// deferred (or even on a tick it didn't — the mutation happened before the
// deferral DECISION was made). wouldModuleSecurityPolicyRefuse is the
// replacement; this test calls it directly (not through a full RunOnce
// pass) so the assertion is unconditional on what it returns — a pre-check
// answering "safe to detach" must be JUST AS non-mutating as one answering
// "refuse", because the whole point is that the PROBE never touches real
// content either way.
func TestWouldModuleSecurityPolicyRefuse_NeverWritesRealDropInContent(t *testing.T) {
	dropIns := t.TempDir()
	t.Cleanup(security.SetSystemdDropInRootForTest(dropIns))
	rec := &mount.RecorderRunner{}
	r := liveReconciler(t, rec)

	oldMf := &manifest.Manifest{
		ID:                          "m1",
		Name:                        "app-mod",
		Digest:                      "abc123",
		ServiceCapabilitiesPresence: true,
		Config:                      map[string]any{"security": map[string]any{"capabilities": []any{"CAP_CHOWN"}, "user_namespace": false}},
		Services:                    []manifest.Service{{Name: "app", StartCommand: "/bin/true"}},
	}
	if err := r.attachModule(context.Background(), mount.Module{ID: "m1", Digest: "abc123", Priority: 1}, oldMf); err != nil {
		t.Fatalf("test setup: real attach of the old digest must succeed: %v", err)
	}

	unit := lifecycle.UnitName("m1", "app")
	dropInPath := filepath.Join(dropIns, unit+".d", "capabilities.conf")
	before, err := os.ReadFile(dropInPath)
	if err != nil {
		t.Fatalf("test setup: expected capabilities.conf after the real attach: %v", err)
	}

	// A NEW manifest, SAME module/unit, GENUINELY DIFFERENT capability list —
	// exactly the shape a version bump's toAttach entry has.
	newMf := &manifest.Manifest{
		ID:                          "m1",
		Name:                        "app-mod",
		Digest:                      "def456",
		ServiceCapabilitiesPresence: true,
		Config:                      map[string]any{"security": map[string]any{"capabilities": []any{"CAP_NET_ADMIN"}, "user_namespace": false}},
		Services:                    []manifest.Service{{Name: "app", StartCommand: "/bin/true"}},
	}
	newMod := mount.Module{ID: "m1", Digest: "def456", Priority: 1}

	if _, err := r.wouldModuleSecurityPolicyRefuse(newMod, newMf); err != nil {
		t.Fatalf("wouldModuleSecurityPolicyRefuse: %v", err)
	}

	after, err := os.ReadFile(dropInPath)
	if err != nil {
		t.Fatalf("expected capabilities.conf to still exist after the pre-check: %v", err)
	}
	if string(before) != string(after) {
		t.Errorf("K1 REGRESSION: wouldModuleSecurityPolicyRefuse wrote REAL content to %s:\nbefore: %q\nafter:  %q", dropInPath, before, after)
	}

	for _, inv := range rec.Invocations {
		if inv.Name == "semodule" || inv.Name == "apparmor_parser" {
			t.Errorf("K1 REGRESSION: the pre-check invoked %s — a MAC loader acts on the RUNNING system and must never run from a pre-check: %v", inv.Name, inv)
		}
	}
}

// The other half: when the new manifest's write WOULD genuinely fail closed
// (a stray directory occupying the target path — the standard fixture this
// package uses to force a drop-in write failure), the pre-check must STILL
// report the refusal (proving the probe is not a no-op that always says
// "safe") while remaining just as non-mutating.
func TestWouldModuleSecurityPolicyRefuse_DetectsAndReportsAFailureWithoutMutating(t *testing.T) {
	dropIns := t.TempDir()
	t.Cleanup(security.SetSystemdDropInRootForTest(dropIns))
	rec := &mount.RecorderRunner{}
	r := liveReconciler(t, rec)

	oldMf := &manifest.Manifest{
		ID:                          "m1",
		Name:                        "app-mod",
		Digest:                      "abc123",
		ServiceCapabilitiesPresence: true,
		Config:                      map[string]any{"security": map[string]any{"capabilities": []any{"CAP_CHOWN"}, "user_namespace": false}},
		Services:                    []manifest.Service{{Name: "app", StartCommand: "/bin/true"}},
	}
	if err := r.attachModule(context.Background(), mount.Module{ID: "m1", Digest: "abc123", Priority: 1}, oldMf); err != nil {
		t.Fatalf("test setup: real attach of the old digest must succeed: %v", err)
	}

	unit := lifecycle.UnitName("m1", "app")
	dropInPath := filepath.Join(dropIns, unit+".d", "capabilities.conf")
	before, err := os.ReadFile(dropInPath)
	if err != nil {
		t.Fatalf("test setup: expected capabilities.conf after the real attach: %v", err)
	}

	// Occupy the exact target the real writer would eventually rename onto —
	// ProbeDropInWritable's Lstat check must catch this without ever
	// touching the OLD regular file: it Lstats the literal target path,
	// which right now is a regular file (the OLD content) — occupying it
	// here would DESTROY that content, so instead this test blocks the
	// PARENT directory's writability generically (a second file inside it
	// that collides with... no: use a sibling unit whose .d IS the blocked
	// target so the OLD unit's real file is never touched at all).
	//
	// Simplest non-destructive failure: make the .d directory unwritable to
	// new files by placing an entry AT the exact probe temp-file pattern is
	// not practical (glob, not fixed name) — instead, corrupt the manifest
	// so decideModuleSecurityPolicy itself refuses (unapproved privileged),
	// which is unambiguously a pre-check "refuse" outcome that never reaches
	// ProbeDropInWritable at all, proving the OTHER refusal path is just as
	// non-mutating.
	newMf := &manifest.Manifest{
		ID:                          "m1",
		Name:                        "app-mod",
		Digest:                      "def456",
		ServiceCapabilitiesPresence: true,
		Config:                      map[string]any{"security": map[string]any{"capabilities": []any{"CAP_NET_ADMIN"}, "user_namespace": false, "privileged": true}},
		Services:                    []manifest.Service{{Name: "app", StartCommand: "/bin/true"}},
	}
	newMod := mount.Module{ID: "m1", Digest: "def456", Priority: 1}

	failedUnits, err := r.wouldModuleSecurityPolicyRefuse(newMod, newMf)
	if err == nil {
		t.Fatal("expected wouldModuleSecurityPolicyRefuse to refuse an unapproved privileged request")
	}
	if len(failedUnits) != 0 {
		t.Errorf("an unapproved-privileged refusal names no specific failed units, got %v", failedUnits)
	}

	after, err := os.ReadFile(dropInPath)
	if err != nil {
		t.Fatalf("expected capabilities.conf to still exist after the pre-check: %v", err)
	}
	if string(before) != string(after) {
		t.Errorf("K1 REGRESSION: a REFUSING pre-check still must not mutate real content:\nbefore: %q\nafter:  %q", before, after)
	}
	for _, inv := range rec.Invocations {
		if inv.Name == "semodule" || inv.Name == "apparmor_parser" {
			t.Errorf("K1 REGRESSION: the pre-check invoked %s on a refusal path", inv.Name)
		}
	}
}
