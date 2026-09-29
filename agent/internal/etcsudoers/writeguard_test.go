package etcsudoers

import (
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/writeguard"
)

// The default-target entry points resolve to /etc/sudoers.d — including the
// destructive ones (the sweep of powernode-* drop-ins, the break-glass
// removal). The guard must refuse them on the resolved path before any I/O.
func TestDefaultTargetsAreRefusedUnderTheGuard(t *testing.T) {
	t.Cleanup(func() { writeguard.Reset() })
	writeguard.Reset()

	calls := map[string]func() error{
		"Apply":                           func() error { return Apply(nil) },
		"ApplyOperatorBreakGlass(enable)": func() error { return ApplyOperatorBreakGlass(true) },
		"ApplyOperatorBreakGlass(revoke)": func() error { return ApplyOperatorBreakGlass(false) },
	}
	for name, call := range calls {
		if err := call(); err == nil {
			t.Errorf("%s: default target was not refused", name)
		}
	}
	if got := len(writeguard.Reset()); got != len(calls) {
		t.Errorf("recorded %d violations, want %d", got, len(calls))
	}
}
