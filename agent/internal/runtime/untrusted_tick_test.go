package runtime

import (
	"context"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/lifecycle"
)

// IMP-1023e79cc82d — a tick whose answer from the platform cannot be trusted
// must retain what is attached, never detach it. Each test below drives one
// such input through RunOnce on a node that is NOT self-hosted (the one
// configuration with no other guard standing in the way).

// An attached module whose assignment arrives with NO digest is not a removal:
// the module is still assigned, and the platform merely failed to say which
// build it is (an unpublished or non-erofs artifact). It was detached, along
// with its declared users, because only a fetch failure was protected.
func TestRunOnce_DigestlessAssignmentRetainsTheAttachedModule(t *testing.T) {
	r, client, runner, _, statePath, manifestRoot, _ := upgradeTestReconciler(t)
	appUnit := lifecycle.UnitName("m1", "app")

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("pass 1 (attach m1): %v", err)
	}
	if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "d1" {
		t.Fatalf("precondition: m1 must be attached at d1, got %q ok=%v", digest, ok)
	}

	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture("", []string{"CAP_CHOWN"}, upgradeAppService)
	backdateManifestCache(t, manifestRoot, "m1")
	pre := len(runner.Invocations)

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("pass 2 (m1 digestless): %v", err)
	}

	if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "d1" {
		t.Errorf("a digestless assignment must not detach m1: attached digest = %q ok=%v", digest, ok)
	}
	if hasSystemctlOp(runner.Invocations[pre:], "stop", appUnit) {
		t.Errorf("a digestless assignment must not stop %s, invocations: %v", appUnit, runner.Invocations[pre:])
	}
}
