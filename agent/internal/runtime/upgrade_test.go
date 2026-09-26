package runtime

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/etcidentity"
	"github.com/nodealchemy/powernode-system/agent/internal/lifecycle"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/security"
)

// upgradeModulesListFixture is the "/api/v1/system/node_api/modules" body
// every test below shares: a single assigned module m1 with a data file.
const upgradeModulesListFixture = `{
	"success": true,
	"data": {"modules": [
		{"id":"m1", "name":"app-mod", "priority":100, "effective_priority":100, "has_data_file":true}
	]}
}`

// upgradeModuleFixture is versionBumpFixture generalized to an arbitrary
// capability list and service set, so the round-9 refusal-class tests below
// can make the OLD and NEW manifests differ in ways versionBumpFixture's
// fixed body cannot (a second service, a different capability list).
func upgradeModuleFixture(digest string, capabilities []string, services string) string {
	capJSON := "["
	for i, c := range capabilities {
		if i > 0 {
			capJSON += ","
		}
		capJSON += fmt.Sprintf("%q", c)
	}
	capJSON += "]"
	return fmt.Sprintf(`{
		"success": true,
		"data": {
			"id":"m1", "name":"app-mod",
			"priority":100, "effective_priority":100,
			"digest":"%s",
			"config": {"security": {"capabilities": %s, "user_namespace": false}},
			"services": [%s]
		}
	}`, digest, capJSON, services)
}

// upgradeModuleFixtureWithUserNS is upgradeModuleFixture with an explicit
// user_namespace value — needed only where a test must observe a drop-in
// file OTHER than capabilities.conf change (e.g. capabilities.conf itself
// is deliberately blocked), since userns.conf is written unconditionally
// (applyModuleSecurityDropIns) and so is a legible witness whenever
// capabilities.conf can't be.
func upgradeModuleFixtureWithUserNS(digest string, capabilities []string, userNS bool, services string) string {
	capJSON := "["
	for i, c := range capabilities {
		if i > 0 {
			capJSON += ","
		}
		capJSON += fmt.Sprintf("%q", c)
	}
	capJSON += "]"
	return fmt.Sprintf(`{
		"success": true,
		"data": {
			"id":"m1", "name":"app-mod",
			"priority":100, "effective_priority":100,
			"digest":"%s",
			"config": {"security": {"capabilities": %s, "user_namespace": %v}},
			"services": [%s]
		}
	}`, digest, capJSON, userNS, services)
}

const upgradeAppService = `{"name":"app", "start_command":"/bin/true", "restart_policy":"always"}`
const upgradeWorkerService = `{"name":"old-worker", "start_command":"/bin/true", "restart_policy":"always"}`

// upgradeZWorkerService sorts AFTER "app" under topoSort's lexicographic
// tiebreak (no declared dependency edges between the two) — needed only by
// M9's own test, which requires app's own restart to succeed BEFORE
// zworker's fails, to exercise a genuine partial multi-unit restart.
const upgradeZWorkerService = `{"name":"zworker", "start_command":"/bin/true", "restart_policy":"always"}`

// upgradeCredService models a run-once credential-fetch/provisioning unit
// (N1, review round 11): this codebase renders every unit Type=simple
// (lifecycle.RenderUnitModeGraph) — there is no manifest-level oneshot/
// RemainAfterExit support — so "ran once and exited cleanly" is
// indistinguishable, at the manifest level, from any other simple unit; what
// makes it oneshot-shaped in these tests is that it is NEVER stubbed active,
// before or after a restart, exactly like claude-tmux's credential unit,
// grok-cli, or dev-cell's own credential/provision units in production.
const upgradeCredService = `{"name":"cred", "start_command":"/bin/true", "restart_policy":"never"}`

// upgradeTestReconciler wires a Reconciler + client + RecorderRunner for a
// single-module round-9 in-place-upgrade scenario, with the systemd unit
// dir and drop-in root both redirected to fresh temp dirs — see the round-9
// summary's note that lifecycle.UnitDir() and security's systemdDropInRoot
// are two INDEPENDENT overrides that must both be set for a test to see a
// consistent on-disk picture.
func upgradeTestReconciler(t *testing.T) (r *Reconciler, client *stubModulesClient, runner *mount.RecorderRunner, layout mount.Layout, statePath, manifestRoot, dropInRoot string) {
	t.Helper()
	tmpRoot := t.TempDir()
	statePath = filepath.Join(t.TempDir(), "state.json")
	manifestRoot = filepath.Join(tmpRoot, "manifests")
	// security.SystemdDropInRoot and lifecycle.UnitDir() are two
	// INDEPENDENTLY overridable roots that both default to the SAME real
	// path (/etc/systemd/system) in production — stopDepartingUnits's own
	// cleanup (unit file under UnitDir(), drop-in ".d" dir under the
	// drop-in root) only ever removes the right ".d" directory when both
	// test overrides point at the SAME directory, exactly mirroring that
	// production identity.
	dropInRoot = t.TempDir()
	t.Cleanup(security.SetSystemdDropInRootForTest(dropInRoot))
	t.Setenv("POWERNODE_LIFECYCLE_UNIT_DIR", dropInRoot)

	client = &stubModulesClient{responses: map[string]string{
		"/api/v1/system/node_api/modules":    upgradeModulesListFixture,
		"/api/v1/system/node_api/modules/m1": upgradeModuleFixture("d1", []string{"CAP_CHOWN"}, upgradeAppService),
	}}
	runner = &mount.RecorderRunner{}
	r = versionBumpReconciler(t, tmpRoot, statePath, client, runner)
	layout = mount.DefaultLayout()
	layout.Root = tmpRoot
	layout = layout.Resolve()
	return
}

// TestUpgradeModule_DeltaStopHappensOnlyAfterNewUnitStarts pins the ORDER
// team-lead's round-9 point 5 requires: a departing unit (one the OLD
// digest owned that the NEW manifest no longer names) is stopped ONLY
// AFTER the new digest's own unit has already been started, and a unit
// that survives the bump (same name in both manifests) is never stopped at
// all — upgradeModule's step 5 delta-stop runs strictly after step 4's
// attach succeeds, never before.
func TestUpgradeModule_DeltaStopHappensOnlyAfterNewUnitStarts(t *testing.T) {
	r, client, runner, _, statePath, manifestRoot, _ := upgradeTestReconciler(t)

	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture(
		"d1", []string{"CAP_CHOWN"}, upgradeAppService+","+upgradeWorkerService)

	appUnit := lifecycle.UnitName("m1", "app")
	workerUnit := lifecycle.UnitName("m1", "old-worker")

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1: %v", err)
	}
	if !hasSystemctlOp(runner.Invocations, "start", appUnit) || !hasSystemctlOp(runner.Invocations, "start", workerUnit) {
		t.Fatalf("pass 1: expected both units started, invocations: %v", runner.Invocations)
	}

	// Bump: the new manifest drops old-worker entirely (a renamed/removed
	// service), keeping only app under the same unit name.
	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture("d2", []string{"CAP_CHOWN"}, upgradeAppService)
	backdateManifestCache(t, manifestRoot, "m1")
	// M1 (review round 9): mark app ACTIVE so ForceRestartActive's decision
	// is actually observable — a "start" is a no-op systemd wouldn't even
	// need to distinguish from "restart" for an inactive unit, so this test
	// must not accept a plain start as proof (that was M1's own bug: an
	// unchanged services: block silently degraded to a no-op start).
	runner.StubOutput = map[string][]byte{"systemctl is-active " + appUnit: []byte("active\n")}

	pass2Start := len(runner.Invocations)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 2: %v", err)
	}
	pass2 := runner.Invocations[pass2Start:]

	appStartIdx, workerStopIdx := -1, -1
	for i, inv := range pass2 {
		if inv.Name != "systemctl" || inv.Op != "Run" {
			continue
		}
		if containsArg(inv.Args, appUnit) && containsArg(inv.Args, "restart") && appStartIdx == -1 {
			appStartIdx = i
		}
		// M1 REGRESSION check: a plain `start` of the surviving, ACTIVE unit
		// is the exact bug — it means ForceRestartActive did not fire and
		// the old binary kept running.
		if containsArg(inv.Args, appUnit) && containsArg(inv.Args, "start") {
			t.Errorf("M1 REGRESSION: %s was `start`-ed instead of `restart`-ed while active — the old binary is still running: %v", appUnit, pass2)
		}
		if containsArg(inv.Args, workerUnit) && containsArg(inv.Args, "stop") && workerStopIdx == -1 {
			workerStopIdx = i
		}
		// The surviving unit (app) must NEVER be stopped by the bump.
		if containsArg(inv.Args, appUnit) && containsArg(inv.Args, "stop") {
			t.Errorf("round 9 REGRESSION: a unit that survives the bump (%s) must never be stopped, invocations: %v", appUnit, pass2)
		}
	}
	if appStartIdx == -1 {
		t.Fatalf("pass 2: expected %s to be restarted, invocations: %v", appUnit, pass2)
	}
	// M5 (review round 9): daemon-reload must run BEFORE the restart —
	// step 2 wrote new drop-ins for a body-unchanged unit, invisible to
	// anyWritten, so a manager that hasn't reloaded risks restarting
	// against stale cached drop-in state.
	reloadIdx := -1
	for i, inv := range pass2 {
		if inv.Name == "systemctl" && inv.Op == "Run" && containsArg(inv.Args, "daemon-reload") {
			reloadIdx = i
			break
		}
	}
	if reloadIdx == -1 {
		t.Errorf("M5 REGRESSION: expected a daemon-reload in pass 2 even though app's unit BODY did not change, invocations: %v", pass2)
	} else if reloadIdx > appStartIdx {
		t.Errorf("M5 REGRESSION: daemon-reload (index %d) ran AFTER the restart (index %d): %v", reloadIdx, appStartIdx, pass2)
	}
	if workerStopIdx == -1 {
		t.Fatalf("pass 2: expected the departing unit %s to be stopped, invocations: %v", workerUnit, pass2)
	}
	if workerStopIdx < appStartIdx {
		t.Errorf("round 9 REGRESSION: departing unit %s stopped (index %d) BEFORE the new unit %s started (index %d) — violates the never-leave-a-running-module-stopped invariant: %v",
			workerUnit, workerStopIdx, appUnit, appStartIdx, pass2)
	}
	if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "d2" {
		t.Errorf("pass 2: expected m1 attached at d2, got digest=%q ok=%v", digest, ok)
	}
}

