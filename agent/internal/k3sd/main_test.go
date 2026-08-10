package k3sd

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

// TestMain sandboxes the /persist-backed state paths this package reaches, so
// a test that forgets a StatePath override hits a temp dir rather than live
// k3s server/agent state. Same floor as internal/runtime and
// internal/bootupgrade: a const path already let an agent suite depend on
// (and on a fleet node, mutate) live /persist — IMP-30493f5f0ab4.
func TestMain(m *testing.M) {
	sandbox, err := os.MkdirTemp("", "powernode-k3sd-test-*")
	if err != nil {
		fmt.Fprintln(os.Stderr, "TestMain: cannot create sandbox:", err)
		os.Exit(1)
	}
	restoreServer := SetDefaultServerStatePathForTest(filepath.Join(sandbox, "k3sd_server_state.json"))
	restoreAgent := SetDefaultAgentStatePathForTest(filepath.Join(sandbox, "k3sd_agent_state.json"))

	code := m.Run()

	restoreAgent()
	restoreServer()
	_ = os.RemoveAll(sandbox)
	os.Exit(code)
}
