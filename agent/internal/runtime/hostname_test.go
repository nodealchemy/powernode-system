package runtime

import (
	"path/filepath"
	"testing"
)

// TestDesiredHostnamePersistedPrecedence locks the mTLS-delivered hostname
// contract: the persisted node.name (from the /node_api/modules envelope) is
// authoritative, an empty push is a no-op, and updates overwrite. The fw-cfg
// path is absent in the test env, so an unpersisted node reads "".
func TestDesiredHostnamePersistedPrecedence(t *testing.T) {
	orig := assignedHostnamePath
	assignedHostnamePath = filepath.Join(t.TempDir(), "hostname")
	t.Cleanup(func() { assignedHostnamePath = orig })

	if got := desiredHostname(); got != "" {
		t.Fatalf("empty state: want \"\", got %q", got)
	}

	persistAssignedHostname("ops-hub")
	if got := desiredHostname(); got != "ops-hub" {
		t.Fatalf("persisted: want ops-hub, got %q", got)
	}

	// A blank push must not clobber the stored value.
	persistAssignedHostname("   ")
	if got := desiredHostname(); got != "ops-hub" {
		t.Fatalf("blank push should be a no-op: got %q", got)
	}

	// A changed name overwrites.
	persistAssignedHostname("ops-hub-b")
	if got := desiredHostname(); got != "ops-hub-b" {
		t.Fatalf("update: want ops-hub-b, got %q", got)
	}
}