// upgradeModuleFixtureWithOldUser is a one-off raw fixture body (not built
// via upgradeModuleFixture, which has no users: support) for M3's own test:
// the OLD digest declares a platform-managed user the NEW digest drops.
func upgradeModuleFixtureWithOldUser(digest string) string {
	return fmt.Sprintf(`{
		"success": true,
		"data": {
			"id":"m1", "name":"app-mod",
			"priority":100, "effective_priority":100,
			"digest":"%s",
			"config": {"security": {"capabilities": ["CAP_CHOWN"], "user_namespace": false}},
			"users": [{"name":"olduser","uid":5001,"primary_gid":5001,"primary_group":"olduser","shell":"/bin/false","home":"/home/olduser"}],
			"services": [%s]
		}
	}`, digest, upgradeAppService)
}

// TestReconcile_DuplicateStateEntryNeverStopsTheLiveModule is M4 fix (b)'s
// own test (review round 9, hard invariant): a pre-existing DUPLICATE
// state.json entry for one module ID at two digests — d1 (stale) and d2
// (the one `desired` actually names) — must never make the next RunOnce
// tick treat d1 as a genuine removal and stop the unit both entries share
// the same name for. The stale entry is silently dropped from state
// instead.
func TestReconcile_DuplicateStateEntryNeverStopsTheLiveModule(t *testing.T) {
	r, client, runner, _, statePath, _, _ := upgradeTestReconciler(t)
	unit := lifecycle.UnitName("m1", "app")

	// desired names ONLY d2 (upgradeModuleFixture default in upgradeTestReconciler
	// is d1 — override to d2 so the pre-seeded state below is the duplicate).
	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture("d2", []string{"CAP_CHOWN"}, upgradeAppService)

	if err := mount.SaveState(statePath, &mount.State{
		AttachedModules: []mount.Module{
			{ID: "m1", Digest: "d1", Priority: 100, Units: []string{unit}},
			{ID: "m1", Digest: "d2", Priority: 100, Units: []string{unit}},
		},
		LastAttachedManifestHashes: map[string]string{},
	}); err != nil {
		t.Fatalf("SaveState: %v", err)
	}

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}
	if hasSystemctlOp(runner.Invocations, "stop", unit) {
		t.Errorf("M4 REGRESSION: a duplicate state entry for a still-desired module must never stop %s, invocations: %v", unit, runner.Invocations)
	}

	st, err := mount.LoadState(statePath)
	if err != nil {
		t.Fatalf("LoadState: %v", err)
	}
	count := 0
	for _, m := range st.AttachedModules {
		if m.ID == "m1" {
			count++
			if m.Digest != "d2" {
				t.Errorf("M4 REGRESSION: expected the surviving m1 entry to be at d2, got %s", m.Digest)
			}
		}
	}
	if count != 1 {
		t.Errorf("M4 REGRESSION: expected exactly one m1 entry after the tick (the stale d1 duplicate dropped), got %d: %+v", count, st.AttachedModules)
	}
}

// TestAttachOne_DigestChangeRoutesThroughUpgradeNeverAppendsDuplicate is M4
// fix (a)'s own test: calling AttachOne for a module already attached at a
// DIFFERENT digest must REPLACE the state entry (via upgradeModule), never
// append a second one for the same ID — the shape that produced M4's bug in
// the first place.
func TestAttachOne_DigestChangeRoutesThroughUpgradeNeverAppendsDuplicate(t *testing.T) {
	r, client, runner, _, statePath, manifestRoot, _ := upgradeTestReconciler(t)
	unit := lifecycle.UnitName("m1", "app")

	status, err := r.AttachOne(context.Background(), "m1")
	if err != nil {
		t.Fatalf("AttachOne (fresh): %v", err)
	}
	if status != "attached" {
		t.Fatalf("AttachOne (fresh): expected status=attached, got %q", status)
	}

	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture("d2", []string{"CAP_CHOWN"}, upgradeAppService)
	backdateManifestCache(t, manifestRoot, "m1")
	// M6: the settled unit must read active for the upgrade to commit.
	runner.StubOutput = map[string][]byte{"systemctl is-active " + unit: []byte("active\n")}

	status, err = r.AttachOne(context.Background(), "m1")
	if err != nil {
		t.Fatalf("AttachOne (digest change): %v", err)
	}
	if status != "attached" {
		t.Fatalf("AttachOne (digest change): expected status=attached, got %q", status)
	}

	st, err := mount.LoadState(statePath)
	if err != nil {
		t.Fatalf("LoadState: %v", err)
	}
	count := 0
	for _, m := range st.AttachedModules {
		if m.ID == "m1" {
			count++
			if m.Digest != "d2" {
				t.Errorf("expected the surviving m1 entry to be at d2, got %s", m.Digest)
			}
		}
	}
	if count != 1 {
		t.Errorf("M4 REGRESSION: AttachOne appended a DUPLICATE state entry for m1 instead of replacing it, got %d entries: %+v", count, st.AttachedModules)
	}
	if !hasSystemctlOp(runner.Invocations, "restart", unit) && !hasSystemctlOp(runner.Invocations, "start", unit) {
		t.Errorf("expected %s to have been started at least once across both AttachOne calls, invocations: %v", unit, runner.Invocations)
	}
}

// TestUpgradeModule_PendingUpgradeStillRendersOldUser is M3's own test (the
// HARD INVARIANT: never leave a previously running module unable to
// restart). The OLD digest declares olduser; the NEW digest drops it; step
// 2 (the security drop-in write) is blocked. Before the RunOnce this tick
// completes, the identity render must STILL include olduser — dropping it
// the moment the new manifest is merely FETCHED (not yet committed) would
// mean the still-running old unit's next crash-restart fails 217/USER, the
// 2026-09-22 outage class.
func TestUpgradeModule_PendingUpgradeStillRendersOldUser(t *testing.T) {
	tmpRoot := t.TempDir()
	statePath := filepath.Join(t.TempDir(), "state.json")
	manifestRoot := filepath.Join(tmpRoot, "manifests")
	dropInRoot := t.TempDir()
	t.Cleanup(security.SetSystemdDropInRootForTest(dropInRoot))
	t.Setenv("POWERNODE_LIFECYCLE_UNIT_DIR", t.TempDir())

	client := &stubModulesClient{responses: map[string]string{
		"/api/v1/system/node_api/modules":    upgradeModulesListFixture,
		"/api/v1/system/node_api/modules/m1": upgradeModuleFixtureWithOldUser("d1"),
	}}
	runner := &mount.RecorderRunner{}
	r := versionBumpReconciler(t, tmpRoot, statePath, client, runner)

	var captured *etcidentity.Set
	origIdentity := applyIdentity
	applyIdentity = func(set *etcidentity.Set) error { captured = set; return nil }
	t.Cleanup(func() { applyIdentity = origIdentity })

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1: %v", err)
	}
	if captured == nil || !hasUser(captured, "olduser") {
		t.Fatalf("precondition: pass 1 must render olduser, got %+v", captured)
	}

	// Bump to a digest that DROPS olduser entirely, and block step 2's
	// drop-in write so the upgrade never commits.
	unit := lifecycle.UnitName("m1", "app")
	blocked := filepath.Join(dropInRoot, unit+".d", "capabilities.conf")
	if err := os.RemoveAll(blocked); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(blocked, 0o755); err != nil {
		t.Fatal(err)
	}
	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture("d2", []string{"CAP_CHOWN"}, upgradeAppService)
	backdateManifestCache(t, manifestRoot, "m1")

	captured = nil
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 2: %v", err)
	}
	if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "d1" {
		t.Fatalf("pass 2: expected the blocked upgrade to leave m1 at d1, got digest=%q ok=%v", digest, ok)
	}
	if captured == nil || !hasUser(captured, "olduser") {
		t.Errorf("M3 REGRESSION: a pending (blocked) upgrade must still render olduser — the OLD unit is still running and may crash-restart against a passwd that no longer has it, got %+v", captured)
	}

	// N3 (review round 11, adapted from reviewer A's
	// TestR10A_IdentityUnionLostOnSecondFailedTick): a SECOND consecutive
	// blocked tick must ALSO still render olduser. Before N3, the identity
	// union's old side came from previousManifests — RunOnce's own ID-keyed
	// pre-fetch disk snapshot, captured fresh at the top of EVERY tick from
	// whatever the LAST fetch wrote to the on-disk cache. Pass 2's own
	// fetch (the d2 manifest, dropping olduser) already overwrote that
	// cache before pass 2 even finished, so pass 3's previousManifests
	// snapshot read back d2 — the "new" manifest — as if it were the old
	// one, reverting the union to new-only and dropping olduser while the
	// OLD unit (still running d1) was never actually touched.
	captured = nil
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 3: %v", err)
	}
	if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "d1" {
		t.Fatalf("pass 3: expected the still-blocked upgrade to leave m1 at d1, got digest=%q ok=%v", digest, ok)
	}
	if captured == nil || !hasUser(captured, "olduser") {
		t.Errorf("N3 REGRESSION: a SECOND consecutive blocked tick must still render olduser — got %+v", captured)
	}
}

func hasUser(set *etcidentity.Set, name string) bool {
	for _, u := range set.Users {
		if u.Name == name {
			return true
		}
	}
	return false
}

