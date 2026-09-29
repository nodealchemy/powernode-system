package cli

import (
	"os"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/writeguard"
)

// TestMain floors every etcidentity/etcsudoers write this test binary can reach
// (it links both through internal/runtime) at the test sandbox: a write that
// resolves to the real /etc or /home is refused on its path and fails the binary,
// unprivileged too. See internal/writeguard.
func TestMain(m *testing.M) {
	os.Exit(writeguard.Run(m.Run))
}
