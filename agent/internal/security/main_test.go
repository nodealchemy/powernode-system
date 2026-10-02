package security

import (
	"os"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/writeguard"
)

// TestMain floors every host-global write in this package at the test sandbox
// (IMP-d869a06dfc57): a test that forgets its override seam resolves to the
// real /etc, /run or console, and the guard refuses the write and fails the
// binary, on the path, so it fires unprivileged too.
func TestMain(m *testing.M) {
	os.Exit(writeguard.Run(m.Run))
}