// TestUpgradeModule_PreRound9EntryPersistsUnitsAcrossAFailedFirstAttempt is
// M7's own test (review round 9, LOW): a pre-round-9 state entry (no
// persisted Units — the field didn't exist yet) upgrading a RENAMED
// service. The first attempt fails (before the fallback-derived Units list
// would ever be used for anything irreversible); the second attempt
// succeeds. The renamed-away old unit must still be stopped on the second
// attempt — proving the fallback resolved on attempt 1 was PERSISTED, not
// silently lost the moment that attempt failed.
func TestUpgradeModule_PreRound9EntryPersistsUnitsAcrossAFailedFirstAttempt(t *testing.T) {
	r, client, runner, _, statePath, manifestRoot, dropInRoot := upgradeTestReconciler(t)

	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture("d1", []string{"CAP_CHOWN"}, upgradeWorkerService)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1: %v", err)
	}

	// Simulate a PRE-ROUND-9 entry: strip the Units the real attach just
	// persisted, so upgradeModule's own fallback (oldMf.UnitNames()) is the
	// ONLY source until M7's persist-once logic writes it back.
	st, err := mount.LoadState(statePath)
	if err != nil {
		t.Fatalf("LoadState: %v", err)
	}
	for i := range st.AttachedModules {
		if st.AttachedModules[i].ID == "m1" {
			st.AttachedModules[i].Units = nil
		}
	}
	if err := mount.SaveState(statePath, st); err != nil {
		t.Fatalf("SaveState: %v", err)
	}

	// Bump to a RENAMED service (old-worker -> app) — old-worker must be
	// stopped once the upgrade eventually succeeds.
	oldWorkerUnit := lifecycle.UnitName("m1", "old-worker")
	appUnit := lifecycle.UnitName("m1", "app")
	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture("d2", []string{"CAP_CHOWN", "CAP_NET_BIND_SERVICE"}, upgradeAppService)
	backdateManifestCache(t, manifestRoot, "m1")

	// Force the FIRST attempt to fail (blocked drop-in write) — the fallback
	// unit list must survive this failure.
	blocked := filepath.Join(dropInRoot, appUnit+".d", "capabilities.conf")
	if err := os.RemoveAll(blocked); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(blocked, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce attempt 1 (blocked): %v", err)
	}
	if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "d1" {
		t.Fatalf("attempt 1: expected m1 still at d1, got digest=%q ok=%v", digest, ok)
	}

	// M7's own assertion, mid-test: the fallback must already be PERSISTED
	// onto the state entry after attempt 1, even though attempt 1 failed.
	st2, err := mount.LoadState(statePath)
	if err != nil {
		t.Fatalf("LoadState after attempt 1: %v", err)
	}
	found := false
	for _, m := range st2.AttachedModules {
		if m.ID == "m1" {
			found = containsArg(m.Units, oldWorkerUnit)
		}
	}
	if !found {
		t.Fatalf("M7 REGRESSION: after a failed first attempt, the state entry's Units must already contain the fallback-derived %s, got %+v", oldWorkerUnit, st2.AttachedModules)
	}

	// Unblock and mark app active (M6) — attempt 2 succeeds.
	if err := os.RemoveAll(blocked); err != nil {
		t.Fatal(err)
	}
	runner.StubOutput = map[string][]byte{"systemctl is-active " + appUnit: []byte("active\n")}
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce attempt 2: %v", err)
	}

	if !hasSystemctlOp(runner.Invocations, "stop", oldWorkerUnit) {
		t.Errorf("M7 REGRESSION: the renamed-away %s must be stopped once the upgrade succeeds, invocations: %v", oldWorkerUnit, runner.Invocations)
	}
	if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "d2" {
		t.Errorf("attempt 2: expected m1 attached at d2, got digest=%q ok=%v", digest, ok)
	}
}

// TestReconcile_FreshAttachPersistsUnits pins the FIRST of three sites the
// review A mutation script found no test caught: a fresh (non-bump) attach
// must persist mount.Module.Units (point 3, review round 9) on the state
// entry directly, not just as a side effect some LATER behavior happens to
// still work through a fallback.
func TestReconcile_FreshAttachPersistsUnits(t *testing.T) {
	r, _, _, _, statePath, _, _ := upgradeTestReconciler(t)
	unit := lifecycle.UnitName("m1", "app")

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}
	st, err := mount.LoadState(statePath)
	if err != nil {
		t.Fatalf("LoadState: %v", err)
	}
	for _, m := range st.AttachedModules {
		if m.ID == "m1" {
			if !containsArg(m.Units, unit) {
				t.Errorf("REGRESSION: a fresh attach must persist Units on the state entry, got %+v", m.Units)
			}
			return
		}
	}
	t.Fatalf("m1 not found in state: %+v", st.AttachedModules)
}

// TestReconcile_ManifestOnlyReattachRefreshesUnits pins the SECOND site: a
// manifest-only edit (same digest, a service RENAMED) must refresh the
// existing entry's Units — a LATER bump's delta-stop reads this list, and a
// stale one (from before the rename) would misjudge which units are
// genuinely departing on that later bump.
func TestReconcile_ManifestOnlyReattachRefreshesUnits(t *testing.T) {
	r, client, _, _, statePath, manifestRoot, _ := upgradeTestReconciler(t)
	renamedUnit := lifecycle.UnitName("m1", "renamed-app")

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1: %v", err)
	}

	// SAME digest, renamed service — a manifest-only edit, not a bump.
	renamedService := `{"name":"renamed-app", "start_command":"/bin/true", "restart_policy":"always"}`
	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture("d1", []string{"CAP_CHOWN"}, renamedService)
	backdateManifestCache(t, manifestRoot, "m1")
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 2: %v", err)
	}

	st, err := mount.LoadState(statePath)
	if err != nil {
		t.Fatalf("LoadState: %v", err)
	}
	for _, m := range st.AttachedModules {
		if m.ID == "m1" {
			if !containsArg(m.Units, renamedUnit) {
				t.Errorf("REGRESSION: a manifest-only reattach must refresh the state entry's Units to the renamed unit, got %+v", m.Units)
			}
			return
		}
	}
	t.Fatalf("m1 not found in state: %+v", st.AttachedModules)
}

// TestUpgradeModule_CommitReplacesUnitsUnmountsOldErofsAndRemovesDropInDir
// pins the remaining THREE mutant sites review A's script found no test
// caught: step 7 must persist the NEW manifest's Units (not the old ones,
// and not leave the field stale), the old erofs blob must actually be
// unmounted on a successful commit, and a departing unit's drop-in ".d"
// directory must actually be REMOVED from disk, not merely stopped.
func TestUpgradeModule_CommitReplacesUnitsUnmountsOldErofsAndRemovesDropInDir(t *testing.T) {
	r, client, runner, layout, statePath, manifestRoot, dropInRoot := upgradeTestReconciler(t)
	// unmountWouldStripLiveRoot only even attempts the real check on a
	// NATIVE root (pivotAwareRootMode() == RootModeNative); forcing Chroot
	// here takes its early "not native, nothing to strip" return, so the
	// unmount actually runs rather than failing closed on
	// PathInLiveUnion's own unreadable-probe fence — which is what a fake
	// test root (this sandbox may itself read as native) would otherwise
	// hit, masking the very call this test exists to observe.
	origMode := pivotAwareRootMode
	pivotAwareRootMode = func() lifecycle.RootMode { return lifecycle.RootModeChroot }
	t.Cleanup(func() { pivotAwareRootMode = origMode })

	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture(
		"d1", []string{"CAP_CHOWN"}, upgradeAppService+","+upgradeWorkerService)
	appUnit := lifecycle.UnitName("m1", "app")
	workerUnit := lifecycle.UnitName("m1", "old-worker")

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1: %v", err)
	}
	workerDropInDir := filepath.Join(dropInRoot, workerUnit+".d")
	if _, err := os.Stat(workerDropInDir); err != nil {
		t.Fatalf("precondition: expected %s to exist after pass 1: %v", workerDropInDir, err)
	}

	// Bump drops old-worker; mark app active (M6) and the OLD digest's
	// erofs blob as currently mounted (M8/mutation: a successful commit
	// must actually unmount it).
	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture("d2", []string{"CAP_CHOWN"}, upgradeAppService)
	backdateManifestCache(t, manifestRoot, "m1")
	oldMountPath := layout.ModuleMountPath("d1")
	runner.StubOutput = map[string][]byte{
		"systemctl is-active " + appUnit:       []byte("active\n"),
		"findmnt --noheadings " + oldMountPath: []byte(oldMountPath + " erofs\n"),
	}

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 2: %v", err)
	}

	if !hasSystemctlOp(runner.Invocations, "stop", workerUnit) {
		t.Fatalf("expected %s to be stopped, invocations: %v", workerUnit, runner.Invocations)
	}
	if _, err := os.Stat(workerDropInDir); !os.IsNotExist(err) {
		t.Errorf("REGRESSION: departing unit %s's drop-in directory %s must be REMOVED, stat err=%v", workerUnit, workerDropInDir, err)
	}

	foundUmount := false
	for _, inv := range runner.Invocations {
		if inv.Name == "umount" && len(inv.Args) == 1 && inv.Args[0] == oldMountPath {
			foundUmount = true
		}
	}
	if !foundUmount {
		t.Errorf("REGRESSION: a successful commit must unmount the OLD erofs blob at %s, invocations: %v", oldMountPath, runner.Invocations)
	}

	st, err := mount.LoadState(statePath)
	if err != nil {
		t.Fatalf("LoadState: %v", err)
	}
	for _, m := range st.AttachedModules {
		if m.ID == "m1" {
			if m.Digest != "d2" {
				t.Errorf("expected m1 at d2, got %s", m.Digest)
			}
			if !containsArg(m.Units, appUnit) || containsArg(m.Units, workerUnit) {
				t.Errorf("REGRESSION: step 7 must persist the NEW manifest's Units (just %s), got %+v", appUnit, m.Units)
			}
			return
		}
	}
	t.Fatalf("m1 not found in state: %+v", st.AttachedModules)
}

// TestUpgradeModule_UnmountFenceSkipsWhenOldDigestStillInLiveUnion pins the
// LAST review-A mutant: unmountWouldStripLiveRoot's own live-union check
// (mount.PathInLiveUnion, the same fence detachModule itself uses — see
// detach_guard_test.go's own fixture, mirrored here) must actually be
// consulted, not merely bypassed to "always safe to unmount". A pivot
// node's OLD digest still listed as a lowerdir of the live root's overlay
// (mount.LiveUnionLowerDirs) must be left mounted, and the commit must
// still go through (the fence only ever skips the unmount step, never the
// cutover itself).
func TestUpgradeModule_UnmountFenceSkipsWhenOldDigestStillInLiveUnion(t *testing.T) {
	r, client, runner, layout, statePath, manifestRoot, _ := upgradeTestReconciler(t)
	appUnit := lifecycle.UnitName("m1", "app")
	forcePivotNative(t)

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1: %v", err)
	}

	oldMountPath := layout.ModuleMountPath("d1")
	liveRoot := filepath.Join(layout.Root, "/")
	mountInfo := fmt.Sprintf("27 1 0:24 / %s rw,relatime shared:1 - overlay overlay rw,"+
		"lowerdir=%s,upperdir=%s/upper,workdir=%s/work\n", liveRoot, oldMountPath, liveRoot, liveRoot)
	mountInfoPath := filepath.Join(t.TempDir(), "mountinfo")
	if err := os.WriteFile(mountInfoPath, []byte(mountInfo), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(mount.SetMountInfoPathForTest(mountInfoPath))

	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture("d2", []string{"CAP_CHOWN"}, upgradeAppService)
	backdateManifestCache(t, manifestRoot, "m1")
	runner.StubOutput = map[string][]byte{
		"systemctl is-active " + appUnit:       []byte("active\n"),
		"findmnt --noheadings " + oldMountPath: []byte(oldMountPath + " erofs\n"),
	}

	var signals []string
	r.cfg.OnError = func(kind string, _ error) { signals = append(signals, kind) }

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 2: %v", err)
	}

	for _, inv := range runner.Invocations {
		if inv.Name == "umount" {
			t.Errorf("REGRESSION: the OLD digest is still a live-union lowerdir — it must NOT be unmounted, invocations: %v", runner.Invocations)
		}
	}
	sawSkip := false
	for _, s := range signals {
		if s == "reconciler:unmount_skipped" {
			sawSkip = true
		}
	}
	if !sawSkip {
		t.Errorf("expected a reconciler:unmount_skipped signal, got signals=%v", signals)
	}
	if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "d2" {
		t.Errorf("the fence must only skip the unmount, not the cutover — expected m1 committed to d2, got digest=%q ok=%v", digest, ok)
	}
}

