package runtime

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// recordingRunner captures the commands a renew would issue.
type recordingRunner struct {
	cmds [][]string
	err  error
}

func (r *recordingRunner) Run(_ context.Context, name string, args ...string) error {
	r.cmds = append(r.cmds, append([]string{name}, args...))
	return r.err
}

func (r *recordingRunner) Output(_ context.Context, _ string, _ ...string) ([]byte, error) {
	return nil, nil
}

// fakeNet builds a /run/systemd/netif/leases + /sys/class/net pair: leases are
// named by ifindex, so the mapping is what turns a lease into an interface name.
func fakeNet(t *testing.T, ifaces map[string]string, leased []string) {
	t.Helper()
	root := t.TempDir()

	sys := filepath.Join(root, "sys")
	for name, idx := range ifaces {
		dir := filepath.Join(sys, name)
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "ifindex"), []byte(idx+"\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	lea := filepath.Join(root, "leases")
	if err := os.MkdirAll(lea, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, idx := range leased {
		if err := os.WriteFile(filepath.Join(lea, idx), []byte("ADDRESS=10.0.0.2\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	prevL, prevS := leasesDir, sysClassNet
	leasesDir, sysClassNet = lea, sys
	t.Cleanup(func() { leasesDir, sysClassNet = prevL, prevS })
}

// THE point of the fix: re-announce on the link that actually holds a lease, so
// a DHCP server that publishes DNS from the client-supplied hostname learns the
// real name immediately instead of at T1 (an hour on this fleet).
func TestRenewDHCPLeases_RenewsTheLeasedLink(t *testing.T) {
	fakeNet(t, map[string]string{"enp6s18": "2", "lo": "1"}, []string{"2"})
	r := &recordingRunner{}

	if err := RenewDHCPLeases(context.Background(), r); err != nil {
		t.Fatalf("RenewDHCPLeases: %v", err)
	}
	if len(r.cmds) != 1 {
		t.Fatalf("expected exactly one renew, got %v", r.cmds)
	}
	got := strings.Join(r.cmds[0], " ")
	if got != "networkctl renew enp6s18" {
		t.Fatalf("got %q, want `networkctl renew enp6s18`", got)
	}
}

// A statically-addressed link has no lease to renew; poking it would only
// produce noise, so leases — not interfaces — drive the loop.
func TestRenewDHCPLeases_SkipsLinksWithoutALease(t *testing.T) {
	fakeNet(t, map[string]string{"enp6s18": "2", "enp7s0": "3"}, []string{"2"})
	r := &recordingRunner{}

	if err := RenewDHCPLeases(context.Background(), r); err != nil {
		t.Fatal(err)
	}
	if len(r.cmds) != 1 || r.cmds[0][2] != "enp6s18" {
		t.Fatalf("expected only the leased link renewed, got %v", r.cmds)
	}
}

// Nodes with no networkd leases at all must be a silent no-op, not an error —
// this runs on every boot's first reconcile tick.
func TestRenewDHCPLeases_NoLeasesIsNotAnError(t *testing.T) {
	fakeNet(t, map[string]string{"enp6s18": "2"}, nil)
	r := &recordingRunner{}

	if err := RenewDHCPLeases(context.Background(), r); err != nil {
		t.Fatalf("expected no error with no leases, got %v", err)
	}
	if len(r.cmds) != 0 {
		t.Fatalf("expected no commands, got %v", r.cmds)
	}
}

func TestRenewDHCPLeases_MissingLeasesDirIsNotAnError(t *testing.T) {
	prev := leasesDir
	leasesDir = filepath.Join(t.TempDir(), "does-not-exist")
	t.Cleanup(func() { leasesDir = prev })

	r := &recordingRunner{}
	if err := RenewDHCPLeases(context.Background(), r); err != nil {
		t.Fatalf("a node without networkd leases must be a no-op, got %v", err)
	}
}

// lo must never be renewed even if something leaves a lease-shaped file for it.
func TestRenewDHCPLeases_NeverTouchesLoopback(t *testing.T) {
	fakeNet(t, map[string]string{"lo": "1", "enp6s18": "2"}, []string{"1", "2"})
	r := &recordingRunner{}

	if err := RenewDHCPLeases(context.Background(), r); err != nil {
		t.Fatal(err)
	}
	for _, c := range r.cmds {
		if strings.Contains(strings.Join(c, " "), " lo") {
			t.Fatalf("loopback was renewed: %v", r.cmds)
		}
	}
}

func TestRenewDHCPLeases_ReportsRunnerFailure(t *testing.T) {
	fakeNet(t, map[string]string{"enp6s18": "2"}, []string{"2"})
	r := &recordingRunner{err: os.ErrPermission}

	if err := RenewDHCPLeases(context.Background(), r); err == nil {
		t.Fatal("a failing networkctl must surface, not be swallowed")
	}
}
