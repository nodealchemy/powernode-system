package identity

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/writeguard"
)

// IMP-d869a06dfc57 — surfaceClaimCode writes to the machine's own console
// (/dev/tty1). It is the one place this package writes outside its caller's
// control, and a test that reaches it as root would print on a real node's
// console. The identity strategies otherwise only READ (/boot, /run, /etc,
// /sys, cloud metadata).
func TestClaimConsoleDefaultIsRefusedUnderTheGuard(t *testing.T) {
	rec := writeguard.Capture(func() { (&ClaimStrategy{}).surfaceClaimCode("GUARD-PROBE") })
	if len(rec) != 1 || !strings.Contains(rec[0], "/dev/tty1") {
		t.Fatalf("the default console was not refused exactly once: %v", rec)
	}
}

func TestClaimConsoleSandboxedIsWrittenAndNotRefused(t *testing.T) {
	console := filepath.Join(t.TempDir(), "tty1")
	if err := os.WriteFile(console, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	prev := claimConsolePath
	claimConsolePath = console
	t.Cleanup(func() { claimConsolePath = prev })

	rec := writeguard.Capture(func() { (&ClaimStrategy{}).surfaceClaimCode("SANDBOX-CODE") })
	if len(rec) != 0 {
		t.Fatalf("a sandboxed console was refused: %v", rec)
	}
	got, err := os.ReadFile(console)
	if err != nil || !strings.Contains(string(got), "SANDBOX-CODE") {
		t.Fatalf("the claim code did not reach the console file: %q err=%v", got, err)
	}
}