// TestUpgradeModule_CrashAfterRestartRefusesCommitAndLeavesOldRunning is M6's
// own test (review round 9, MEDIUM), corrected for N1 (review round 11,
// review B's test-fidelity gap): a Type=simple unit's restart job reporting
// success proves only that the process was launched, not that it stayed up.
// N1 makes the settle check apply ONLY to units that were ACTIVE BEFORE step
// 4 — a unit RecorderRunner defaults to "not active" (the previous version
// of this test never stubbed is-active at all) is now, correctly,
// indistinguishable from a oneshot unit that never ran and gets SKIPPED, not
// exercising the crash path this test exists to pin. app is stubbed ACTIVE
// before the bump, so ForceRestartActive actually issues `restart` (not
// `start`) and N1's preActive snapshot marks it settle-checkable; the
// overridden settle-window sleep then flips app back to inactive with no
// Result/ConditionResult opinion, modeling a binary that crashed right after
// exec. The upgrade must refuse to delta-stop/unmount/commit, and old-worker
// (a departing unit that would otherwise be stopped at step 5) must stay
// running.
func TestUpgradeModule_CrashAfterRestartRefusesCommitAndLeavesOldRunning(t *testing.T) {
	r, client, runner, _, statePath, manifestRoot, _ := upgradeTestReconciler(t)

	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture(
		"d1", []string{"CAP_CHOWN"}, upgradeAppService+","+upgradeWorkerService)
	appUnit := lifecycle.UnitName("m1", "app")
	workerUnit := lifecycle.UnitName("m1", "old-worker")

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1: %v", err)
	}

	// Bump drops old-worker; app's body is unchanged. app is ACTIVE before
	// the bump — this is what makes N1's settle check apply to it at all —
	// so step 4's `systemctl restart` (not `start`) is what actually runs,
	// and it succeeds (no error stubbed), exactly as it would for a process
	// that launched and then immediately died. The settle-window sleep is
	// overridden to flip app to NOT active (with no Result/ConditionResult
	// opinion, i.e. a genuine crash rather than a clean exit) at the moment
	// upgradeModule would otherwise just wait — modeling the crash landing
	// inside the settle window, after step 4's own is-active read already
	// saw it come up.
	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture("d2", []string{"CAP_CHOWN"}, upgradeAppService)
	backdateManifestCache(t, manifestRoot, "m1")

	appIsActiveKey := "systemctl is-active " + appUnit
	runner.StubOutput = map[string][]byte{appIsActiveKey: []byte("active\n")}
	origSleep := sleepForUpgradeSettle
	sleepForUpgradeSettle = func(d time.Duration) {
		delete(runner.StubOutput, appIsActiveKey)
		origSleep(d)
	}
	t.Cleanup(func() { sleepForUpgradeSettle = origSleep })

	pass2Start := len(runner.Invocations)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 2: %v", err)
	}
	pass2 := runner.Invocations[pass2Start:]

	if !hasSystemctlOp(pass2, "restart", appUnit) {
		t.Fatalf("pass 2: expected app to be RESTARTED (it was active before the bump), not just started — got: %v", pass2)
	}

	if hasSystemctlOp(pass2, "stop", appUnit) || hasSystemctlOp(pass2, "stop", workerUnit) {
		t.Errorf("M6 REGRESSION: pass 2 stopped a unit even though the settled unit crashed after restart — nothing should be stopped or unmounted: %v", pass2)
	}
	if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "d1" {
		t.Errorf("M6 REGRESSION: pass 2 must leave m1 attached at the OLD digest d1 (the settle check refused the commit), got digest=%q ok=%v", digest, ok)
	}
}

// TestUpgradeModule_SettleCheckSkipsUnitNeverActiveBeforeUpgrade is N1's own
// test (review round 11, HIGH): a module with a long-running unit (app) and
// a run-once unit (cred, e.g. a credential-fetch or provisioning script)
// that is NEVER active — before or after the bump — must still commit the
// bump in a SINGLE tick, with app restarted exactly once and cred never
// touched by the settle check at all. Before N1, the settle check refused
// to commit on ANY unit reading inactive after the settle window regardless
// of whether it was ever meant to stay running, which meant a module
// carrying a oneshot-shaped unit could never converge — the settle check
// looped forever, reporting the same "crash" every tick.
func TestUpgradeModule_SettleCheckSkipsUnitNeverActiveBeforeUpgrade(t *testing.T) {
	r, client, runner, _, statePath, manifestRoot, _ := upgradeTestReconciler(t)

	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture(
		"d1", []string{"CAP_CHOWN"}, upgradeAppService+","+upgradeCredService)
	appUnit := lifecycle.UnitName("m1", "app")
	credUnit := lifecycle.UnitName("m1", "cred")

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1: %v", err)
	}

	// app is active going into the bump (a real long-running process);
	// cred is left at RecorderRunner's default ("not active") throughout —
	// it ran once at pass 1 and already exited, exactly like a real
	// oneshot-shaped unit would.
	runner.StubOutput = map[string][]byte{"systemctl is-active " + appUnit: []byte("active\n")}

	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture(
		"d2", []string{"CAP_CHOWN"}, upgradeAppService+","+upgradeCredService)
	backdateManifestCache(t, manifestRoot, "m1")

	pass2Start := len(runner.Invocations)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 2: %v", err)
	}
	pass2 := runner.Invocations[pass2Start:]

	if !hasSystemctlOp(pass2, "restart", appUnit) {
		t.Errorf("N1 REGRESSION: expected app (active before the bump) to be restarted exactly once: %v", pass2)
	}
	if hasSystemctlOp(pass2, "restart", credUnit) {
		t.Errorf("N1 REGRESSION: cred was never active before the bump and must not be restarted: %v", pass2)
	}
	if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "d2" {
		t.Errorf("N1 REGRESSION: expected the bump to commit to d2 in a SINGLE tick (cred's own inactivity must never block the settle check), got digest=%q ok=%v", digest, ok)
	}
}

// TestUpgradeModule_SettleCheckAcceptsCleanExitAndConditionSkip is N1's
// second test (review round 11, HIGH): a unit that WAS active before the
// bump but reads inactive after the settle window is settled, not crashed,
// when systemd's own bookkeeping says the termination was clean
// (Result=success) or that a Condition*= directive skipped the start
// (ConditionResult=no) — is-active alone cannot distinguish either from a
// genuine crash. Two units cover both: "app" (Result=success) and "gated"
// (ConditionResult=no). Neither must block the commit.
func TestUpgradeModule_SettleCheckAcceptsCleanExitAndConditionSkip(t *testing.T) {
	gatedService := `{"name":"gated", "start_command":"/bin/true", "restart_policy":"always"}`
	r, client, runner, _, statePath, manifestRoot, _ := upgradeTestReconciler(t)

	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture(
		"d1", []string{"CAP_CHOWN"}, upgradeAppService+","+gatedService)
	appUnit := lifecycle.UnitName("m1", "app")
	gatedUnit := lifecycle.UnitName("m1", "gated")

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1: %v", err)
	}

	// Both units are active going into the bump, so N1's preActive snapshot
	// marks both settle-checkable. Post-restart, both read inactive (no
	// is-active stub for either at this point) — but app's Result is
	// "success" (it exited cleanly on its own after the restart) and
	// gated's ConditionResult is "no" (its Condition*= directive was not
	// met on this restart attempt, so systemd skipped starting it). Neither
	// is a crash.
	runner.StubOutput = map[string][]byte{
		"systemctl is-active " + appUnit:                                      []byte("active\n"),
		"systemctl is-active " + gatedUnit:                                    []byte("active\n"),
		"systemctl show " + appUnit + " --property=Result --value":            []byte("success\n"),
		"systemctl show " + gatedUnit + " --property=ConditionResult --value": []byte("no\n"),
	}
	origSleep := sleepForUpgradeSettle
	sleepForUpgradeSettle = func(d time.Duration) {
		delete(runner.StubOutput, "systemctl is-active "+appUnit)
		delete(runner.StubOutput, "systemctl is-active "+gatedUnit)
		origSleep(d)
	}
	t.Cleanup(func() { sleepForUpgradeSettle = origSleep })

	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture(
		"d2", []string{"CAP_CHOWN"}, upgradeAppService+","+gatedService)
	backdateManifestCache(t, manifestRoot, "m1")

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 2: %v", err)
	}

	if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "d2" {
		t.Errorf("N1 REGRESSION: a clean exit (Result=success) or a condition skip (ConditionResult=no) must not refuse the commit, got digest=%q ok=%v", digest, ok)
	}
}

