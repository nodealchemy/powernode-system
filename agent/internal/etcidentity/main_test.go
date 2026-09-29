package etcidentity

import (
	"os"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/writeguard"
)

// TestMain floors every write in this package at the test sandbox: a test that
// forgets its override seam (Paths, dir, root) resolves to the real /etc or
// /home, and the guard refuses the write and fails the binary — on the path, so
// it fires unprivileged too, where the real write would merely EACCES.
func TestMain(m *testing.M) {
	os.Exit(writeguard.Run(m.Run))
}
