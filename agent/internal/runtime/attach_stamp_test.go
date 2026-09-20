package runtime

import (
	"strings"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/lifecycle"
	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
)

// IMP-01a05efa — the re-attach stamp has TWO inputs, and each closes a
// different way for a renderer fix to never ship.
//
// Before this, the stamp was manifest.ServicesHash: a corrected RENDERER in a
// new agent binary left it byte-identical, so no module was queued for
// re-attach and the stale unit body stayed on disk until an unrelated manifest
// change or a hand-run ClearAttachedManifestHashes.

func stampFixture() *manifest.Manifest {
	return &manifest.Manifest{Services: []manifest.Service{
		{Name: "api", StartCommand: "/usr/bin/api", RestartPolicy: "always"},
	}}
}

func TestAttachStamp_CarriesTheRenderedOutput(t *testing.T) {
	r := &Reconciler{}
	mf := stampFixture()

	got := r.attachStamp("m1", mf)
	want := lifecycle.RenderedServicesHash("m1", mf.Services, pivotAwareRootMode())

	if !strings.HasPrefix(got, want) || want == "" {
		t.Fatalf("stamp %q does not carry the rendered hash %q", got, want)
	}
	// And it is NOT the manifest hash, which is the whole point.
	if strings.HasPrefix(got, mf.ServicesHash()) {
		t.Fatal("stamp still leads with the manifest hash")
	}
}

// The agent version is the belt to the rendered hash's braces: a change in an
// input the render path does not cover still forces one pass.
func TestAttachStamp_MovesWithTheAgentVersion(t *testing.T) {
	mf := stampFixture()

	older := (&Reconciler{cfg: ReconcilerConfig{AgentVersion: "1.0.0"}}).attachStamp("m1", mf)
	newer := (&Reconciler{cfg: ReconcilerConfig{AgentVersion: "1.0.1"}}).attachStamp("m1", mf)

	if older == newer {
		t.Fatal("an agent upgrade must move the stamp, so every module re-attaches once")
	}
}

// An empty AgentVersion is allowed — the rendered half still does the work,
// which is what keeps every existing fixture and the operator CLI working.
func TestAttachStamp_EmptyAgentVersionStillStamps(t *testing.T) {
	got := (&Reconciler{}).attachStamp("m1", stampFixture())
	if got == "" || got == "|" {
		t.Fatalf("stamp with no agent version should still carry the rendered hash, got %q", got)
	}
}

// THE DEFECT THIS TASK FIXES, DIRECTLY (IMP-f5c0afa7183a). Identical unit
// bodies, different security: block: the unit-body hash cannot tell these
// manifests apart (proven as an explicit precondition, reproducing the
// pre-fix bug) and the full stamp must.
func TestAttachStamp_MovesWhenOnlySecurityPolicyDiffers(t *testing.T) {
	r := &Reconciler{}
	// Deliberately two SEPARATE, independently-constructed slices (not one
	// shared `services` variable passed to both manifests) so the
	// precondition below is a real comparison — a future edit that
	// accidentally lets these two literals drift apart would fail the
	// precondition loudly, rather than the check being trivially true by
	// construction because both manifests pointed at the same slice.
	base := &manifest.Manifest{
		Services: []manifest.Service{{Name: "api", StartCommand: "/usr/bin/api"}},
		Config: map[string]any{
			"security": map[string]any{"capabilities": []any{"CAP_NET_BIND_SERVICE"}},
		},
	}
	changed := &manifest.Manifest{
		Services: []manifest.Service{{Name: "api", StartCommand: "/usr/bin/api"}},
		Config: map[string]any{
			"security": map[string]any{"capabilities": []any{"CAP_CHOWN"}},
		},
	}

	if lifecycle.RenderedServicesHash("m1", base.Services, pivotAwareRootMode()) !=
		lifecycle.RenderedServicesHash("m1", changed.Services, pivotAwareRootMode()) {
		t.Fatal("precondition: the unit-body hash should be identical for a security-only manifest change — " +
			"that identical-unit-body, different-security-block shape is exactly what made the pre-fix stamp blind")
	}

	if r.attachStamp("m1", base) == r.attachStamp("m1", changed) {
		t.Fatal("attachStamp did not move when only the module's security: block differed — " +
			"a manifest edit to security.capabilities alone would never re-attach on a live node")
	}
}

func TestAttachStamp_NilManifest(t *testing.T) {
	if got := (&Reconciler{}).attachStamp("m1", nil); got != "" {
		t.Fatalf("nil manifest should stamp empty, got %q", got)
	}
}

// A module with no services and no security: block stamps on the agent
// version alone — it has no rendered unit-body output AND no per-unit
// security-policy output to describe (RenderedPolicyHash omits
// capabilities/seccomp/userns entirely when hasUnits is false — see its own
// doc). Pinned so the double-empty leading segments are a decision rather
// than an accident: two hash components now (rendered unit bodies, rendered
// security policy) plus the agent-version tail, both "" here.
func TestAttachStamp_NoServices(t *testing.T) {
	r := &Reconciler{cfg: ReconcilerConfig{AgentVersion: "9.9.9"}}
	if got := r.attachStamp("m1", &manifest.Manifest{}); got != "||9.9.9" {
		t.Fatalf("stamp for a service-less module with no security: block = %q, want %q", got, "||9.9.9")
	}
}

// A module with no SERVICES (so no units, no per-unit drop-in writes) but a
// module-level security: block still has real output to describe: SELinux/
// AppArmor profile loading is per-MODULE (Policy.Apply runs unconditionally,
// before any per-unit loop), so it participates even when hasUnits is false.
// This is the case TestAttachStamp_NoServices deliberately does NOT cover.
func TestAttachStamp_NoServicesButSELinuxProfileDeclared(t *testing.T) {
	r := &Reconciler{cfg: ReconcilerConfig{AgentVersion: "9.9.9"}}
	mf := &manifest.Manifest{Config: map[string]any{
		"security": map[string]any{"selinux_profile": "my-policy"},
	}}
	if got := r.attachStamp("m1", mf); got == "||9.9.9" {
		t.Fatal("a service-less module's declared selinux_profile must still contribute to the stamp — it is applied per-module, not per-unit")
	}
}
