package etcidentity

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// mkEtc makes <dir>/etc so ApplyHostname's AtomicWrite (temp file in the
// target dir) has somewhere to land, and returns the hostname path.
func mkEtc(t *testing.T) (root, hostnamePath string) {
	t.Helper()
	root = t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "etc"), 0o755); err != nil {
		t.Fatalf("mkdir etc: %v", err)
	}
	return root, filepath.Join(root, "etc", "hostname")
}

func TestApplyHostname_WritesFileWithTrailingNewline(t *testing.T) {
	root, path := mkEtc(t)

	changed, err := ApplyHostname(root, "ops-hub", false)
	if err != nil {
		t.Fatalf("ApplyHostname: %v", err)
	}
	if !changed {
		t.Fatalf("expected changed=true on first write")
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read hostname: %v", err)
	}
	if string(got) != "ops-hub\n" {
		t.Fatalf("hostname = %q, want %q", string(got), "ops-hub\n")
	}
}

func TestApplyHostname_Idempotent(t *testing.T) {
	root, _ := mkEtc(t)

	if _, err := ApplyHostname(root, "ops-hub", false); err != nil {
		t.Fatalf("first ApplyHostname: %v", err)
	}
	// Second call with the same name must be a no-op (changed=false) — the
	// reconcile loop calls this every tick and must not churn the file.
	changed, err := ApplyHostname(root, "ops-hub", false)
	if err != nil {
		t.Fatalf("second ApplyHostname: %v", err)
	}
	if changed {
		t.Fatalf("expected changed=false on identical re-apply")
	}
}

func TestApplyHostname_EmptyNameIsNoOp(t *testing.T) {
	root, path := mkEtc(t)

	changed, err := ApplyHostname(root, "   ", false)
	if err != nil {
		t.Fatalf("ApplyHostname: %v", err)
	}
	if changed {
		t.Fatalf("expected changed=false for empty/whitespace name")
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("expected no hostname file to be written, stat err = %v", err)
	}
}

func TestApplyHostname_TrimsAndTruncates(t *testing.T) {
	root, path := mkEtc(t)

	// Leading/trailing whitespace is trimmed; an over-long name is capped at
	// HostNameMax so sethostname(2) wouldn't EINVAL on the live path.
	long := strings.Repeat("a", HostNameMax+10)
	if _, err := ApplyHostname(root, "  "+long+"  ", false); err != nil {
		t.Fatalf("ApplyHostname: %v", err)
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read hostname: %v", err)
	}
	want := strings.Repeat("a", HostNameMax) + "\n"
	if string(got) != want {
		t.Fatalf("hostname len = %d, want capped at %d", len(strings.TrimSpace(string(got))), HostNameMax)
	}
}

func TestApplyHostname_WritesDhcpHostnameDropin(t *testing.T) {
	root, _ := mkEtc(t)

	if _, err := ApplyHostname(root, "ops-hub", false); err != nil {
		t.Fatalf("ApplyHostname: %v", err)
	}
	// networkd must announce the assigned name to DHCP regardless of the base
	// image's baked /etc/hostname, so DNS registers the right name at first
	// boot instead of the build-time machine name.
	dropin := filepath.Join(root, "etc", "systemd", "network", "10-dhcp.network.d", "50-powernode-hostname.conf")
	got, err := os.ReadFile(dropin)
	if err != nil {
		t.Fatalf("read dhcp hostname drop-in: %v", err)
	}
	want := "[DHCPv4]\nHostname=ops-hub\n[DHCPv6]\nHostname=ops-hub\n"
	if string(got) != want {
		t.Fatalf("dhcp hostname drop-in = %q, want %q", string(got), want)
	}
}