// TestUpgradeModule_DropInRestoreSkipsUnitAlreadyRestartedOntoNewBinary is
// N6's own test (review round 11, MEDIUM; also N10's first mutant-kill
// target): a module with two units where old-worker's restart succeeds
// (so it is ALREADY running the new binary by the time app's own restart
// fails and step 4 returns an error) must restore capabilities.conf to the
// OLD policy for app (never restarted — the old process, if it is even
// still alive, is confined by whatever is on disk) but leave old-worker's
// capabilities.conf at the NEW policy: reverting it would describe stale
// confinement for a process that is no longer the one running under it.
func TestUpgradeModule_DropInRestoreSkipsUnitAlreadyRestartedOntoNewBinary(t *testing.T) {
	r, client, runner, _, statePath, manifestRoot, dropInRoot := upgradeTestReconciler(t)
	appUnit := lifecycle.UnitName("m1", "app")
	workerUnit := lifecycle.UnitName("m1", "old-worker")

	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture(
		"d1", []string{"CAP_CHOWN"}, upgradeAppService+","+upgradeWorkerService)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1: %v", err)
	}

	// old-worker SURVIVES the bump (same name in both manifests); its
	// capability set changes so its drop-in content is an observable
	// witness for whether N6's skip actually fired.
	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture(
		"d2", []string{"CAP_CHOWN", "CAP_NET_BIND_SERVICE"}, upgradeAppService+","+upgradeWorkerService)
	backdateManifestCache(t, manifestRoot, "m1")
	// app's own restart fails; old-worker's succeeds (no error stubbed) —
	// a genuine PARTIAL step-4 failure.
	runner.StubErr = map[string]error{
		"systemctl start " + appUnit: errors.New("start refused (test)"),
	}

	pass2Start := len(runner.Invocations)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 2: %v", err)
	}
	pass2 := runner.Invocations[pass2Start:]

	if hasSystemctlOp(pass2, "stop", workerUnit) {
		t.Errorf("N6 REGRESSION: old-worker already restarted onto the new binary must never be stopped by app's own failure: %v", pass2)
	}
	if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "d1" {
		t.Errorf("N6: pass 2 must leave m1 attached at the OLD digest d1 (step 4 failed), got digest=%q ok=%v", digest, ok)
	}

	wantOldBody, err := security.RenderCapabilityDropInBody([]string{"CAP_CHOWN"})
	if err != nil {
		t.Fatalf("RenderCapabilityDropInBody(old): %v", err)
	}
	wantNewBody, err := security.RenderCapabilityDropInBody([]string{"CAP_CHOWN", "CAP_NET_BIND_SERVICE"})
	if err != nil {
		t.Fatalf("RenderCapabilityDropInBody(new): %v", err)
	}
	gotAppBody, err := os.ReadFile(filepath.Join(dropInRoot, appUnit+".d", "capabilities.conf"))
	if err != nil {
		t.Fatalf("read app's capabilities.conf: %v", err)
	}
	if string(gotAppBody) != wantOldBody {
		t.Errorf("N6 REGRESSION: app (never restarted) must have its drop-in reverted to the OLD policy (%q), got %q", wantOldBody, gotAppBody)
	}
	gotWorkerBody, err := os.ReadFile(filepath.Join(dropInRoot, workerUnit+".d", "capabilities.conf"))
	if err != nil {
		t.Fatalf("read old-worker's capabilities.conf: %v", err)
	}
	if string(gotWorkerBody) != wantNewBody {
		t.Errorf("N6 REGRESSION: old-worker (already restarted onto the new binary) must KEEP the NEW policy (%q), got %q — reverting it describes stale confinement for a process no longer running under it", wantNewBody, gotWorkerBody)
	}
}

// TestUpgradeModule_SettleCheckCatchesCrashInANonFirstUnit is N10's third
// mutant-kill test (review round 11): a module with TWO units, both active
// before the bump, where the FIRST unit in topoSort order (app) settles
// cleanly but the SECOND (zworker) crashes (inactive after, no Result/
// ConditionResult opinion) — the settle check must still refuse the commit.
// A settle loop that only inspected the first unit would miss this.
func TestUpgradeModule_SettleCheckCatchesCrashInANonFirstUnit(t *testing.T) {
	r, client, runner, _, statePath, manifestRoot, _ := upgradeTestReconciler(t)

	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture(
		"d1", []string{"CAP_CHOWN"}, upgradeAppService+","+upgradeZWorkerService)
	appUnit := lifecycle.UnitName("m1", "app")
	zworkerUnit := lifecycle.UnitName("m1", "zworker")

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1: %v", err)
	}

	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture(
		"d2", []string{"CAP_CHOWN"}, upgradeAppService+","+upgradeZWorkerService)
	backdateManifestCache(t, manifestRoot, "m1")

	// Both active going in; only zworker (the SECOND unit, sorting after
	// app under topoSort's lexicographic tiebreak) is flipped to inactive
	// by the overridden settle-window sleep — app stays active throughout.
	runner.StubOutput = map[string][]byte{
		"systemctl is-active " + appUnit:     []byte("active\n"),
		"systemctl is-active " + zworkerUnit: []byte("active\n"),
	}
	origSleep := sleepForUpgradeSettle
	sleepForUpgradeSettle = func(d time.Duration) {
		delete(runner.StubOutput, "systemctl is-active "+zworkerUnit)
		origSleep(d)
	}
	t.Cleanup(func() { sleepForUpgradeSettle = origSleep })

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 2: %v", err)
	}

	if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "d1" {
		t.Errorf("N10 REGRESSION: a crash in the SECOND unit (zworker) must refuse the commit exactly like a crash in the first — expected m1 still at d1, got digest=%q ok=%v", digest, ok)
	}
}

// TestUpgradeModule_PartialMultiUnitRestartPersistsPendingDigest is M9's own
// test (review B, HIGH): a module with TWO units where app's restart
// succeeds but zworker's fails. upgradeModule returns before step 7, so
// neither unit is stopped and app may already be running the NEW binary —
// but state.json (and the heartbeat) must say so via PendingDigest/
// PendingModuleDigests rather than silently keep claiming the old digest
// alone. A later tick that succeeds commits the new digest and clears it.
func TestUpgradeModule_PartialMultiUnitRestartPersistsPendingDigest(t *testing.T) {
	r, client, runner, _, statePath, manifestRoot, _ := upgradeTestReconciler(t)
	appUnit := lifecycle.UnitName("m1", "app")
	zworkerUnit := lifecycle.UnitName("m1", "zworker")

	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture(
		"d1", []string{"CAP_CHOWN"}, upgradeAppService+","+upgradeZWorkerService)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1: %v", err)
	}

	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture(
		"d2", []string{"CAP_CHOWN"}, upgradeAppService+","+upgradeZWorkerService)
	backdateManifestCache(t, manifestRoot, "m1")
	runner.StubErr = map[string]error{"systemctl start " + zworkerUnit: errors.New("start refused (test)")}

	tick1Start := len(runner.Invocations)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 1: %v", err)
	}
	tick1 := runner.Invocations[tick1Start:]

	if !hasSystemctlOp(tick1, "start", appUnit) {
		t.Fatalf("tick 1: expected app's own restart to have been attempted (and succeeded), invocations: %v", tick1)
	}
	if hasSystemctlOp(tick1, "stop", appUnit) || hasSystemctlOp(tick1, "stop", zworkerUnit) {
		t.Errorf("M9 REGRESSION: a partial multi-unit restart must never stop anything, invocations: %v", tick1)
	}

	st, err := mount.LoadState(statePath)
	if err != nil {
		t.Fatalf("LoadState: %v", err)
	}
	found := false
	for _, m := range st.AttachedModules {
		if m.ID == "m1" {
			found = true
			if m.Digest != "d1" {
				t.Errorf("M9 REGRESSION: expected m1's own Digest to remain d1 after a partial restart, got %s", m.Digest)
			}
			if m.PendingDigest != "d2" {
				t.Errorf("M9 REGRESSION: expected m1's PendingDigest to be d2 after step 4 started restarting, got %q", m.PendingDigest)
			}
		}
	}
	if !found {
		t.Fatalf("m1 not found in state: %+v", st.AttachedModules)
	}

	payload := heartbeatFrom(t, statePath)
	if got := payload.ModuleDigests["m1"]; got != "d1" {
		t.Errorf("M9 REGRESSION: heartbeat must report m1 at its OLD digest d1 while the upgrade is only partially applied, got %q", got)
	}
	if got := payload.PendingModuleDigests["m1"]; got != "d2" {
		t.Errorf("M9 REGRESSION: heartbeat must surface m1's PendingDigest d2, got %q (payload=%+v)", got, payload.PendingModuleDigests)
	}

	// Retry: unblock, mark both units active (M6), and confirm the second
	// tick commits d2 and clears PendingDigest — still with no stop.
	delete(runner.StubErr, "systemctl start "+zworkerUnit)
	runner.StubOutput = map[string][]byte{
		"systemctl is-active " + appUnit:     []byte("active\n"),
		"systemctl is-active " + zworkerUnit: []byte("active\n"),
	}
	tick2Start := len(runner.Invocations)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 2: %v", err)
	}
	tick2 := runner.Invocations[tick2Start:]
	if hasSystemctlOp(tick2, "stop", appUnit) || hasSystemctlOp(tick2, "stop", zworkerUnit) {
		t.Errorf("M9 REGRESSION: the eventual successful commit must never have stopped anything either, invocations: %v", tick2)
	}

	st2, err := mount.LoadState(statePath)
	if err != nil {
		t.Fatalf("LoadState after tick 2: %v", err)
	}
	for _, m := range st2.AttachedModules {
		if m.ID == "m1" {
			if m.Digest != "d2" {
				t.Errorf("expected m1 committed to d2, got %s", m.Digest)
			}
			if m.PendingDigest != "" {
				t.Errorf("M9 REGRESSION: PendingDigest must be cleared once the upgrade commits, got %q", m.PendingDigest)
			}
		}
	}
}

// hookRunner wraps a mount.Runner and calls onRun for every Run invocation
// BEFORE delegating to the wrapped runner. N10's SaveState-before-restart
// mutant-kill test uses this to read state.json off disk at the EXACT
// instant step 4 issues the restart — independent of RunOnce's own
// end-of-cycle SaveState, which runs unconditionally after upgradeModule
// returns and would otherwise mask a removed pre-restart persist: any test
// that only inspects state.json AFTER RunOnce returns cannot tell the two
// saves apart.
type hookRunner struct {
	mount.Runner
	onRun func(name string, args []string)
}

func (h *hookRunner) Run(ctx context.Context, name string, args ...string) error {
	if h.onRun != nil {
		h.onRun(name, args)
	}
	return h.Runner.Run(ctx, name, args...)
}

// TestUpgradeModule_PendingDigestPersistedBeforeRestartIsIssued is N10's
// second mutant-kill test (review round 11): the SaveState call ahead of
// step 4's restart exists so that if the AGENT ITSELF dies between issuing
// `systemctl restart` and RunOnce's own end-of-cycle save (e.g. an OOM-kill
// racing the restart), state.json on disk already shows PendingDigest —
// not just the in-memory struct RunOnce would otherwise save moments later.
// A test that only checks state.json after RunOnce returns cannot
// distinguish "saved before the restart" from "saved after, at end of
// cycle" — both leave the same end-state. hookRunner reads state.json
// SYNCHRONOUSLY inside the restart command itself, mid-RunOnce, before
// RunOnce's own final save has any chance to run.
func TestUpgradeModule_PendingDigestPersistedBeforeRestartIsIssued(t *testing.T) {
	r, client, runner, _, statePath, manifestRoot, _ := upgradeTestReconciler(t)
	unit := lifecycle.UnitName("m1", "app")

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1: %v", err)
	}

	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture("d2", []string{"CAP_CHOWN"}, upgradeAppService)
	backdateManifestCache(t, manifestRoot, "m1")
	runner.StubOutput = map[string][]byte{"systemctl is-active " + unit: []byte("active\n")}

	var sawPendingAtRestartTime string
	var sawRestartCall bool
	hooked := &hookRunner{Runner: runner, onRun: func(name string, args []string) {
		if name != "systemctl" || !containsArg(args, "restart") || !containsArg(args, unit) {
			return
		}
		sawRestartCall = true
		st, err := mount.LoadState(statePath)
		if err != nil {
			t.Fatalf("LoadState mid-restart: %v", err)
		}
		for _, m := range st.AttachedModules {
			if m.ID == "m1" {
				sawPendingAtRestartTime = m.PendingDigest
			}
		}
	}}
	r.cfg.MountRunner = hooked

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 2: %v", err)
	}
	if !sawRestartCall {
		t.Fatalf("fixture did not reach the restart call at all")
	}
	if sawPendingAtRestartTime != "d2" {
		t.Errorf("N10 REGRESSION: state.json must already show PendingDigest=d2 ON DISK at the moment the restart is issued (not only after RunOnce's own end-of-cycle save), got %q", sawPendingAtRestartTime)
	}
}

