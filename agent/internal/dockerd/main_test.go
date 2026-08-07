package dockerd

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

// TestMain sandboxes the /persist-backed state path this package reaches, so
// a test that forgets a StatePath override hits a temp dir rather than live
// dockerd state. Same floor as internal/runtime and internal/bootupgrade: a
// const path already let an agent suite depend on (and on a fleet node,
// mutate) live /persist — IMP-30493f5f0ab4.
func TestMain(m *testing.M) {
	sandbox, err := os.MkdirTemp("", "powernode-dockerd-test-*")
	if err != nil {
		fmt.Fprintln(os.Stderr, "TestMain: cannot create sandbox:", err)
		os.Exit(1)
	}
	restore := SetDefaultStatePathForTest(filepath.Join(sandbox, "dockerd_state.json"))

	code := m.Run()

	restore()
	_ = os.RemoveAll(sandbox)
	os.Exit(code)
}
