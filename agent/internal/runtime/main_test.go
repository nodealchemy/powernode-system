package runtime

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/bootslots"
)

// TestMain sandboxes every /persist-backed path in this package BEFORE any test
// runs, so touching production state is impossible by default rather than
// avoided by convention.
//
// This exists because the opposite — opt-in seams, remembered per test — already
// failed in exactly the way you would predict. PendingComposePath was a const, so
// nothing could redirect it, and the promote path's ClearPendingCompose ran
// os.Remove against /persist/var/lib/powernode/pending-compose.json on whatever
// host ran `go test`. Debugging on the control plane is precisely when someone
// would do that. The fetch-failure paths READ the host's real staged set too, and
// a read-dependence leaves no trace at all: a canary file proves writes did not
// happen, never that behaviour was not influenced by real on-disk state.
//
// Redirecting here makes the failure mode "a future test writes into a temp dir
// it did not expect" instead of "a future test deletes live boot state". Tests
// that need their own paths still override them locally; this is the floor, not
// a replacement for the per-test seams.
func TestMain(m *testing.M) {
	sandbox, err := os.MkdirTemp("", "powernode-runtime-test-*")
	if err != nil {
		fmt.Fprintln(os.Stderr, "TestMain: cannot create sandbox:", err)
		os.Exit(1)
	}

	// Every package-level path that would otherwise resolve under /persist (or
	// /proc). Anything added later must be added here — the pattern-validation
	// scan flags absolute-path literals in non-test agent code for this reason.
	BootLKGPath = filepath.Join(sandbox, "assignment-lkg.json")
	BootBreadcrumbPath = filepath.Join(sandbox, "boot-composed.json")
	LKGDisableSentinel = filepath.Join(sandbox, "lkg-fallback.disabled")
	PendingComposePath = filepath.Join(sandbox, "pending-compose.json")
	procCmdlinePath = filepath.Join(sandbox, "cmdline")
	// A cmdline that parses but disables nothing, so tests see the default
	// behaviour rather than whatever this host happens to boot with — the read
	// half of the same hazard.
	if werr := os.WriteFile(procCmdlinePath, []byte("ro quiet\n"), 0o644); werr != nil {
		fmt.Fprintln(os.Stderr, "TestMain: cannot seed cmdline:", werr)
		os.Exit(1)
	}
	// EFI variables are the same read-dependence hazard, and BootConfirmer.Run
	// began reading them the moment the rollback verdict moved ahead of the health
	// gate: it now asks systemd-boot which slot booted before probing anything.
	// Unsandboxed, that reads the HOST's LoaderEntrySelected — so on any real A/B
	// machine (dev-cell, the drill VMs) a test that seeds Pending="b" has its
	// attempt resolved as a rollback because the host booted slot a, and the test
	// then measures nothing it claims to. Two of this package's gate tests would
	// fail there and a third would pass for the wrong reason, while passing here
	// only because this host publishes no LoaderEntrySelected.
	//
	// An empty dir means "no LoaderInfo, no LoaderEntrySelected" — not booted via
	// systemd-boot, booted slot undeterminable — which is the inert default. Tests
	// needing a real answer override it locally.
	bootslots.SetEfivarsDirForTest(filepath.Join(sandbox, "efivars-absent"))

	code := m.Run()
	_ = os.RemoveAll(sandbox)
	os.Exit(code)
}
