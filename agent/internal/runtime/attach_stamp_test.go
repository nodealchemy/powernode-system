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

func TestAttachStamp_NilManifest(t *testing.T) {
	if got := (&Reconciler{}).attachStamp("m1", nil); got != "" {
		t.Fatalf("nil manifest should stamp empty, got %q", got)
	}
}

// A module with no services stamps on the agent version alone — it has no
// rendered output to describe. Pinned so the "" from RenderedServicesHash is a
// decision rather than an accident.
func TestAttachStamp_NoServices(t *testing.T) {
	r := &Reconciler{cfg: ReconcilerConfig{AgentVersion: "9.9.9"}}
	if got := r.attachStamp("m1", &manifest.Manifest{}); got != "|9.9.9" {
		t.Fatalf("stamp for a service-less module = %q, want %q", got, "|9.9.9")
	}
}
