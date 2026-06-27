package security

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// withTempSystemdRootUserns mirrors the capabilities/seccomp drop-in test
// helpers — redirects systemdDropInRoot to a per-test tmp dir so the
// drop-in writer can be exercised without touching /etc/systemd.
func withTempSystemdRootUserns(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	original := systemdDropInRoot
	systemdDropInRoot = dir
	t.Cleanup(func() { systemdDropInRoot = original })
	return dir
}

func TestWriteUserNamespaceDropIn_EnabledEmitsPrivateUsersYes(t *testing.T) {
	root := withTempSystemdRootUserns(t)
	if err := WriteUserNamespaceDropIn("powernode-redis-redis.service", true); err != nil {
		t.Fatalf("WriteUserNamespaceDropIn: %v", err)
	}
	path := filepath.Join(root, "powernode-redis-redis.service.d", "userns.conf")
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read drop-in: %v", err)
	}
	s := string(body)
	if !strings.Contains(s, "[Service]\n") {
		t.Errorf("expected [Service] section; got %s", s)
	}
	if !strings.Contains(s, "PrivateUsers=yes\n") {
		t.Errorf("expected PrivateUsers=yes; got %s", s)
	}
	if strings.Contains(s, "PrivateUsers=no") {
		t.Errorf("unexpected PrivateUsers=no in enabled drop-in; got %s", s)
	}
}

func TestWriteUserNamespaceDropIn_DisabledEmitsPrivateUsersNo(t *testing.T) {
	root := withTempSystemdRootUserns(t)
	if err := WriteUserNamespaceDropIn("powernode-rawsock-rawsock.service", false); err != nil {
		t.Fatalf("WriteUserNamespaceDropIn: %v", err)
	}
	path := filepath.Join(root, "powernode-rawsock-rawsock.service.d", "userns.conf")
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read drop-in: %v", err)
	}
	s := string(body)
	if !strings.Contains(s, "PrivateUsers=no\n") {
		t.Errorf("expected PrivateUsers=no for host-namespace workloads; got %s", s)
	}
	if strings.Contains(s, "PrivateUsers=yes") {
		t.Errorf("unexpected PrivateUsers=yes in disabled drop-in; got %s", s)
	}
}

func TestWriteUserNamespaceDropIn_IsIdempotent(t *testing.T) {
	root := withTempSystemdRootUserns(t)
	unit := "powernode-base.service"
	if err := WriteUserNamespaceDropIn(unit, true); err != nil {
		t.Fatalf("first write: %v", err)
	}
	first, err := os.ReadFile(filepath.Join(root, unit+".d", "userns.conf"))
	if err != nil {
		t.Fatalf("read first: %v", err)
	}
	if err := WriteUserNamespaceDropIn(unit, true); err != nil {
		t.Fatalf("second write: %v", err)
	}
	second, err := os.ReadFile(filepath.Join(root, unit+".d", "userns.conf"))
	if err != nil {
		t.Fatalf("read second: %v", err)
	}
	if string(first) != string(second) {
		t.Errorf("drop-in not idempotent:\nfirst=%s\nsecond=%s", first, second)
	}
}

func TestWriteUserNamespaceDropIn_RejectsBadUnitNames(t *testing.T) {
	withTempSystemdRootUserns(t)
	for _, bad := range []string{"", "../escape", "foo/bar", "foo\x00null", "-leading-dash"} {
		if err := WriteUserNamespaceDropIn(bad, true); err == nil {
			t.Errorf("expected error for unit name %q", bad)
		}
	}
}
