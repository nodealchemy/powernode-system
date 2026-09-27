package runtime

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/lifecycle"
	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/security"
)

// TestApplyModuleSecurityDropIns_PrivilegedBranchLeavesLegacyAmbientFileAlone
// is X7 (IMP-caef5c00d63f round X, LOW, A7): a PRIVILEGED unit must NOT have
// its legacy ambient-capabilities.conf removed — a non-root privileged unit
// (traefik binding :80 is the canonical case) can be relying on that
// legacy file as its only remaining source of a real capability grant once
// removeCapability deletes the current-format capabilities.conf for a
// privileged unit. Removing both in the same pass would strip the grant
// entirely with nothing left to fall back on.
func TestApplyModuleSecurityDropIns_PrivilegedBranchLeavesLegacyAmbientFileAlone(t *testing.T) {
	dropIns := t.TempDir()
	t.Cleanup(security.SetSystemdDropInRootForTest(dropIns))

	mf := &manifest.Manifest{
		ID:       "m1",
		Services: []manifest.Service{{Name: "app", StartCommand: "/bin/true"}},
	}
	unit := lifecycle.UnitName("m1", "app")
	dropInDir := filepath.Join(dropIns, unit+".d")
	if err := os.MkdirAll(dropInDir, 0o755); err != nil {
		t.Fatal(err)
	}
	legacyPath := filepath.Join(dropInDir, "ambient-capabilities.conf")
	legacyBody := "[Service]\nAmbientCapabilities=CAP_NET_BIND_SERVICE\n"
	if err := os.WriteFile(legacyPath, []byte(legacyBody), 0o644); err != nil {
		t.Fatal(err)
	}

	privileged := &security.Policy{Privileged: true}
	if _, failed := applyModuleSecurityDropIns("m1", mf, privileged, nil, nil, liveSecurityDropInFuncs(), func(string, error) {}); len(failed) != 0 {
		t.Fatalf("privileged attach must not fail, got %v", failed)
	}

	got, err := os.ReadFile(legacyPath)
	if err != nil {
		t.Fatalf("X7 REGRESSION: expected the legacy ambient file to survive a privileged unit's own drop-in pass, but it's gone: %v", err)
	}
	if string(got) != legacyBody {
		t.Errorf("X7 REGRESSION: expected the legacy file's content untouched, got %q want %q", got, legacyBody)
	}
}
