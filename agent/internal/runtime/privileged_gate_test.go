package runtime

import (
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
)

// IMP-01a02f70-20b1 — security.privileged=true disables ALL on-node
// confinement, and before this fix the agent honoured it straight from the
// module manifest with no operator approval anywhere. The gate: privileged is
// honoured ONLY when the module's server-assigned id appears in the
// operator-controlled allowlist (AssignmentMeta.PrivilegedModuleIDs), which the
// module cannot author. The server resolves any operator-supplied NAMES to ids
// before sending them, so the agent matches on the immutable id ONLY (F1).

const devcellNodeModuleID = "019f7cb5-3858-7000-8000-0000dc000001"

func devcellManifest() *manifest.Manifest {
	return &manifest.Manifest{
		ID:   devcellNodeModuleID,
		Name: "dev-cell",
		Config: map[string]any{
			"security": map[string]any{"privileged": true},
		},
	}
}

// Default-DENY: an empty allowlist approves nothing; buildPolicy still PARSES
// the request but privilegedApproved reports false.
func TestPrivilegedApproved_DefaultDeny(t *testing.T) {
	mf := devcellManifest()
	if got := buildPolicy(mf); !got.Privileged {
		t.Fatal("buildPolicy should still PARSE the privileged request")
	}
	if privilegedApproved(mf.ID, nil) {
		t.Error("empty allowlist must DENY (default-deny)")
	}
	if privilegedApproved(mf.ID, []string{"some-other-id"}) {
		t.Error("a module id absent from the allowlist must be denied")
	}
}

// Granted only by the immutable id. dev-cell keeps working once the operator's
// allowlist names its NodeModule id (the server resolves the operator's
// "dev-cell" name to this id), without blanket-permitting.
func TestPrivilegedApproved_GrantsByIDOnly(t *testing.T) {
	mf := devcellManifest()
	if !privilegedApproved(mf.ID, []string{devcellNodeModuleID}) {
		t.Error("allowlist containing the module id must GRANT")
	}
	// The gate must NOT grant on the module NAME — names are mutable/
	// author-influenced; name→id resolution is the server's job (F1).
	if privilegedApproved(mf.ID, []string{"dev-cell"}) {
		t.Error("gate must not grant on a module name, only on the server-assigned id")
	}
	if privilegedApproved("", []string{""}) {
		t.Error("empty id must never match an empty allowlist entry")
	}
}

// The gate can NEVER be satisfied by module-controlled input: the allowlist is
// the only thing that grants, it is compared against the immutable id, and it
// is not authored by the module.
func TestPrivilegedApproved_NotSatisfiableByManifest(t *testing.T) {
	mf := &manifest.Manifest{
		ID:   "019f7cb5-3858-7000-8000-0000ee000001",
		Name: "evil",
		Config: map[string]any{
			"security":              map[string]any{"privileged": true},
			"privileged_module_ids": []any{"019f7cb5-3858-7000-8000-0000ee000001"}, // module-authored — must be ignored
			"approved":              true,
		},
	}
	if privilegedApproved(mf.ID, nil) {
		t.Error("module-authored config must never satisfy the privileged gate")
	}
}