// TestUpgradeModule_RetryAfterFailedRestartStillRestartsBeforeCommitting is
// M2's own test (review round 9): a retry after a failed restart attempt
// must still RESTART (not silently degrade to `start`) on the next attempt,
// and must only commit the new digest once that restart actually succeeds.
// Before M1's fix this could fail because the restart decision derived from
// writeIfChanged's per-PASS "did the body change" result — not durable
// across attempts, since the body stops looking "changed" after the very
// first write. ForceRestartActive is evaluated fresh on every attempt
// (never cached), so this must keep restarting until it succeeds.
//
// N5 (review round 11, test gap; reviewer B): also this round's dedicated
// "restart of an ACTIVE unit fails" test — every OTHER test in this file
// left is-active at RecorderRunner's default ("not active"), so the verb
// decision always picked Start and the Restart code path (and its failure
// mode) went unexercised. This one already stubbed is-active active and a
// failing `restart`; it now additionally pins that the failure is VISIBLE
// (PendingDigest set, surfaced in the heartbeat) rather than silently
// swallowed, and that it clears once the retry succeeds (N2).
func TestUpgradeModule_RetryAfterFailedRestartStillRestartsBeforeCommitting(t *testing.T) {
	r, client, runner, _, statePath, manifestRoot, _ := upgradeTestReconciler(t)
	unit := lifecycle.UnitName("m1", "app")

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1: %v", err)
	}

	// Bump with an UNCHANGED services block — M1's exact trigger condition —
	// and mark the unit active so restart-vs-start is observable.
	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture("d2", []string{"CAP_CHOWN"}, upgradeAppService)
	backdateManifestCache(t, manifestRoot, "m1")
	runner.StubOutput = map[string][]byte{"systemctl is-active " + unit: []byte("active\n")}
	runner.StubErr = map[string]error{"systemctl restart " + unit: errors.New("restart refused (test)")}

	tick2Start := len(runner.Invocations)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 2: %v", err)
	}
	tick2 := runner.Invocations[tick2Start:]
	if !hasSystemctlOp(tick2, "restart", unit) {
		t.Fatalf("tick 2: expected a restart attempt (that then fails), invocations: %v", tick2)
	}
	if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "d1" {
		t.Fatalf("tick 2: a failed restart must not commit — expected m1 still at d1, got digest=%q ok=%v", digest, ok)
	}

	// N5: the failure must be VISIBLE, not silently swallowed.
	if pd, ok := pendingDigest(t, statePath, "m1"); !ok || pd != "d2" {
		t.Errorf("N5 REGRESSION: tick 2's failed restart must leave PendingDigest=d2 on m1, got %q ok=%v", pd, ok)
	}
	if got := heartbeatFrom(t, statePath).PendingModuleDigests["m1"]; got != "d2" {
		t.Errorf("N5 REGRESSION: tick 2's failed restart must surface PendingModuleDigests[m1]=d2 in the heartbeat, got %q", got)
	}

	// Clear the stub error — the retry succeeds.
	delete(runner.StubErr, "systemctl restart "+unit)
	tick3Start := len(runner.Invocations)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 3: %v", err)
	}
	tick3 := runner.Invocations[tick3Start:]
	if !hasSystemctlOp(tick3, "restart", unit) {
		t.Errorf("M2 REGRESSION: tick 3 must STILL attempt a restart (not silently degrade to start because the body no longer looks 'changed'), invocations: %v", tick3)
	}
	if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "d2" {
		t.Errorf("tick 3: expected the upgrade to commit to d2 now that the restart succeeds, got digest=%q ok=%v", digest, ok)
	}
	if pd, ok := pendingDigest(t, statePath, "m1"); ok && pd != "" {
		t.Errorf("N5 REGRESSION: PendingDigest must be cleared once the retry commits, got %q", pd)
	}
	if got, ok := heartbeatFrom(t, statePath).PendingModuleDigests["m1"]; ok {
		t.Errorf("N5 REGRESSION: PendingModuleDigests must not still name m1 once committed, got %q", got)
	}
}

// TestUpgradeModule_BackoffBoundsRepeatedRetries is N2's own backoff test
// (review round 11, HIGH): a unit whose restart keeps failing must not be
// force-restarted on every single reconcile tick forever. The very first
// attempt and its first retry (M2's own scenario, pinned by
// TestUpgradeModule_RetryAfterFailedRestartStillRestartsBeforeCommitting)
// proceed immediately; from the SECOND retry on, a backed-off tick must
// issue NO restart at all, must leave PendingDigest/Attempts untouched
// (still visible, never silently dropped), and must resume once the
// backoff window elapses.
func TestUpgradeModule_BackoffBoundsRepeatedRetries(t *testing.T) {
	r, client, runner, _, statePath, manifestRoot, _ := upgradeTestReconciler(t)
	unit := lifecycle.UnitName("m1", "app")

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1: %v", err)
	}

	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture("d2", []string{"CAP_CHOWN"}, upgradeAppService)
	backdateManifestCache(t, manifestRoot, "m1")
	runner.StubOutput = map[string][]byte{"systemctl is-active " + unit: []byte("active\n")}
	runner.StubErr = map[string]error{"systemctl restart " + unit: errors.New("restart refused (test)")}

	fakeNow := time.Now()
	origNow := nowForUpgradeBackoff
	nowForUpgradeBackoff = func() time.Time { return fakeNow }
	t.Cleanup(func() { nowForUpgradeBackoff = origNow })

	// Attempt 1 (tick 2, fails) and its free retry, attempt 2 (tick 3,
	// fails) — both proceed immediately, no time advanced.
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 2 (attempt 1): %v", err)
	}
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 3 (attempt 2): %v", err)
	}
	if pd, ok := pendingDigest(t, statePath, "m1"); !ok || pd != "d2" {
		t.Fatalf("after attempt 2: expected PendingDigest=d2, got %q ok=%v", pd, ok)
	}

	// Tick 4: attempt 3 would be the SECOND retry — backed off, since no
	// time has passed. No restart must be issued at all.
	tick4Start := len(runner.Invocations)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 4 (backed off): %v", err)
	}
	tick4 := runner.Invocations[tick4Start:]
	if hasSystemctlOp(tick4, "restart", unit) || hasSystemctlOp(tick4, "start", unit) {
		t.Errorf("N2 REGRESSION: a backed-off tick must issue no start/restart at all: %v", tick4)
	}
	if pd, ok := pendingDigest(t, statePath, "m1"); !ok || pd != "d2" {
		t.Errorf("N2 REGRESSION: a backed-off tick must leave PendingDigest visible (still d2), got %q ok=%v", pd, ok)
	}

	// Advance the clock past the backoff window (attempts=2 → 20s) and
	// clear the stub error — the next tick must retry and succeed.
	fakeNow = fakeNow.Add(30 * time.Second)
	delete(runner.StubErr, "systemctl restart "+unit)
	tick5Start := len(runner.Invocations)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 5 (backoff elapsed): %v", err)
	}
	tick5 := runner.Invocations[tick5Start:]
	if !hasSystemctlOp(tick5, "restart", unit) {
		t.Errorf("N2 REGRESSION: once the backoff window elapses, the next tick must retry, invocations: %v", tick5)
	}
	if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "d2" {
		t.Errorf("expected the upgrade to finally commit to d2, got digest=%q ok=%v", digest, ok)
	}
	if pd, ok := pendingDigest(t, statePath, "m1"); ok && pd != "" {
		t.Errorf("PendingDigest must be cleared once the delayed retry commits, got %q", pd)
	}
}

// TestUpgradeModule_RevertAfterSettleFailureRestartsAndClearsPending is N2's
// own revert test (review round 11, HIGH; adapted from reviewer A's
// TestR10A_RollbackAfterSettleFailureIsANoOp): a bump to d2 crashes inside
// the settle window (a real settle-check refusal, PendingDigest=d2 left
// set, digest stays d1). The operator then REVERTS the desired digest back
// to d1 — the entry's own, already-stable Digest. Before N2 this was a
// total no-op: mount.Reconcile sees no digest diff (d1 already equals d1)
// and the manifest-only reattach's stamp check ALSO sees no diff (d1's
// content never changed), so nothing ever restarts the unit the failed
// attempt left dead, and PendingDigest is never cleared. The revert must
// force some start/restart of app and must clear PendingDigest.
func TestUpgradeModule_RevertAfterSettleFailureRestartsAndClearsPending(t *testing.T) {
	r, client, runner, _, statePath, manifestRoot, _ := upgradeTestReconciler(t)
	appUnit := lifecycle.UnitName("m1", "app")

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1: %v", err)
	}

	// Bump to d2: app is active going in, step 4's restart itself succeeds,
	// but the overridden settle-window sleep flips it back to inactive (no
	// Result/ConditionResult opinion) — a genuine crash inside the settle
	// window, exactly like TestUpgradeModule_CrashAfterRestartRefusesCommitAndLeavesOldRunning.
	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture("d2", []string{"CAP_CHOWN"}, upgradeAppService)
	backdateManifestCache(t, manifestRoot, "m1")
	appIsActiveKey := "systemctl is-active " + appUnit
	runner.StubOutput = map[string][]byte{appIsActiveKey: []byte("active\n")}
	origSleep := sleepForUpgradeSettle
	sleepForUpgradeSettle = func(d time.Duration) {
		delete(runner.StubOutput, appIsActiveKey)
		origSleep(d)
	}
	t.Cleanup(func() { sleepForUpgradeSettle = origSleep })

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 2 (crash inside settle window): %v", err)
	}
	if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "d1" {
		t.Fatalf("tick 2: expected the settle failure to refuse the commit, m1 still at d1, got digest=%q ok=%v", digest, ok)
	}
	if pd, ok := pendingDigest(t, statePath, "m1"); !ok || pd != "d2" {
		t.Fatalf("tick 2: expected PendingDigest=d2 after the settle failure, got %q ok=%v", pd, ok)
	}

	// Revert: the operator points the desired digest back at d1 — the
	// entry's OWN stable digest. app is left at RecorderRunner's default
	// ("not active") throughout tick 3, exactly as tick 2's crash left it.
	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture("d1", []string{"CAP_CHOWN"}, upgradeAppService)
	backdateManifestCache(t, manifestRoot, "m1")

	tick3Start := len(runner.Invocations)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 3 (revert): %v", err)
	}
	tick3 := runner.Invocations[tick3Start:]

	if !hasSystemctlOp(tick3, "start", appUnit) && !hasSystemctlOp(tick3, "restart", appUnit) {
		t.Errorf("N2 REGRESSION: the revert must issue SOME start/restart of app to recover it — invocations: %v", tick3)
	}
	if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "d1" {
		t.Errorf("tick 3: expected m1 still (or again) at d1, got digest=%q ok=%v", digest, ok)
	}
	if pd, ok := pendingDigest(t, statePath, "m1"); ok && pd != "" {
		t.Errorf("N2 REGRESSION: the revert must clear PendingDigest, got %q", pd)
	}
}

