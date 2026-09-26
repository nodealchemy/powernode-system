package runtime

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/lifecycle"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/security"
)

func unpredictableApplyFixture(digest, selinuxProfile string) string {
	extra := ""
	if selinuxProfile != "" {
		extra = fmt.Sprintf(`, "selinux_profile": "%s"`, selinuxProfile)
	}
	return fmt.Sprintf(`{"success": true, "data": {"id":"m1", "name":"app-mod", "priority":100, "effective_priority":100, "digest":"%s",
	 "config": {"security": {"capabilities": ["CAP_CHOWN"], "user_namespace": false%s}},
	 "services": [{"name":"app", "start_command":"/bin/true", "restart_policy":"always"}]}}`, digest, extra)
}

// TestVersionBumpDetach_PersistentUnpredictableApplyFailureFlapsOnceThenIsRemembered
// is L2 part 1's own red-first test (review round 7, HIGH), distinct from
// TestVersionBumpDetach_UnresolvableSELinuxProfileNeverFlapsTheRunningUnit
// (L2 part 2, the PREDICTABLE case): here the profile NAME resolves for
// real (a file is provisioned under a temp SELinuxProfileDir) and the LSM
// is forced available (security.SetSELinuxAvailableForTest) — so
// Policy.PredictMACProfileFailure's pure pre-check has nothing to object
// to — but the actual `semodule -i` invocation is made to fail every time
// via the RecorderRunner's StubErr. This is exactly the residual class L2's
// own doc calls out: "a malformed compiled policy module semodule itself
// rejects" — something no side-effect-free pre-check can predict, since the
// only way to learn it is to actually run semodule.
//
// Expected shape: tick 2 (the first tick to see the bump) pays ONE
// unavoidable stop/start flap — this failure genuinely could not have been
// predicted before that tick tried it for real. Ticks 3+ must NOT repeat it:
// mount.State.FailedVersionBumps, written when tick 2's real attach failed,
// makes every later tick defer the same digest without ever touching the
// still-running old digest again.
func TestVersionBumpDetach_PersistentUnpredictableApplyFailureFlapsOnceThenIsRemembered(t *testing.T) {
	selinuxDir := t.TempDir()
	origDir := security.SELinuxProfileDir
	security.SELinuxProfileDir = selinuxDir
	t.Cleanup(func() { security.SELinuxProfileDir = origDir })
	t.Cleanup(security.SetSELinuxAvailableForTest(true))

	profilePath := filepath.Join(selinuxDir, "someprofile")
	if err := os.WriteFile(profilePath, []byte("fake compiled policy module"), 0o644); err != nil {
		t.Fatal(err)
	}
	resolvedProfilePath, err := filepath.EvalSymlinks(profilePath)
	if err != nil {
		t.Fatal(err)
	}

	tmpRoot := t.TempDir()
	statePath := filepath.Join(t.TempDir(), "state.json")
	t.Setenv("POWERNODE_LIFECYCLE_UNIT_DIR", t.TempDir())
	t.Cleanup(security.SetSystemdDropInRootForTest(t.TempDir()))

	client := &stubModulesClient{responses: map[string]string{
		"/api/v1/system/node_api/modules":    `{"success": true, "data": {"modules": [{"id":"m1", "name":"app-mod", "priority":100, "effective_priority":100, "has_data_file":true}]}}`,
		"/api/v1/system/node_api/modules/m1": unpredictableApplyFixture("abc123", ""),
	}}
	runner := &mount.RecorderRunner{
		StubErr: map[string]error{
			"semodule -i " + resolvedProfilePath: errors.New("semodule: rejected: malformed policy module (simulated, unpredictable ahead of time)"),
		},
	}
	r := versionBumpReconciler(t, tmpRoot, statePath, client, runner)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatal(err)
	}

	client.responses["/api/v1/system/node_api/modules/m1"] = unpredictableApplyFixture("def456", "someprofile")
	unit := lifecycle.UnitName("m1", "app")
	stops := 0
	for tick := 2; tick <= 4; tick++ {
		backdateManifestCache(t, filepath.Join(tmpRoot, "manifests"), "m1")
		start := len(runner.Invocations)
		if err := r.RunOnce(context.Background()); err != nil {
			t.Fatal(err)
		}
		inv := runner.Invocations[start:]
		d, _ := attachedDigest(t, statePath, "m1")
		stopped := hasSystemctlOp(inv, "stop", unit)
		t.Logf("tick %d: stop=%v start=%v digest=%s", tick, stopped, hasSystemctlOp(inv, "start", unit), d)
		if stopped {
			stops++
		}
		if tick == 2 {
			if d != "abc123" {
				t.Fatalf("tick 2: expected the old digest abc123 still attached after rollback, got %q", d)
			}
			st, lerr := mount.LoadState(statePath)
			if lerr != nil {
				t.Fatal(lerr)
			}
			if st.FailedVersionBumps["m1"] != "def456" {
				t.Errorf("L2 part 1 REGRESSION: expected FailedVersionBumps[m1]=def456 after tick 2's real attach failure, got %v", st.FailedVersionBumps)
			}
		} else if !stopped {
			// Ticks 3-4 must not even ATTEMPT a real attach of def456 again —
			// asserted structurally, not just by absence of a stop: no
			// invocation this tick should reference the semodule call at all.
			for _, i := range inv {
				if i.Name == "semodule" {
					t.Errorf("tick %d: expected NO semodule invocation (digest def456 is a known-failed bump target) — got %v", tick, i)
				}
			}
		}
	}
	if stops > 1 {
		t.Errorf("L2 part 1 REGRESSION: running unit %s stopped on %d ticks by a persistent, pre-check-invisible Apply failure — expected exactly ONE unavoidable flap (tick 2) and none afterward", unit, stops)
	}
	if got, _ := attachedDigest(t, statePath, "m1"); got != "abc123" {
		t.Errorf("expected the old digest abc123 to still be the attached one after every tick (never dropped from state.json), got %q", got)
	}
}
