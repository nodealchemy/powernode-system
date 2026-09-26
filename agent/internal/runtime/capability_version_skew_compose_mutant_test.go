package runtime

import (
	"context"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/security"
)

// TestRenderPivotUnits_UnknownCeilingCapabilityWarnsEvenWithNoServices is
// L5's mutant-killing test for compose.go's pivot-path
// policy.DropUnknownCapabilities() call (review round 7): removing that one
// call (~compose.go L254 at the time of the round-7 review) would pass
// EVERY OTHER existing test in this package.
//
// Why a service-LESS module specifically: security.ResolveServiceCapabilities
// (L4, review round 7) now ALSO drops an unrecognized name from the ceiling
// on its own, internally, the moment it is called for ANY service — so a
// manifest with at least one service makes compose.go's own explicit call
// REDUNDANT (confirmed empirically: reverting compose.go's call while
// keeping a one-service fixture still passed, because
// composeCapabilityWrites's per-service loop discovers and drops the same
// name on its own, and this file's OTHER OnError call site — added for L4
// — reports it just the same). A module with ZERO services never enters
// that loop at all (resolveUnitCapabilities' `for _, svc := range
// mf.Services` body never runs, so canonicalCapSet(ceiling) is never
// invoked from that path) — the ONLY remaining source of the warning for
// THIS shape is compose.go's own explicit, unconditional call. If that call
// is removed, a service-less module with a version-skew ceiling name
// produces NO warning at all — silently narrower, per DropUnknownCapabilities'
// own contract, but silence is exactly what this test refuses to accept
// (see that method's own "with a warning, not silence" doc).
func TestRenderPivotUnits_UnknownCeilingCapabilityWarnsEvenWithNoServices(t *testing.T) {
	sysroot := t.TempDir()
	r := newPivotReconciler(&mount.RecorderRunner{})

	allCaps := make([]any, 0, len(security.KnownCapabilities)+1)
	for c := range security.KnownCapabilities {
		allCaps = append(allCaps, c)
	}
	allCaps = append(allCaps, "CAP_FUTURE_THING_A_NEWER_AGENT_ADDED")

	mf := &manifest.Manifest{
		ID:       "content-only-module",
		Name:     "content-only-module",
		Config:   map[string]any{"security": map[string]any{"capabilities": allCaps}},
		Services: nil, // deliberately NO services — see doc comment above
	}

	var onErrors []string
	r.cfg.OnError = func(stage string, err error) { onErrors = append(onErrors, stage) }
	stack := mount.ModuleStack{{ID: mf.ID, Priority: 1}}
	manifests := map[string]*manifest.Manifest{mf.ID: mf}
	r.renderPivotUnits(context.Background(), sysroot, stack, manifests, &BootComposedBreadcrumb{})

	if !containsArg(onErrors, "compose:unknown_capability_dropped") {
		t.Errorf("L5 REGRESSION: expected a warning about the dropped capability name even for a service-less module "+
			"(compose.go's own DropUnknownCapabilities call is the ONLY source of it in this shape), got stages: %v", onErrors)
	}
}