// TestUpgradeModule_PolicyRefusalLeavesOldRunningStateUnchanged covers the
// FIRST refusal class (point 5c) plus point 5d (persistent failure across
// several ticks stops nothing): a blocked security drop-in write for the
// NEW digest must never touch the old, running unit, must leave
// state.json reporting the OLD digest, and must keep recording the
// refusal — on every one of three consecutive ticks, not just the first —
// until the write is unblocked.
func TestUpgradeModule_PolicyRefusalLeavesOldRunningStateUnchanged(t *testing.T) {
	r, client, runner, _, statePath, manifestRoot, dropInRoot := upgradeTestReconciler(t)
	unit := lifecycle.UnitName("m1", "app")

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1: %v", err)
	}
	if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "d1" {
		t.Fatalf("pass 1: expected m1 attached at d1, got digest=%q ok=%v", digest, ok)
	}

	// Force the NEW digest's capabilities.conf write to fail by occupying its
	// path with a directory (same technique as the pre-round-9 J1 test).
	unitDropInDir := filepath.Join(dropInRoot, unit+".d")
	blocked := filepath.Join(unitDropInDir, "capabilities.conf")
	if err := os.RemoveAll(blocked); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(blocked, 0o755); err != nil {
		t.Fatal(err)
	}
	// user_namespace flips true (old is false, via upgradeTestReconciler's
	// default fixture) so userns.conf — written unconditionally by step 2,
	// unlike capabilities.conf which is blocked below — is an observable
	// witness for whether restoreDropInSnapshot actually ran (A1).
	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixtureWithUserNS("d2", []string{"CAP_CHOWN", "CAP_NET_BIND_SERVICE"}, true, upgradeAppService)
	backdateManifestCache(t, manifestRoot, "m1")
	wantUserNSBody := security.RenderUserNamespaceDropInBody(false) // old value

	// Three consecutive blocked ticks — point 5d: zero stops across ALL of
	// them, not just the first.
	for attempt := 1; attempt <= 3; attempt++ {
		tickStart := len(runner.Invocations)
		if err := r.RunOnce(context.Background()); err != nil {
			t.Fatalf("RunOnce blocked tick %d: %v", attempt, err)
		}
		tick := runner.Invocations[tickStart:]
		if hasSystemctlOp(tick, "stop", unit) {
			t.Errorf("round 9 REGRESSION: blocked tick %d stopped %s even though the new digest's policy write is refused — old, working unit must stay up: %v",
				attempt, unit, tick)
		}
		if got := r.SecurityFailClosedUnits(); !containsArg(got, unit) {
			t.Errorf("blocked tick %d: expected %s in SecurityFailClosedUnits() (refusal must be recorded), got %v", attempt, unit, got)
		}
		if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "d1" {
			t.Errorf("round 9 REGRESSION: blocked tick %d must leave m1 attached at the OLD digest d1, got digest=%q ok=%v", attempt, digest, ok)
		}
		gotUserNSBody, err := os.ReadFile(filepath.Join(dropInRoot, unit+".d", "userns.conf"))
		if err != nil {
			t.Fatalf("blocked tick %d: read userns.conf: %v", attempt, err)
		}
		if string(gotUserNSBody) != wantUserNSBody {
			t.Errorf("A1 REGRESSION: blocked tick %d must restore userns.conf to the OLD value, got %q want %q", attempt, gotUserNSBody, wantUserNSBody)
		}
	}

	// Unblock — the bump should now go through normally.
	if err := os.RemoveAll(blocked); err != nil {
		t.Fatal(err)
	}
	// M6: the settled unit must read active for the upgrade to commit.
	runner.StubOutput = map[string][]byte{"systemctl is-active " + unit: []byte("active\n")}
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce recovery tick: %v", err)
	}
	if got := r.SecurityFailClosedUnits(); len(got) != 0 {
		t.Errorf("recovery tick: SecurityFailClosedUnits() must clear once the bump succeeds, got %v", got)
	}
	if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "d2" {
		t.Errorf("recovery tick: expected m1 attached at the NEW digest d2 once its policy write stops refusing, got digest=%q ok=%v", digest, ok)
	}
}

// TestUpgradeModule_HotReconcileRefusalLeavesOldRunningStateUnchanged
// covers the SECOND refusal class (point 5c): a materialization refusal
// (here, the scratch pre-flight declining because the configured floor
// exceeds real free space) must leave the old unit running untouched and
// state.json still reporting the old digest — the same guarantee as the
// policy-refusal case, for a different step.
func TestUpgradeModule_HotReconcileRefusalLeavesOldRunningStateUnchanged(t *testing.T) {
	r, client, runner, layout, statePath, manifestRoot, dropInRoot := upgradeTestReconciler(t)
	unit := lifecycle.UnitName("m1", "app")
	forcePivotNative(t)

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1: %v", err)
	}

	// Old and new capability sets deliberately differ so capabilities.conf
	// is an observable witness for A1's restore, mirroring
	// TestUpgradeModule_AttachRefusalRestoresOldPolicyOnDisk's own pattern.
	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture("d2", []string{"CAP_CHOWN", "CAP_NET_BIND_SERVICE"}, upgradeAppService)
	backdateManifestCache(t, manifestRoot, "m1")
	// Stand-in for what the erofs loop-mount of d2 would expose — without
	// real bytes here, PlanScratchBudget sees a zero-byte diff and the
	// pre-flight below trivially "fits" no matter how small the floor is
	// (see budgetReportingFixture, hotreconcile_budget_reporting_test.go,
	// for the same pattern).
	newMountDir := layout.ModuleMountPath("d2")
	mkdirAll(t, filepath.Join(newMountDir, "opt", "powernode", "app"))
	writeFile(t, filepath.Join(newMountDir, "opt", "powernode", "app", "BUILD_INFO.json"), `{"git_sha":"d2"}`)
	// A floor no real filesystem satisfies forces escalateIfHotRungTooSmall
	// to refuse before a single byte is copied (see its own doc).
	r.cfg.ScratchMinFreeBytes = ^uint64(0) >> 1

	var signals []string
	r.cfg.OnError = func(kind string, _ error) { signals = append(signals, kind) }

	pass2Start := len(runner.Invocations)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 2: %v", err)
	}
	pass2 := runner.Invocations[pass2Start:]

	sawRefusal := false
	for _, s := range signals {
		if s == "reconciler:upgrade_hotreconcile" {
			sawRefusal = true
		}
	}
	if !sawRefusal {
		t.Fatalf("fixture did not reach the hotReconcile refusal; signals=%v", signals)
	}
	if hasSystemctlOp(pass2, "stop", unit) {
		t.Errorf("round 9 REGRESSION: pass 2 stopped %s even though materialization was refused — old, working unit must stay up: %v", unit, pass2)
	}
	if hasSystemctlOp(pass2, "restart", unit) {
		t.Errorf("round 9 REGRESSION: pass 2 restarted %s even though materialization was refused: %v", unit, pass2)
	}
	if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "d1" {
		t.Errorf("round 9 REGRESSION: pass 2 must leave m1 attached at the OLD digest d1, got digest=%q ok=%v", digest, ok)
	}
	wantCapsBody, err := security.RenderCapabilityDropInBody([]string{"CAP_CHOWN"})
	if err != nil {
		t.Fatalf("RenderCapabilityDropInBody(old): %v", err)
	}
	gotCapsBody, err := os.ReadFile(filepath.Join(dropInRoot, unit+".d", "capabilities.conf"))
	if err != nil {
		t.Fatalf("read capabilities.conf after the hotReconcile refusal: %v", err)
	}
	if string(gotCapsBody) != wantCapsBody {
		t.Errorf("A1 REGRESSION: after step 3's refusal, capabilities.conf must be restored to the OLD policy (%q), got %q", wantCapsBody, gotCapsBody)
	}
}

// TestUpgradeModule_AttachRefusalRestoresOldPolicyOnDisk covers the THIRD
// refusal class (point 5c) together with A1 (review round 9): when step 4
// (attachModuleServicesOpts) fails AFTER step 2 already wrote the NEW
// digest's security drop-ins, upgradeModule must best-effort restore the
// OLD digest's drop-in CONTENT — not just leave the old unit running,
// but leave its confinement files describing the OLD policy, not the new
// one. Old and new deliberately declare DIFFERENT capability sets so a
// test that silently re-asserted the new content would fail.
func TestUpgradeModule_AttachRefusalRestoresOldPolicyOnDisk(t *testing.T) {
	r, client, runner, _, statePath, manifestRoot, dropInRoot := upgradeTestReconciler(t)
	unit := lifecycle.UnitName("m1", "app")

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1: %v", err)
	}

	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture(
		"d2", []string{"CAP_CHOWN", "CAP_NET_BIND_SERVICE"}, upgradeAppService)
	backdateManifestCache(t, manifestRoot, "m1")
	// Force step 4's systemctl start to fail for this unit.
	runner.StubErr = map[string]error{
		"systemctl start " + unit: errors.New("start refused (test)"),
	}

	pass2Start := len(runner.Invocations)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 2: %v", err)
	}
	pass2 := runner.Invocations[pass2Start:]

	if hasSystemctlOp(pass2, "stop", unit) {
		t.Errorf("round 9 REGRESSION: pass 2 stopped %s even though the new digest's attach failed — old, running unit must stay up: %v", unit, pass2)
	}
	if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "d1" {
		t.Errorf("round 9 REGRESSION: pass 2 must leave m1 attached at the OLD digest d1, got digest=%q ok=%v", digest, ok)
	}

	wantBody, err := security.RenderCapabilityDropInBody([]string{"CAP_CHOWN"})
	if err != nil {
		t.Fatalf("RenderCapabilityDropInBody(old): %v", err)
	}
	gotBody, err := os.ReadFile(filepath.Join(dropInRoot, unit+".d", "capabilities.conf"))
	if err != nil {
		t.Fatalf("read capabilities.conf after a failed attach: %v", err)
	}
	if string(gotBody) != wantBody {
		t.Errorf("A1 REGRESSION: after step 4 fails, the on-disk drop-in must be reapplied to the OLD policy (%q), got %q — the old process is running under content step 2 wrote for the NEW (refused) digest",
			wantBody, string(gotBody))
	}
}

