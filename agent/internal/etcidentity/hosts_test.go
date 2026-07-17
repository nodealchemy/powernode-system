package etcidentity

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// mkEtcHosts makes <dir>/etc so ApplyHosts's AtomicWrite (temp file in the
// target dir) has somewhere to land, and returns the hosts path.
func mkEtcHosts(t *testing.T) (root, hostsPath string) {
	t.Helper()
	root = t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "etc"), 0o755); err != nil {
		t.Fatalf("mkdir etc: %v", err)
	}
	return root, filepath.Join(root, "etc", "hosts")
}

func TestApplyHosts_WritesLoopbackAndNodeLine(t *testing.T) {
	root, path := mkEtcHosts(t)

	changed, err := ApplyHosts(root, "ops-hub")
	if err != nil {
		t.Fatalf("ApplyHosts: %v", err)
	}
	if !changed {
		t.Fatalf("expected changed=true on first write")
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read hosts: %v", err)
	}
	want := "127.0.0.1\tlocalhost\n127.0.1.1\tops-hub\n::1\tlocalhost ip6-localhost ip6-loopback\n"
	if string(got) != want {
		t.Fatalf("hosts = %q, want %q", string(got), want)
	}
}

func TestApplyHosts_Idempotent(t *testing.T) {
	root, _ := mkEtcHosts(t)

	if _, err := ApplyHosts(root, "ops-hub"); err != nil {
		t.Fatalf("first ApplyHosts: %v", err)
	}
	// Second call with the same name must be a no-op (changed=false) — the
	// reconcile loop calls this every tick and must not churn the file.
	changed, err := ApplyHosts(root, "ops-hub")
	if err != nil {
		t.Fatalf("second ApplyHosts: %v", err)
	}
	if changed {
		t.Fatalf("expected changed=false on identical re-apply")
	}
}

func TestApplyHosts_EmptyNameIsNoOp(t *testing.T) {
	root, path := mkEtcHosts(t)

	changed, err := ApplyHosts(root, "   ")
	if err != nil {
		t.Fatalf("ApplyHosts: %v", err)
	}
	if changed {
		t.Fatalf("expected changed=false for empty/whitespace name")
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("expected no hosts file to be written, stat err = %v", err)
	}
}

func TestApplyHosts_ChangedNameRewrites(t *testing.T) {
	root, path := mkEtcHosts(t)

	if _, err := ApplyHosts(root, "ops-hub"); err != nil {
		t.Fatalf("first ApplyHosts: %v", err)
	}
	changed, err := ApplyHosts(root, "renamed-hub")
	if err != nil {
		t.Fatalf("second ApplyHosts: %v", err)
	}
	if !changed {
		t.Fatalf("expected changed=true when the hostname line differs")
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read hosts: %v", err)
	}
	if !strings.Contains(string(got), "127.0.1.1\trenamed-hub\n") {
		t.Fatalf("hosts = %q, want it to contain the renamed-hub line", string(got))
	}
}

func TestApplyHosts_TrimsAndTruncates(t *testing.T) {
	root, path := mkEtcHosts(t)

	long := strings.Repeat("a", HostNameMax+10)
	if _, err := ApplyHosts(root, "  "+long+"  "); err != nil {
		t.Fatalf("ApplyHosts: %v", err)
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read hosts: %v", err)
	}
	wantName := strings.Repeat("a", HostNameMax)
	if !strings.Contains(string(got), "127.0.1.1\t"+wantName+"\n") {
		t.Fatalf("hosts = %q, want it to contain the truncated name", string(got))
	}
}
