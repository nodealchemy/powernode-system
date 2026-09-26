package runtime

import (
	"context"
	"fmt"
	"path/filepath"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/lifecycle"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/security"
)

// reviewFixtureSel is the fixture the round-7 review's own repro used
// (renamed from its scratch-file original for clarity, kept close to its
// literal wording): a module with (optionally) a security.selinux_profile
// name that this test never provisions under security.SELinuxProfileDir, so
// resolving it always fails — the PREDICTABLE Apply failure mode L2 part 2
// (Policy.PredictMACProfileFailure) targets.
func reviewFixtureSel(digest, sel string) string {
	extra := ""
	if sel != "" {
		extra = fmt.Sprintf(`, "selinux_profile": "%s"`, sel)
	}
	return fmt.Sprintf(`{"success": true, "data": {"id":"m1", "name":"app-mod", "priority":100, "effective_priority":100, "digest":"%s",
	 "config": {"security": {"capabilities": ["CAP_CHOWN"], "user_namespace": false%s}},
	 "services": [{"name":"app", "start_command":"/bin/true", "restart_policy":"always"}]}}`, digest, extra)
}

// TestVersionBumpDetach_UnresolvableSELinuxProfileNeverFlapsTheRunningUnit is
// the round-7 review's own repro test (L1+L2, copied from its scratch file
// per team-lead's instruction, renamed sensibly here). Before L1+L2: tick 2
// detaches the old (abc123) digest, the new (def456) digest's Apply fails
// resolving "someprofile" (never provisioned on disk), rollback re-attaches
// abc123 — one flap, survivable — but the on-disk manifest cache is now
// holding def456's content keyed by module ID alone (L1's bug), so tick 3's
// rollback attempt uses the WRONG manifest, fails, and DROPS the module from
// state.json entirely; tick 4 has nothing left to even try. After L1
// (digest-keyed attached-snapshot store) + L2 part 2 (a pure pre-check that
// predicts an unresolvable profile name without touching the LSM): the
// pre-check defers the bump on EVERY tick before ever detaching the running
// old digest, so this specific (predictable) failure mode produces ZERO
// stop/start cycles, not merely "at most one" — see
// TestVersionBumpDetach_PersistentUnpredictableApplyFailureFlapsOnceThenIsRemembered
// for the genuinely unpredictable case L2 part 1 (FailedVersionBumps) exists
// for, where one initial flap is unavoidable.
func TestVersionBumpDetach_UnresolvableSELinuxProfileNeverFlapsTheRunningUnit(t *testing.T) {
	tmpRoot := t.TempDir()
	statePath := filepath.Join(t.TempDir(), "state.json")
	t.Setenv("POWERNODE_LIFECYCLE_UNIT_DIR", t.TempDir())
	t.Cleanup(security.SetSystemdDropInRootForTest(t.TempDir()))
	client := &stubModulesClient{responses: map[string]string{
		"/api/v1/system/node_api/modules":    `{"success": true, "data": {"modules": [{"id":"m1", "name":"app-mod", "priority":100, "effective_priority":100, "has_data_file":true}]}}`,
		"/api/v1/system/node_api/modules/m1": reviewFixtureSel("abc123", ""),
	}}
	runner := &mount.RecorderRunner{}
	r := versionBumpReconciler(t, tmpRoot, statePath, client, runner)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatal(err)
	}
	client.responses["/api/v1/system/node_api/modules/m1"] = reviewFixtureSel("def456", "someprofile")
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
		t.Logf("tick %d: stop=%v start=%v digest=%s", tick, hasSystemctlOp(inv, "stop", unit), hasSystemctlOp(inv, "start", unit), d)
		if hasSystemctlOp(inv, "stop", unit) {
			stops++
		}
	}
	if stops > 0 {
		t.Errorf("L1/L2 REGRESSION: running unit %s stopped on %d tick(s) by an unresolvable selinux_profile — this failure mode is PREDICTABLE ahead of time (Policy.PredictMACProfileFailure) and the pre-check must defer the bump before ever detaching the running old digest, not merely limit the flap to one", unit, stops)
	}
}
