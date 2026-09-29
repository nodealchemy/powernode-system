package cli

import (
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/writeguard"
)

// The TestMain floor is only worth having if it is actually armed in this
// binary: an out-of-sandbox path must be refused, a sandboxed one allowed.
func TestWriteGuardIsArmed(t *testing.T) {
	var bad, good error
	rec := writeguard.Capture(func() {
		bad = writeguard.Check("/etc/passwd")
		good = writeguard.Check(t.TempDir() + "/passwd")
	})
	if bad == nil || good != nil || len(rec) != 1 {
		t.Fatalf("guard not armed as expected: bad=%v good=%v recorded=%v", bad, good, rec)
	}
}
