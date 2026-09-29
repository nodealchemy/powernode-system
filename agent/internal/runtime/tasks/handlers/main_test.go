package handlers

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

// TestMain sandboxes this package's /persist-backed paths before any test runs.
// markAttempted() writes on the handler success path, so without this a handler
// test drops a marker into the host's live boot state — the same shape as the
// const that let the runtime suite delete a staged composition.
func TestMain(m *testing.M) {
	sandbox, err := os.MkdirTemp("", "powernode-handlers-test-*")
	if err != nil {
		fmt.Fprintln(os.Stderr, "TestMain: cannot create sandbox:", err)
		os.Exit(1)
	}
	restore := SetAttemptMarkerPathForTest(filepath.Join(sandbox, "boot-image-upgrade.attempted"))
	// probe.node_inspect reads /proc and the filesystem directly. Its tests point
	// both at their own sandbox; this default means one that forgets to can only
	// ever see an empty directory, never the live host.
	restoreInspect := SetInspectRootsForTest(filepath.Join(sandbox, "inspect-fs"), filepath.Join(sandbox, "inspect-proc"))
	code := m.Run()
	restoreInspect()
	restore()
	_ = os.RemoveAll(sandbox)
	os.Exit(code)
}
