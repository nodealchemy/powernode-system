package runtime

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/writeguard"
)

// TestHostnameApplyNeverResolvesOutsideTheSandbox drives the two live-root
// hostname writers (the pre-loop applyHostnameFromFwCfg; the per-tick reconcile
// call shares its seam) the way a fleet node reaches them: a persisted
// platform-assigned hostname. Without the redirect that resolves to the real
// /etc/hostname (and, applyLive, sethostname(2)) — harmless-looking unprivileged
// (EACCES), a rename of the host as root. The verdict here is on the resolved
// path, so it fails unprivileged too.
func TestHostnameApplyNeverResolvesOutsideTheSandbox(t *testing.T) {
	orig := assignedHostnamePath
	assignedHostnamePath = filepath.Join(t.TempDir(), "hostname")
	t.Cleanup(func() { assignedHostnamePath = orig })
	persistAssignedHostname("ops-hub-guard-probe")

	writeguard.Reset()
	err := (&Service{}).applyHostnameFromFwCfg()
	if v := writeguard.Reset(); len(v) > 0 {
		t.Fatalf("hostname apply resolved outside the test sandbox (err=%v): %s", err, strings.Join(v, "; "))
	}
	if err != nil {
		t.Fatalf("applyHostnameFromFwCfg: %v", err)
	}
	got, rerr := os.ReadFile(filepath.Join(hostnameTestRoot, "etc", "hostname"))
	if rerr != nil || strings.TrimSpace(string(got)) != "ops-hub-guard-probe" {
		t.Fatalf("hostname did not land in the sandbox root: %q, %v", got, rerr)
	}
}

// ComposeForPivot falls back to Layout.SysRoot when its sysroot is empty; if
// that too were empty, unionIdentityPaths would yield RELATIVE paths and the
// render would land under the working directory. The guard must refuse those,
// and accept a real sandboxed sysroot — both arms.
func TestUnionIdentityPathsGuard(t *testing.T) {
	t.Cleanup(func() { writeguard.Reset() })
	writeguard.Reset()
	p := unionIdentityPaths("")
	for _, path := range []string{p.Lock, p.Passwd, p.Group, p.Shadow, p.Gshadow} {
		if err := writeguard.Check(path); err == nil {
			t.Errorf("empty sysroot: %q was not refused", path)
		}
	}
	if len(writeguard.Reset()) != 5 {
		t.Error("empty sysroot: expected 5 recorded violations")
	}

	p = unionIdentityPaths(t.TempDir())
	for _, path := range []string{p.Lock, p.Passwd, p.Group, p.Shadow, p.Gshadow} {
		if err := writeguard.Check(path); err != nil {
			t.Errorf("sandboxed sysroot: %q refused: %v", path, err)
		}
	}
	if v := writeguard.Reset(); len(v) != 0 {
		t.Errorf("sandboxed sysroot recorded violations: %v", v)
	}
}

// Service.Run applies the break-glass drop-in — or REMOVES it when the env flag
// is off, the common case — against /etc/sudoers.d before bootstrap. The
// removal is the destructive half: as root a test binary would delete a real
// node's operator access.
func TestBreakGlassSeamStaysInTheSandbox(t *testing.T) {
	writeguard.Reset()
	if err := applyBreakGlass(false); err != nil {
		t.Fatalf("applyBreakGlass(false): %v", err)
	}
	if v := writeguard.Reset(); len(v) != 0 {
		t.Fatalf("break-glass resolved outside the sandbox: %v", v)
	}
}
