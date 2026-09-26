package runtime

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/security"
)

// K5b (review round 6), end-to-end: an OLDER agent's attachModule, given a
// manifest declaring KnownCapabilities PLUS one name this binary does not
// recognize, must (a) NOT refuse the whole module (Validate no longer errors
// on an unknown name — DropUnknownCapabilities handles it first), (b) still
// treat the resulting (collapsed-to-exactly-known) set as FULL, so a forced
// drop-in write failure is EXEMPT rather than fail-closed, and (c) warn
// about the dropped name via OnError — a real signal, not silence.
func TestAttachModule_UnknownCapabilityFromNewerManifestIsDroppedNotRefused(t *testing.T) {
	dropIns := t.TempDir()
	t.Cleanup(security.SetSystemdDropInRootForTest(dropIns))
	rec := &mount.RecorderRunner{}
	r := liveReconciler(t, rec)

	allCaps := make([]any, 0, len(security.KnownCapabilities)+1)
	for c := range security.KnownCapabilities {
		allCaps = append(allCaps, c)
	}
	allCaps = append(allCaps, "CAP_FUTURE_THING_A_NEWER_AGENT_ADDED")

	mf := &manifest.Manifest{
		ID:                          "qga-like",
		Name:                        "qga-like",
		Digest:                      "d1",
		ServiceCapabilitiesPresence: true,
		Config:                      map[string]any{"security": map[string]any{"capabilities": allCaps, "user_namespace": false}},
		Services:                    []manifest.Service{{Name: "qga", StartCommand: "/bin/true"}},
	}

	var onErrors []string
	r.cfg.OnError = func(stage string, err error) { onErrors = append(onErrors, stage) }

	// Also force what WOULD be a fail-closed drop-in write failure — proving
	// the exemption still applies once the unknown name is dropped.
	unit := "powernode-qga-like-qga.service"
	dropInDir := filepath.Join(dropIns, unit+".d")
	if err := os.MkdirAll(dropInDir, 0o755); err != nil {
		t.Fatal(err)
	}
	blocked := filepath.Join(dropInDir, "capabilities.conf")
	if err := os.MkdirAll(blocked, 0o755); err != nil {
		t.Fatal(err)
	}

	if err := r.attachModule(context.Background(), mount.Module{ID: mf.ID, Digest: "d1", Priority: 1}, mf); err != nil {
		t.Fatalf("K5b REGRESSION: attachModule must NOT refuse the whole module over one unrecognized capability name (it must be dropped, not fatal): %v", err)
	}

	if !containsArg(onErrors, "reconciler:unknown_capability_dropped") {
		t.Errorf("K5b: expected a warning about the dropped capability name, got stages: %v", onErrors)
	}
	if containsArg(onErrors, "reconciler:security_dropin_fail_closed") {
		t.Errorf("K5b REGRESSION: the resolved ceiling (after dropping the unrecognized extra) collapses to EXACTLY KnownCapabilities, which must stay EXEMPT from the forced write failure, got stages: %v", onErrors)
	}
}
