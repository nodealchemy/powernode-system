package runtime

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/lifecycle"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/security"
)

func differingCapsFixture(digest string, caps ...string) string {
	quoted := ""
	for i, c := range caps {
		if i > 0 {
			quoted += ", "
		}
		quoted += fmt.Sprintf("%q", c)
	}
	return fmt.Sprintf(`{"success": true, "data": {"id":"m1", "name":"app-mod", "priority":100, "effective_priority":100, "digest":"%s",
	 "config": {"security": {"capabilities": [%s], "user_namespace": true}},
	 "services": [{"name":"app", "start_command":"/bin/true", "restart_policy":"always"}]}}`, digest, quoted)
}

// TestVersionBumpDetach_DeferredBumpNeverRewritesTheOldDigestsRealCapabilitiesDropIn
// is L5(a)'s mutant-killing test (review round 7): swapping
// filterUnsafeVersionBumpDetaches's pre-check call
// (wouldModuleSecurityPolicyRefuse, K1) back to the EFFECTFUL
// applyModuleSecurityPolicy must fail a test — DRIVEN THROUGH THE FILTER /
// RunOnce, not by calling either helper function directly (unlike this
// file's sibling version_bump_precheck_side_effects_test.go, which pins the
// SAME property on the standalone function and would not notice a mutation
// to what filterUnsafeVersionBumpDetaches itself calls).
//
// THE DISCRIMINATOR. A blocking fixture that makes the WHOLE precheck refuse
// (e.g. a directory sitting on capabilities.conf, as J1's own
// TestVersionBumpDetach_RefusedNewDigestKeepsOldUnitsRunning uses) fails
// IDENTICALLY whether the precheck is pure or effectful — the write itself
// errors before anything could be observed either way, so that fixture
// cannot distinguish the two. Instead: the OLD digest's ceiling is
// [CAP_CHOWN] and the NEW digest's is [CAP_CHOWN, CAP_FOWNER] — genuinely
// DIFFERENT capabilities.conf content — and ONLY userns.conf's directory is
// blocked. applyModuleSecurityDropIns writes userNamespace FIRST per unit,
// then (since the module is not privileged) seccomp/capability SECOND for
// the SAME unit — so an EFFECTFUL run would refuse on userns.conf but still
// go on to WRITE capabilities.conf for real with the NEW digest's content,
// even though the whole attach is refused overall. The pure pre-check
// (correct code) never reaches any real writer at all, so
// capabilities.conf stays exactly what the OLD digest's own successful
// attach wrote.
func TestVersionBumpDetach_DeferredBumpNeverRewritesTheOldDigestsRealCapabilitiesDropIn(t *testing.T) {
	tmpRoot := t.TempDir()
	statePath := filepath.Join(t.TempDir(), "state.json")
	dropIns := t.TempDir()
	t.Cleanup(security.SetSystemdDropInRootForTest(dropIns))
	t.Setenv("POWERNODE_LIFECYCLE_UNIT_DIR", t.TempDir())

	client := &stubModulesClient{responses: map[string]string{
		"/api/v1/system/node_api/modules":    `{"success": true, "data": {"modules": [{"id":"m1", "name":"app-mod", "priority":100, "effective_priority":100, "has_data_file":true}]}}`,
		"/api/v1/system/node_api/modules/m1": differingCapsFixture("abc123", "CAP_CHOWN"),
	}}
	runner := &mount.RecorderRunner{}
	r := versionBumpReconciler(t, tmpRoot, statePath, client, runner)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1: %v", err)
	}

	unit := lifecycle.UnitName("m1", "app")
	capPath := filepath.Join(dropIns, unit+".d", "capabilities.conf")
	oldCapContent, err := os.ReadFile(capPath)
	if err != nil {
		t.Fatalf("test setup: expected capabilities.conf after pass 1's real attach: %v", err)
	}

	// Block ONLY userns.conf's path with a directory — capabilities.conf is
	// left completely unobstructed, so an effectful run's capability write
	// would succeed for real.
	unsPath := filepath.Join(dropIns, unit+".d", "userns.conf")
	if err := os.RemoveAll(unsPath); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(unsPath, 0o755); err != nil {
		t.Fatal(err)
	}

	client.responses["/api/v1/system/node_api/modules/m1"] = differingCapsFixture("def456", "CAP_CHOWN", "CAP_FOWNER")
	backdateManifestCache(t, filepath.Join(tmpRoot, "manifests"), "m1")
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 2: %v", err)
	}

	if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "abc123" {
		t.Fatalf("test setup: expected the bump to be deferred (old digest abc123 still attached), got digest=%q ok=%v", digest, ok)
	}

	afterCapContent, err := os.ReadFile(capPath)
	if err != nil {
		t.Fatalf("capabilities.conf missing after the deferred tick: %v", err)
	}
	if string(afterCapContent) != string(oldCapContent) {
		t.Errorf("L5(a) REGRESSION: filterUnsafeVersionBumpDetaches's pre-check ran an EFFECTFUL write against the "+
			"still-running OLD digest's real capabilities.conf during a deferred tick — content changed from\n%q\nto\n%q",
			oldCapContent, afterCapContent)
	}
}