// upgradeModuleFixtureWithSeccomp is upgradeModuleFixture plus an optional
// seccomp_profile — needed only by the R3b "new-only drop-in file" test
// below, which requires a manifest transition where the NEW policy creates
// a drop-in file (seccomp.conf) the OLD one never wrote at all.
func upgradeModuleFixtureWithSeccomp(digest string, capabilities []string, seccompProfile, services string) string {
	capJSON := "["
	for i, c := range capabilities {
		if i > 0 {
			capJSON += ","
		}
		capJSON += fmt.Sprintf("%q", c)
	}
	capJSON += "]"
	return fmt.Sprintf(`{
		"success": true,
		"data": {
			"id":"m1", "name":"app-mod",
			"priority":100, "effective_priority":100,
			"digest":"%s",
			"config": {"security": {"capabilities": %s, "user_namespace": false, "seccomp_profile": %q}},
			"services": [%s]
		}
	}`, digest, capJSON, seccompProfile, services)
}

// TestUpgradeModule_RepeatedAttachRefusalsStayByteIdenticalToPreAttemptState
// is R3b's own red-first case: TWO CONSECUTIVE failed upgrade attempts for
// the SAME old/new digest pair. Before R3b, reapplyOldPolicyBestEffort
// re-rendered the old policy from oldMf (RunOnce's previousManifests
// snapshot) — correct on the FIRST attempt (the cache still held the old
// digest's manifest), but WRONG on the second: attempt 1's own manifest
// fetch had already overwritten the on-disk cache with the NEW digest's
// content, so attempt 2's "restore" silently re-rendered the NEW (already
// wrong) policy instead of genuinely restoring the old one. This test
// fails on that code (verified) and passes once restoreDropInSnapshot
// (byte-exact, independent of previousManifests) replaces it.
func TestUpgradeModule_RepeatedAttachRefusalsStayByteIdenticalToPreAttemptState(t *testing.T) {
	r, client, runner, _, statePath, manifestRoot, dropInRoot := upgradeTestReconciler(t)
	unit := lifecycle.UnitName("m1", "app")

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1: %v", err)
	}
	capPath := filepath.Join(dropInRoot, unit+".d", "capabilities.conf")
	preAttemptState, err := os.ReadFile(capPath)
	if err != nil {
		t.Fatalf("read capabilities.conf after pass 1: %v", err)
	}

	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture(
		"d2", []string{"CAP_CHOWN", "CAP_NET_BIND_SERVICE"}, upgradeAppService)
	backdateManifestCache(t, manifestRoot, "m1")
	runner.StubErr = map[string]error{
		"systemctl start " + unit: errors.New("start refused (test)"),
	}

	for attempt := 1; attempt <= 2; attempt++ {
		if err := r.RunOnce(context.Background()); err != nil {
			t.Fatalf("RunOnce attempt %d: %v", attempt, err)
		}
		if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "d1" {
			t.Fatalf("attempt %d: expected m1 to remain attached at d1, got digest=%q ok=%v", attempt, digest, ok)
		}
		got, err := os.ReadFile(capPath)
		if err != nil {
			t.Fatalf("attempt %d: read capabilities.conf: %v", attempt, err)
		}
		if string(got) != string(preAttemptState) {
			t.Errorf("R3b REGRESSION: after attempt %d, capabilities.conf must be byte-identical to the pre-upgrade (OLD digest's) state %q, got %q",
				attempt, preAttemptState, got)
		}
	}
}

// TestUpgradeModule_RestoreRemovesADropInFileTheNewPolicyCreated is R3b's
// second required test: the NEW manifest declares a seccomp_profile the OLD
// one never had, so step 2 creates seccomp.conf where nothing existed
// before. On a step-4 failure, restoreDropInSnapshot must REMOVE that file
// (not merely leave it, and not try to overwrite it with empty content —
// its snapshot correctly records existed=false).
func TestUpgradeModule_RestoreRemovesADropInFileTheNewPolicyCreated(t *testing.T) {
	r, client, runner, _, statePath, manifestRoot, dropInRoot := upgradeTestReconciler(t)
	unit := lifecycle.UnitName("m1", "app")

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1: %v", err)
	}
	seccompPath := filepath.Join(dropInRoot, unit+".d", "seccomp.conf")
	if _, err := os.Stat(seccompPath); !os.IsNotExist(err) {
		t.Fatalf("precondition: seccomp.conf must not exist after pass 1 (old policy declares no seccomp_profile), stat err=%v", err)
	}

	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixtureWithSeccomp(
		"d2", []string{"CAP_CHOWN"}, "default", upgradeAppService)
	backdateManifestCache(t, manifestRoot, "m1")
	runner.StubErr = map[string]error{
		"systemctl start " + unit: errors.New("start refused (test)"),
	}

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 2: %v", err)
	}
	if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "d1" {
		t.Fatalf("pass 2: expected m1 to remain attached at d1, got digest=%q ok=%v", digest, ok)
	}
	if _, err := os.Stat(seccompPath); !os.IsNotExist(err) {
		t.Errorf("R3b REGRESSION: seccomp.conf, created by the NEW (refused) policy's step 2, must be REMOVED once the upgrade fails and restores — stat err=%v", err)
	}
}

// TestUpgradeModule_AgentVersionBumpTickDoesNotDoubleRestartViaReattach
// covers point 5e: a tick that ALSO carries a pending module version bump
// must not additionally restart that same unit through the ordinary
// toReattach loop just because attachStamp's embedded AgentVersion made
// every module's stamp look stale (see RunOnce's own doc on
// bumpIDsThisTick, closing exactly this bypass). Simulated by hand-
// corrupting the stored manifest hash the way a genuine agent-version
// change would (a real agent upgrade is out of scope for this package's
// tests) — the unit must be started/restarted EXACTLY ONCE this tick, not
// once by upgradeModule and again by the toReattach loop.
func TestUpgradeModule_AgentVersionBumpTickDoesNotDoubleRestartViaReattach(t *testing.T) {
	r, client, runner, _, statePath, manifestRoot, _ := upgradeTestReconciler(t)
	unit := lifecycle.UnitName("m1", "app")

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1: %v", err)
	}

	// Corrupt the stored stamp to simulate what a real AgentVersion change
	// embeds into every module's attachStamp — a stale value that would, on
	// its own, put m1 into toReattach.
	st, err := mount.LoadState(statePath)
	if err != nil {
		t.Fatalf("LoadState: %v", err)
	}
	st.LastAttachedManifestHashes["m1"] = "stale-stamp-from-a-different-agent-version"
	if err := mount.SaveState(statePath, st); err != nil {
		t.Fatalf("SaveState: %v", err)
	}

	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture("d2", []string{"CAP_CHOWN"}, upgradeAppService)
	backdateManifestCache(t, manifestRoot, "m1")
	// M6: the settled unit must read active for the upgrade to commit.
	runner.StubOutput = map[string][]byte{"systemctl is-active " + unit: []byte("active\n")}

	pass2Start := len(runner.Invocations)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 2: %v", err)
	}
	pass2 := runner.Invocations[pass2Start:]

	starts := 0
	for _, inv := range pass2 {
		if inv.Name == "systemctl" && inv.Op == "Run" && containsArg(inv.Args, unit) &&
			(containsArg(inv.Args, "start") || containsArg(inv.Args, "restart")) {
			starts++
		}
	}
	if starts != 1 {
		t.Errorf("round 9 REGRESSION: expected exactly one start/restart of %s this tick (upgradeModule only — the toReattach bypass must stay closed), got %d: %v",
			unit, starts, pass2)
	}
	if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "d2" {
		t.Errorf("pass 2: expected m1 attached at d2, got digest=%q ok=%v", digest, ok)
	}
}

// TestAttachModuleServices_SelfHostFenceAppliesToManifestOnlyReattachNotBump
// is A2's own test: a manifest-only edit (same digest, changed service
// body) on a self-hosted node must still be fenced by attachModuleServices
// (no restart of an active unit), while a genuine version bump on the SAME
// self-hosted node bypasses that fence — but ONLY through upgradeModule.
// systemd.IsActive must read "active" for the fence to be observable at
// all (a Restart verb is only ever chosen over Start when the unit already
// reads active — see AttachServicesModeOpts).
func TestAttachModuleServices_SelfHostFenceAppliesToManifestOnlyReattachNotBump(t *testing.T) {
	r, client, runner, _, _, manifestRoot, _ := upgradeTestReconciler(t)
	r.selfHostLatched = true
	unit := lifecycle.UnitName("m1", "app")

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1: %v", err)
	}
	runner.StubOutput = map[string][]byte{
		"systemctl is-active " + unit: []byte("active\n"),
	}

	// PASS 2: manifest-only edit, SAME digest — a different start_command
	// changes the rendered unit body without touching the digest.
	editedService := `{"name":"app", "start_command":"/bin/true --edited", "restart_policy":"always"}`
	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture("d1", []string{"CAP_CHOWN"}, editedService)
	backdateManifestCache(t, manifestRoot, "m1")
	pass2Start := len(runner.Invocations)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 2 (manifest-only edit): %v", err)
	}
	pass2 := runner.Invocations[pass2Start:]
	if hasSystemctlOp(pass2, "restart", unit) {
		t.Errorf("A2 REGRESSION: a manifest-only reattach on a self-hosted node must stay fenced (no restart of an active unit), invocations: %v", pass2)
	}

	// PASS 3: a genuine version bump on the SAME self-hosted node — must
	// bypass the fence, restarting the active unit, via upgradeModule only.
	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture("d2", []string{"CAP_CHOWN"}, upgradeAppService)
	backdateManifestCache(t, manifestRoot, "m1")
	pass3Start := len(runner.Invocations)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 3 (version bump): %v", err)
	}
	pass3 := runner.Invocations[pass3Start:]
	if !hasSystemctlOp(pass3, "restart", unit) {
		t.Errorf("A2 REGRESSION: a version bump on a self-hosted node must bypass the restart fence via upgradeModule, invocations: %v", pass3)
	}
}
