package bootupgrade

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/bootslots"
)

// TestMain sandboxes the /persist-backed paths this package reaches, so a test
// that forgets a seam hits a temp dir rather than live boot state. See the
// matching TestMain in internal/runtime for why this is a floor rather than a
// convention: a const path already let the suite delete production state once.
func TestMain(m *testing.M) {
	sandbox, err := os.MkdirTemp("", "powernode-bootupgrade-test-*")
	if err != nil {
		fmt.Fprintln(os.Stderr, "TestMain: cannot create sandbox:", err)
		os.Exit(1)
	}
	restoreStage := SetDefaultStageDirForTest(filepath.Join(sandbox, "stage"))
	restoreState := bootslots.SetStatePathForTest(filepath.Join(sandbox, "boot-slot.json"))

	code := m.Run()

	restoreState()
	restoreStage()
	_ = os.RemoveAll(sandbox)
	os.Exit(code)
}
