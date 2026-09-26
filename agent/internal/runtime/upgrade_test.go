package runtime

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/etcidentity"
	"github.com/nodealchemy/powernode-system/agent/internal/etcsudoers"
	"github.com/nodealchemy/powernode-system/agent/internal/lifecycle"
	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/oci"
	"github.com/nodealchemy/powernode-system/agent/internal/security"
	"gopkg.in/yaml.v3"
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

// upgradeNewWorkerService names a unit that never existed under any OLD
// digest in these tests — N8's own fixture needs a genuinely NEW-THIS-
// UPGRADE unit, distinct from upgradeWorkerService's "old-worker" (which
// exists on the OLD side and departs) and upgradeZWorkerService (which
// exists on BOTH sides).
const upgradeNewWorkerService = `{"name":"new-worker", "start_command":"/bin/true", "restart_policy":"always"}`

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

	// app is active going into the bump (a real long-running process); cred
	// reads inactive (RecorderRunner's default) but reports Result=success
	// (O5, review round 12: a run-once unit is now actually CHECKED, not
	// skipped outright — settled requires active, ConditionResult=no, or
	// Result=success; a genuinely crashed run-once unit would report
	// something else and correctly block the commit).
	runner.StubOutput = map[string][]byte{
		"systemctl is-active " + appUnit:                            []byte("active\n"),
		"systemctl show " + credUnit + " --property=Result --value": []byte("success\n"),
	}

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
	// O5 (review round 12) CORRECTED this fixture: round 11's version used
	// an `always` (persistent) unit for the Result=success case, which O5
	// found was ITSELF wrong — Result=success does not settle a persistent
	// unit (a Restart=always unit that exits 0 and immediately relaunches
	// reports success while genuinely crash-looping). Result=success only
	// settles a run-once unit (restart_policy:"never"), which is what
	// "onceunit" declares here. See
	// TestUpgradeModule_SettleCheckRejectsPersistentUnitReportingSuccess for
	// the negative case this fixture used to get wrong.
	onceService := `{"name":"onceunit", "start_command":"/bin/true", "restart_policy":"never"}`
	gatedService := `{"name":"gated", "start_command":"/bin/true", "restart_policy":"always"}`
	r, client, runner, _, statePath, manifestRoot, _ := upgradeTestReconciler(t)

	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture(
		"d1", []string{"CAP_CHOWN"}, onceService+","+gatedService)
	onceUnit := lifecycle.UnitName("m1", "onceunit")
	gatedUnit := lifecycle.UnitName("m1", "gated")

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1: %v", err)
	}

	// Both units are active going into the bump, so both are settle-checked
	// (O5: onceunit's own restart_policy:"never" ALSO makes it checked now,
	// not skipped — this fixture exercises it via the active-before path,
	// same as gated). Post-restart, both read inactive (no is-active stub
	// for either at this point) — but onceunit's Result is "success" (it
	// ran once and exited cleanly, exactly as declared) and gated's
	// ConditionResult is "no" (its Condition*= directive was not met on
	// this restart attempt, so systemd skipped starting it). Neither is a
	// crash.
	runner.StubOutput = map[string][]byte{
		"systemctl is-active " + onceUnit:                                     []byte("active\n"),
		"systemctl is-active " + gatedUnit:                                    []byte("active\n"),
		"systemctl show " + onceUnit + " --property=Result --value":           []byte("success\n"),
		"systemctl show " + gatedUnit + " --property=ConditionResult --value": []byte("no\n"),
	}
	origSleep := sleepForUpgradeSettle
	sleepForUpgradeSettle = func(d time.Duration) {
		delete(runner.StubOutput, "systemctl is-active "+onceUnit)
		delete(runner.StubOutput, "systemctl is-active "+gatedUnit)
		origSleep(d)
	}
	t.Cleanup(func() { sleepForUpgradeSettle = origSleep })

	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture(
		"d2", []string{"CAP_CHOWN"}, onceService+","+gatedService)
	backdateManifestCache(t, manifestRoot, "m1")

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 2: %v", err)
	}

	if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "d2" {
		t.Errorf("N1/O5 REGRESSION: a run-once unit's clean exit (Result=success) or a condition skip (ConditionResult=no) must not refuse the commit, got digest=%q ok=%v", digest, ok)
	}
}

// TestUpgradeModule_SettleCheckRejectsPersistentUnitReportingSuccess is O5's
// own negative test (review round 12, MEDIUM): round 11's settled predicate
// accepted Result=success for ANY unit, persistent or not. That is wrong
// for a persistent one — a Restart=always unit that crashes and exits 0
// each time (a bad migration that runs, "succeeds" at nothing, and exits
// cleanly, over and over) reports Result=success while genuinely down.
// Only ConditionResult=no or a currently-active read may settle a
// persistent unit; Result=success must NOT.
func TestUpgradeModule_SettleCheckRejectsPersistentUnitReportingSuccess(t *testing.T) {
	r, client, runner, _, statePath, manifestRoot, _ := upgradeTestReconciler(t)
	unit := lifecycle.UnitName("m1", "app")

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1: %v", err)
	}

	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture("d2", []string{"CAP_CHOWN"}, upgradeAppService)
	backdateManifestCache(t, manifestRoot, "m1")

	// app (restart_policy:"always") is active going in; the settle window
	// then finds it inactive but reporting Result=success — a clean exit
	// each crash-loop iteration reports, never a genuine "this is fine".
	appIsActiveKey := "systemctl is-active " + unit
	runner.StubOutput = map[string][]byte{
		appIsActiveKey: []byte("active\n"),
		"systemctl show " + unit + " --property=Result --value": []byte("success\n"),
	}
	origSleep := sleepForUpgradeSettle
	sleepForUpgradeSettle = func(d time.Duration) {
		delete(runner.StubOutput, appIsActiveKey)
		origSleep(d)
	}
	t.Cleanup(func() { sleepForUpgradeSettle = origSleep })

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 2: %v", err)
	}

	if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "d1" {
		t.Errorf("O5 REGRESSION: a PERSISTENT unit reporting Result=success while inactive must NOT settle (a crash loop reports success on every clean-exit iteration) — expected m1 still at d1, got digest=%q ok=%v", digest, ok)
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

// TestUpgradeModule_DepartingUnitStoppedToUnblockPortConflict is N8's own
// test (review round 11, MEDIUM): a renamed service (old-worker departs,
// new-worker replaces it) that shares a port with the unit it replaces
// deadlocks under the ordinary design — the departing unit is never
// stopped until the new one is confirmed settled, but the new one can never
// bind the port while the old one still holds it. new-worker is stubbed to
// fail is-active until old-worker is actually stopped (simulating exactly
// that bind conflict, not a real crash); once recoverFromDepartingUnitConflict
// stops old-worker and retries, new-worker comes up and the whole upgrade
// commits in the SAME tick.
func TestUpgradeModule_DepartingUnitStoppedToUnblockPortConflict(t *testing.T) {
	r, client, runner, _, statePath, manifestRoot, _ := upgradeTestReconciler(t)

	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture(
		"d1", []string{"CAP_CHOWN"}, upgradeAppService+","+upgradeWorkerService)
	appUnit := lifecycle.UnitName("m1", "app")
	oldWorkerUnit := lifecycle.UnitName("m1", "old-worker")
	newWorkerUnit := lifecycle.UnitName("m1", "new-worker")

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1: %v", err)
	}

	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture(
		"d2", []string{"CAP_CHOWN"}, upgradeAppService+","+upgradeNewWorkerService)
	backdateManifestCache(t, manifestRoot, "m1")

	newWorkerIsActiveKey := "systemctl is-active " + newWorkerUnit
	runner.StubOutput = map[string][]byte{
		"systemctl is-active " + appUnit:       []byte("active\n"),
		"systemctl is-active " + oldWorkerUnit: []byte("active\n"),
		newWorkerIsActiveKey:                   []byte("inactive\n"), // simulated bind conflict
	}
	var sawStopBeforeRecoveredStart bool
	hooked := &hookRunner{Runner: runner, onRun: func(name string, args []string) {
		if name == "systemctl" && containsArg(args, "stop") && containsArg(args, oldWorkerUnit) {
			// The port is now free — new-worker can bind on the retry.
			runner.StubOutput[newWorkerIsActiveKey] = []byte("active\n")
			sawStopBeforeRecoveredStart = true
		}
	}}
	r.cfg.MountRunner = hooked

	tick2Start := len(runner.Invocations)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 2: %v", err)
	}
	tick2 := runner.Invocations[tick2Start:]

	if !sawStopBeforeRecoveredStart {
		t.Fatalf("N8 REGRESSION: expected old-worker to be stopped to unblock new-worker, invocations: %v", tick2)
	}
	if !hasSystemctlOp(tick2, "start", newWorkerUnit) {
		t.Errorf("N8 REGRESSION: expected new-worker to be (re)started after old-worker was stopped: %v", tick2)
	}
	if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "d2" {
		t.Errorf("N8 REGRESSION: expected the upgrade to commit to d2 once the conflict was recovered from, got digest=%q ok=%v", digest, ok)
	}
	if pd, ok := pendingDigest(t, statePath, "m1"); ok && pd != "" {
		t.Errorf("N8 REGRESSION: PendingDigest must be cleared once the upgrade commits, got %q", pd)
	}
}

// TestUpgradeModule_N8RecoveryRefusesOnCrashInsideSettleWindow is O1's own
// test (review round 12, HIGH): N8's conflict recovery checked is-active
// IMMEDIATELY after stopping the departing unit and retrying `start`, with
// no settle wait at all — for a Type=simple unit that reads "active" the
// instant the process exists, a crash landing inside what SHOULD be the
// settle window would sail through as recovered and commit d2 while the
// module goes down silently. new-worker comes up right after old-worker
// stops (as in the ordinary N8 test) but then crashes during N8's OWN
// settle window (simulated via the second sleepForUpgradeSettle call,
// mirroring how the main check's own crash tests intercept the sleep) —
// the commit must be refused, not accepted.
func TestUpgradeModule_N8RecoveryRefusesOnCrashInsideSettleWindow(t *testing.T) {
	r, client, runner, _, statePath, manifestRoot, _ := upgradeTestReconciler(t)

	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture(
		"d1", []string{"CAP_CHOWN"}, upgradeAppService+","+upgradeWorkerService)
	appUnit := lifecycle.UnitName("m1", "app")
	oldWorkerUnit := lifecycle.UnitName("m1", "old-worker")
	newWorkerUnit := lifecycle.UnitName("m1", "new-worker")

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1: %v", err)
	}

	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture(
		"d2", []string{"CAP_CHOWN"}, upgradeAppService+","+upgradeNewWorkerService)
	backdateManifestCache(t, manifestRoot, "m1")

	newWorkerIsActiveKey := "systemctl is-active " + newWorkerUnit
	runner.StubOutput = map[string][]byte{
		"systemctl is-active " + appUnit:       []byte("active\n"),
		"systemctl is-active " + oldWorkerUnit: []byte("active\n"),
		newWorkerIsActiveKey:                   []byte("inactive\n"),
	}
	hooked := &hookRunner{Runner: runner, onRun: func(name string, args []string) {
		if name == "systemctl" && containsArg(args, "stop") && containsArg(args, oldWorkerUnit) {
			runner.StubOutput[newWorkerIsActiveKey] = []byte("active\n")
		}
	}}
	r.cfg.MountRunner = hooked

	// The main settle check's own sleep is call #1 (nothing to do — the
	// bind conflict is still live at that point). N8 recovery's own sleep
	// is call #2 — simulate the crash landing there, exactly inside the
	// window this fix adds.
	sleepCalls := 0
	origSleep := sleepForUpgradeSettle
	sleepForUpgradeSettle = func(d time.Duration) {
		sleepCalls++
		if sleepCalls == 2 {
			runner.StubOutput[newWorkerIsActiveKey] = []byte("inactive\n")
		}
		origSleep(d)
	}
	t.Cleanup(func() { sleepForUpgradeSettle = origSleep })

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 2: %v", err)
	}

	if sleepCalls < 2 {
		t.Fatalf("fixture did not reach N8's own settle sleep at all (sleepCalls=%d) — precondition not met", sleepCalls)
	}
	if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "d1" {
		t.Errorf("O1 REGRESSION: a crash inside N8's OWN settle window must refuse the commit, expected m1 still at d1, got digest=%q ok=%v", digest, ok)
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

// TestUpgradeModule_RevertBackoffBoundsRepeatedFailures is O3's own test
// (review round 12, MEDIUM): the revert path's force-restart previously had
// NO backoff at all — a persistently failing revert retried on EVERY tick
// forever (the reviewer's own "4 in 4 ticks"). Gated by the SAME
// backoffAllows the ordinary retry path uses.
func TestUpgradeModule_RevertBackoffBoundsRepeatedFailures(t *testing.T) {
	r, client, runner, _, statePath, manifestRoot, _ := upgradeTestReconciler(t)
	appUnit := lifecycle.UnitName("m1", "app")

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1: %v", err)
	}

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
	if pd, ok := pendingDigest(t, statePath, "m1"); !ok || pd != "d2" {
		t.Fatalf("tick 2: expected PendingDigest=d2, got %q ok=%v", pd, ok)
	}

	fakeNow := time.Now()
	origNow := nowForUpgradeBackoff
	nowForUpgradeBackoff = func() time.Time { return fakeNow }
	t.Cleanup(func() { nowForUpgradeBackoff = origNow })

	// Revert to d1 — but the revert's own force-restart keeps FAILING.
	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture("d1", []string{"CAP_CHOWN"}, upgradeAppService)
	backdateManifestCache(t, manifestRoot, "m1")
	runner.StubErr = map[string]error{"systemctl start " + appUnit: errors.New("start refused (test)")}

	// Tick 3: this is the revert's FIRST attempt (attempts was 1 from tick
	// 2's own failed upgrade — see backoffAllows: attempts<2 always
	// proceeds) — fails, attempts becomes 2.
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 3 (revert attempt 1, fails): %v", err)
	}
	if pd, ok := pendingDigest(t, statePath, "m1"); !ok || pd != "d2" {
		t.Fatalf("tick 3: expected PendingDigest to remain d2 (revert failed), got %q ok=%v", pd, ok)
	}

	// Tick 4: attempts=2 now — the SECOND retry is subject to backoff, and
	// no time has passed. No start attempt must be issued at all.
	tick4Start := len(runner.Invocations)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 4 (backed off): %v", err)
	}
	tick4 := runner.Invocations[tick4Start:]
	if hasSystemctlOp(tick4, "start", appUnit) || hasSystemctlOp(tick4, "restart", appUnit) {
		t.Errorf("O3 REGRESSION: a backed-off revert tick must issue no start/restart at all: %v", tick4)
	}

	// Advance the clock past the backoff window (attempts=2 -> 20s), clear
	// the stub error — the next tick must retry and succeed.
	fakeNow = fakeNow.Add(30 * time.Second)
	delete(runner.StubErr, "systemctl start "+appUnit)
	tick5Start := len(runner.Invocations)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 5 (backoff elapsed): %v", err)
	}
	tick5 := runner.Invocations[tick5Start:]
	if !hasSystemctlOp(tick5, "start", appUnit) && !hasSystemctlOp(tick5, "restart", appUnit) {
		t.Errorf("O3 REGRESSION: once the backoff window elapses, the revert must retry, invocations: %v", tick5)
	}
	if pd, ok := pendingDigest(t, statePath, "m1"); ok && pd != "" {
		t.Errorf("O3 REGRESSION: PendingDigest must be cleared once the delayed revert retry succeeds, got %q", pd)
	}
}

// TestUpgradeModule_RevertStopsUnitsThatExistOnlyInTheAbandonedDigest is
// O4's own test (review round 12, MEDIUM): a unit new-worker exists ONLY in
// the abandoned PENDING digest (d2), started during its own step 4 before
// the settle check refused the commit. The stable digest's manifest (d1)
// never named new-worker at all, so the revert's own force-restart (which
// only touches units the STABLE manifest names) never touches it — before
// O4, it stayed running (or at least its unit file stayed on disk) forever
// once PendingDigest cleared, orphaned. The revert must stop it and remove
// its unit file/drop-in dir, exactly like an ordinary delta-stop.
func TestUpgradeModule_RevertStopsUnitsThatExistOnlyInTheAbandonedDigest(t *testing.T) {
	r, client, runner, _, statePath, manifestRoot, _ := upgradeTestReconciler(t)
	appUnit := lifecycle.UnitName("m1", "app")
	newWorkerUnit := lifecycle.UnitName("m1", "new-worker")

	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture("d1", []string{"CAP_CHOWN"}, upgradeAppService)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1: %v", err)
	}

	// Bump to d2 (app + new-worker): app settles fine; new-worker never
	// becomes active (simulated bind failure / crash — no departing unit is
	// active here, so N8 does not apply, and the settle check simply
	// refuses).
	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture("d2", []string{"CAP_CHOWN"}, upgradeAppService+","+upgradeNewWorkerService)
	backdateManifestCache(t, manifestRoot, "m1")
	runner.StubOutput = map[string][]byte{
		"systemctl is-active " + appUnit:       []byte("active\n"),
		"systemctl is-active " + newWorkerUnit: []byte("inactive\n"),
	}
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 2 (new-worker never settles): %v", err)
	}
	if pd, ok := pendingDigest(t, statePath, "m1"); !ok || pd != "d2" {
		t.Fatalf("tick 2: expected PendingDigest=d2, got %q ok=%v", pd, ok)
	}

	// Revert to d1 (app only) — new-worker exists ONLY in the abandoned d2.
	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture("d1", []string{"CAP_CHOWN"}, upgradeAppService)
	backdateManifestCache(t, manifestRoot, "m1")
	runner.StubOutput["systemctl is-active "+appUnit] = []byte("active\n")

	tick3Start := len(runner.Invocations)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 3 (revert): %v", err)
	}
	tick3 := runner.Invocations[tick3Start:]

	if !hasSystemctlOp(tick3, "stop", newWorkerUnit) {
		t.Errorf("O4 REGRESSION: the revert must stop new-worker (it exists ONLY in the abandoned d2 digest), invocations: %v", tick3)
	}
	if pd, ok := pendingDigest(t, statePath, "m1"); ok && pd != "" {
		t.Errorf("O4: PendingDigest must still be cleared once the revert succeeds, got %q", pd)
	}
}

// TestUpgradeModule_N8RecoveryFiresAtMostOncePerDigest is O6's own test
// (review round 12, MEDIUM): a settle failure that N8's recovery could not
// actually resolve (new-worker never comes up even after old-worker is
// stopped) must not re-run the stop/start dance against old-worker on
// EVERY retry of the same digest — only the FIRST attempt tries it; a
// SUBSEQUENT retry declines and leaves old-worker alone (already restored
// by the first attempt's own undo).
func TestUpgradeModule_N8RecoveryFiresAtMostOncePerDigest(t *testing.T) {
	r, client, runner, _, statePath, manifestRoot, _ := upgradeTestReconciler(t)

	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture(
		"d1", []string{"CAP_CHOWN"}, upgradeAppService+","+upgradeWorkerService)
	appUnit := lifecycle.UnitName("m1", "app")
	oldWorkerUnit := lifecycle.UnitName("m1", "old-worker")
	newWorkerUnit := lifecycle.UnitName("m1", "new-worker")

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1: %v", err)
	}

	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture(
		"d2", []string{"CAP_CHOWN"}, upgradeAppService+","+upgradeNewWorkerService)
	backdateManifestCache(t, manifestRoot, "m1")

	// new-worker NEVER comes up, no matter what — old-worker being stopped
	// doesn't actually fix its problem (a bad binary, not a real conflict).
	runner.StubOutput = map[string][]byte{
		"systemctl is-active " + appUnit:       []byte("active\n"),
		"systemctl is-active " + oldWorkerUnit: []byte("active\n"),
		"systemctl is-active " + newWorkerUnit: []byte("inactive\n"),
	}

	tick2Start := len(runner.Invocations)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 2 (N8 attempts and fails): %v", err)
	}
	tick2 := runner.Invocations[tick2Start:]
	if !hasSystemctlOp(tick2, "stop", oldWorkerUnit) {
		t.Fatalf("tick 2: expected N8 to attempt stopping old-worker at least once, invocations: %v", tick2)
	}
	if pd, ok := pendingDigest(t, statePath, "m1"); !ok || pd != "d2" {
		t.Fatalf("tick 2: expected PendingDigest to remain d2 (recovery did not resolve it), got %q ok=%v", pd, ok)
	}

	// Tick 3: SAME digest retried (attempts=1, still free per backoffAllows).
	// N8 must NOT fire again — old-worker (already restored by tick 2's own
	// undo) must not be touched a second time.
	tick3Start := len(runner.Invocations)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 3 (retry, N8 must not re-fire): %v", err)
	}
	tick3 := runner.Invocations[tick3Start:]
	if hasSystemctlOp(tick3, "stop", oldWorkerUnit) {
		t.Errorf("O6 REGRESSION: N8 recovery must fire at most ONCE per digest — old-worker was stopped again on a retry: %v", tick3)
	}
}

// TestUpgradeModule_N8UndoRetriesOnceBeforeGivingUp is O6's own second test
// (review round 12, MEDIUM; also N10-style mutant-kill target: "N8 undo
// restart removed"): the undo restart of a departing unit, after N8's own
// recovery attempt fails, is retried ONCE within the SAME attempt before
// being treated as a genuine failure — a transient error (the same class
// step 4's own restart can hit) must not strand the departing unit down on
// the very first try.
func TestUpgradeModule_N8UndoRetriesOnceBeforeGivingUp(t *testing.T) {
	r, client, runner, _, statePath, manifestRoot, _ := upgradeTestReconciler(t)

	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture(
		"d1", []string{"CAP_CHOWN"}, upgradeAppService+","+upgradeWorkerService)
	appUnit := lifecycle.UnitName("m1", "app")
	oldWorkerUnit := lifecycle.UnitName("m1", "old-worker")
	newWorkerUnit := lifecycle.UnitName("m1", "new-worker")

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1: %v", err)
	}

	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture(
		"d2", []string{"CAP_CHOWN"}, upgradeAppService+","+upgradeNewWorkerService)
	backdateManifestCache(t, manifestRoot, "m1")

	runner.StubOutput = map[string][]byte{
		"systemctl is-active " + appUnit:       []byte("active\n"),
		"systemctl is-active " + oldWorkerUnit: []byte("active\n"),
		"systemctl is-active " + newWorkerUnit: []byte("inactive\n"), // never comes up
	}
	runner.StubErr = map[string]error{}
	startCalls := 0
	oldWorkerStartKey := "systemctl start " + oldWorkerUnit
	hooked := &hookRunner{Runner: runner, onRun: func(name string, args []string) {
		if name != "systemctl" || !containsArg(args, "start") || !containsArg(args, oldWorkerUnit) {
			return
		}
		startCalls++
		if startCalls == 1 {
			runner.StubErr[oldWorkerStartKey] = errors.New("undo failed once (transient)")
		} else {
			delete(runner.StubErr, oldWorkerStartKey)
		}
	}}
	r.cfg.MountRunner = hooked

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 2: %v", err)
	}

	if startCalls < 2 {
		t.Fatalf("O6 REGRESSION: expected the undo to be retried at least once (2+ start calls on old-worker), got %d", startCalls)
	}
	st, err := mount.LoadState(statePath)
	if err != nil {
		t.Fatalf("LoadState: %v", err)
	}
	for _, m := range st.AttachedModules {
		if m.ID == "m1" && len(m.PendingUndoUnits) > 0 {
			t.Errorf("O6 REGRESSION: the undo's own retry succeeded — PendingUndoUnits must be empty, got %v", m.PendingUndoUnits)
		}
	}
}

// TestUpgradeModule_PendingUndoUnitsPersistedBeforeDepartingUnitIsStopped is
// P8's own crash-boundary test (review round 13, MEDIUM): before this fix,
// PendingConflictRecoveryAttempted=true was the only thing persisted before
// recoverFromDepartingUnitConflict stopped a departing unit — the
// PendingUndoUnits/stillDown save only happened AFTER the stop-then-start-
// then-settle sequence completed. A crash landing anywhere in that window
// (here: the instant old-worker is stopped) left state.json with the
// attempted flag set but no record of which unit this attempt had just
// stopped, so nothing would ever retry it. hookRunner reads state.json
// SYNCHRONOUSLY inside the stop command itself, mid-RunOnce, before
// anything past that point (including the function's own eventual
// stillDown save) has any chance to run — proving PendingUndoUnits already
// names old-worker on disk at the moment it is stopped, not only once the
// attempt later concludes.
func TestUpgradeModule_PendingUndoUnitsPersistedBeforeDepartingUnitIsStopped(t *testing.T) {
	r, client, runner, _, statePath, manifestRoot, _ := upgradeTestReconciler(t)

	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture(
		"d1", []string{"CAP_CHOWN"}, upgradeAppService+","+upgradeWorkerService)
	appUnit := lifecycle.UnitName("m1", "app")
	oldWorkerUnit := lifecycle.UnitName("m1", "old-worker")
	newWorkerUnit := lifecycle.UnitName("m1", "new-worker")

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1: %v", err)
	}

	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture(
		"d2", []string{"CAP_CHOWN"}, upgradeAppService+","+upgradeNewWorkerService)
	backdateManifestCache(t, manifestRoot, "m1")

	newWorkerIsActiveKey := "systemctl is-active " + newWorkerUnit
	runner.StubOutput = map[string][]byte{
		"systemctl is-active " + appUnit:       []byte("active\n"),
		"systemctl is-active " + oldWorkerUnit: []byte("active\n"),
		newWorkerIsActiveKey:                   []byte("inactive\n"), // simulated bind conflict
	}
	var sawStopCall bool
	var pendingUndoAtStopTime []string
	hooked := &hookRunner{Runner: runner, onRun: func(name string, args []string) {
		if name != "systemctl" || !containsArg(args, "stop") || !containsArg(args, oldWorkerUnit) {
			return
		}
		if sawStopCall {
			// Once recovery succeeds this same tick, the upgrade commits
			// and step 5's own delta-stop issues a SECOND, entirely
			// legitimate stop of this now-genuinely-departed unit — by
			// then PendingUndoUnits has already been correctly cleared
			// (recovery's own success path, below). Only the FIRST stop —
			// recoverFromDepartingUnitConflict's own — is what this test
			// is about.
			return
		}
		sawStopCall = true
		st, err := mount.LoadState(statePath)
		if err != nil {
			t.Fatalf("LoadState mid-stop: %v", err)
		}
		for _, m := range st.AttachedModules {
			if m.ID == "m1" {
				pendingUndoAtStopTime = append([]string(nil), m.PendingUndoUnits...)
			}
		}
		// The port is now free — new-worker can bind on the retry, same
		// fixture shape as the ordinary N8 test.
		runner.StubOutput[newWorkerIsActiveKey] = []byte("active\n")
	}}
	r.cfg.MountRunner = hooked

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 2: %v", err)
	}
	if !sawStopCall {
		t.Fatalf("fixture did not reach the stop call at all")
	}
	if !containsArg(pendingUndoAtStopTime, oldWorkerUnit) {
		t.Errorf("P8 REGRESSION: state.json must already list %s in PendingUndoUnits ON DISK at the moment it is stopped (not only after the attempt later concludes), got %v", oldWorkerUnit, pendingUndoAtStopTime)
	}

	// The recovery succeeds this same tick (new-worker comes up) — the
	// pre-stop candidate list must be retracted, not left dangling now that
	// old-worker's departure was deliberate.
	st, err := mount.LoadState(statePath)
	if err != nil {
		t.Fatalf("LoadState: %v", err)
	}
	for _, m := range st.AttachedModules {
		if m.ID == "m1" && len(m.PendingUndoUnits) > 0 {
			t.Errorf("P8 REGRESSION: PendingUndoUnits must be cleared once recovery succeeds, got %v", m.PendingUndoUnits)
		}
	}
	if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "d2" {
		t.Errorf("expected the upgrade to commit to d2 once the conflict was recovered from, got digest=%q ok=%v", digest, ok)
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

	// P7 (review round 13): step 2's own refusal now counts against
	// backoffAllows just like a step-4 failure does (see
	// recordPendingDigestAttempt) — from the second retry on, a genuine
	// re-attempt needs the backoff window to have elapsed, or the tick is a
	// silent backoff-skip rather than a real policy-refusal retry. Control
	// the clock and advance it past the (capped) 5-minute max window before
	// every tick from the second on, so all three blocked ticks below are
	// genuine re-attempts, matching this test's original intent.
	fakeNow := time.Now()
	origNow := nowForUpgradeBackoff
	nowForUpgradeBackoff = func() time.Time { return fakeNow }
	t.Cleanup(func() { nowForUpgradeBackoff = origNow })

	// Three consecutive blocked ticks — point 5d: zero stops across ALL of
	// them, not just the first.
	for attempt := 1; attempt <= 3; attempt++ {
		if attempt > 1 {
			fakeNow = fakeNow.Add(6 * time.Minute)
		}
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
	// P7: advance past the backoff window one more time so the recovery
	// tick is itself a genuine attempt, not another silent backoff-skip.
	fakeNow = fakeNow.Add(6 * time.Minute)
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

// TestUpgradeModule_StaleSnapshotNeverRestoresALooserPolicy is O2's own
// test (review round 12, HIGH, SECURITY): the reviewer's exact sequence.
// d2 is refused (capabilities.conf blocked) — the snapshot for (m1, d2)
// captures d1's ORIGINAL (user_namespace:false) content. d1's OWN manifest
// is then edited to TIGHTEN user_namespace to true — an ordinary
// manifest-only reattach, unrelated to the blocked d2 attempt, which
// correctly writes userns.conf=true and bumps d1's attach-stamp. d2 is
// refused AGAIN. Before O2, the snapshot for (m1, d2) was keyed ONLY by
// digest, so this second refusal's restore would reuse the STALE snapshot
// from the FIRST refusal — reverting userns.conf back to the ORIGINAL,
// untightened (false) value and silently weakening the running unit's
// confinement below what its current, correct manifest declares.
func TestUpgradeModule_StaleSnapshotNeverRestoresALooserPolicy(t *testing.T) {
	r, client, _, _, statePath, manifestRoot, dropInRoot := upgradeTestReconciler(t)
	unit := lifecycle.UnitName("m1", "app")

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1: %v", err)
	}

	unitDropInDir := filepath.Join(dropInRoot, unit+".d")
	blocked := filepath.Join(unitDropInDir, "capabilities.conf")
	block := func() {
		if err := os.RemoveAll(blocked); err != nil {
			t.Fatal(err)
		}
		if err := os.MkdirAll(blocked, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	unblock := func() {
		if err := os.RemoveAll(blocked); err != nil {
			t.Fatal(err)
		}
	}

	// Attempt 1: d2 refused. Snapshot captures d1's ORIGINAL content
	// (user_namespace:false, upgradeTestReconciler's own default).
	block()
	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixtureWithUserNS("d2", []string{"CAP_CHOWN"}, true, upgradeAppService)
	backdateManifestCache(t, manifestRoot, "m1")
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce attempt 1 (d2 refused): %v", err)
	}
	if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "d1" {
		t.Fatalf("attempt 1: expected m1 still at d1, got digest=%q ok=%v", digest, ok)
	}
	originalBody, err := os.ReadFile(filepath.Join(dropInRoot, unit+".d", "userns.conf"))
	if err != nil {
		t.Fatalf("read userns.conf after attempt 1: %v", err)
	}
	if string(originalBody) != security.RenderUserNamespaceDropInBody(false) {
		t.Fatalf("precondition: expected userns.conf still false after attempt 1, got %q", originalBody)
	}

	// Revert/edit: d1's OWN manifest tightens user_namespace to true — an
	// ordinary manifest-only reattach, unrelated to the blocked d2 attempt.
	// capabilities.conf must be UNBLOCKED for this tick — it is d1's own
	// reattach, not the d2 attempt this test is about — otherwise this
	// reattach would ALSO refuse (attachModule fails as a whole even though
	// userns.conf, written unconditionally, still lands on disk as a side
	// effect of the same refused call) and never actually commit the
	// tightened attach-stamp this test's own precondition depends on.
	unblock()
	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixtureWithUserNS("d1", []string{"CAP_CHOWN"}, true, upgradeAppService)
	backdateManifestCache(t, manifestRoot, "m1")
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce d1 tightening tick: %v", err)
	}
	tightenedBody, err := os.ReadFile(filepath.Join(dropInRoot, unit+".d", "userns.conf"))
	if err != nil {
		t.Fatalf("read userns.conf after tightening: %v", err)
	}
	if string(tightenedBody) != security.RenderUserNamespaceDropInBody(true) {
		t.Fatalf("precondition: expected userns.conf tightened to true, got %q", tightenedBody)
	}

	// Attempt 2: d2 refused AGAIN (re-block capabilities.conf). The restore
	// must NOT revert userns.conf back to the ORIGINAL (false) value from
	// attempt 1's now-stale snapshot.
	block()
	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixtureWithUserNS("d2", []string{"CAP_CHOWN"}, true, upgradeAppService)
	backdateManifestCache(t, manifestRoot, "m1")
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce attempt 2 (d2 refused again): %v", err)
	}
	if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "d1" {
		t.Fatalf("attempt 2: expected m1 still at d1, got digest=%q ok=%v", digest, ok)
	}
	finalBody, err := os.ReadFile(filepath.Join(dropInRoot, unit+".d", "userns.conf"))
	if err != nil {
		t.Fatalf("read userns.conf after attempt 2: %v", err)
	}
	if string(finalBody) != security.RenderUserNamespaceDropInBody(true) {
		t.Errorf("O2 REGRESSION (SECURITY): attempt 2's restore reverted userns.conf to a STALE, LOOSER policy — got %q, want the currently-tightened %q",
			finalBody, security.RenderUserNamespaceDropInBody(true))
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

// TestLoadOrTakeDropInSnapshot_PersistsAndReusesAcrossAttempts is N7's own
// test (review round 11, MEDIUM), exercising loadOrTakeDropInSnapshot
// directly rather than through a full RunOnce tick: a fresh snapshot taken
// on EVERY attempt (R3b's original design) is itself wrong across attempts
// of the SAME (ID, new digest) target if attempt 1 ever writes new content
// and never reaches its own restore — the only realistic way is the agent
// process itself dying mid-attempt, which cannot be reproduced by driving
// RunOnce through a normal, reachable failure branch (every one of those
// already calls restoreDropInSnapshot before returning). Simulated directly
// here: write TRUE old content, take+persist attempt 1's snapshot, then
// write NEW content onto disk WITHOUT going through any restore (standing
// in for "attempt 1 wrote it and then the process died before reverting"),
// and confirm attempt 2 reuses the PERSISTED (true old) snapshot rather
// than re-reading the now-corrupted current disk state.
func TestLoadOrTakeDropInSnapshot_PersistsAndReusesAcrossAttempts(t *testing.T) {
	dropInRoot := t.TempDir()
	t.Cleanup(security.SetSystemdDropInRootForTest(dropInRoot))
	statePath := filepath.Join(t.TempDir(), "state.json")
	unit := lifecycle.UnitName("m1", "app")
	dropDir := filepath.Join(dropInRoot, unit+".d")
	if err := os.MkdirAll(dropDir, 0o755); err != nil {
		t.Fatal(err)
	}
	capPath := filepath.Join(dropDir, "capabilities.conf")
	if err := os.WriteFile(capPath, []byte("OLD-POLICY"), 0o644); err != nil {
		t.Fatal(err)
	}

	if _, err := loadOrTakeDropInSnapshot(statePath, "m1", "d2", "d1", "stamp-a", []string{unit}); err != nil {
		t.Fatalf("attempt 1: %v", err)
	}

	// Simulate step 2 writing new content, then the process dying before
	// reaching its own restore — the on-disk content is now "corrupted"
	// (new, never reverted) independent of the persisted snapshot.
	if err := os.WriteFile(capPath, []byte("NEW-POLICY-NEVER-RESTORED"), 0o644); err != nil {
		t.Fatal(err)
	}

	// Attempt 2: the OLD digest's own identity (d1, stamp-a) is UNCHANGED,
	// so the persisted snapshot from attempt 1 is still valid and reused.
	snap2, err := loadOrTakeDropInSnapshot(statePath, "m1", "d2", "d1", "stamp-a", []string{unit})
	if err != nil {
		t.Fatalf("attempt 2: %v", err)
	}
	var got string
	found := false
	for _, s := range snap2 {
		if s.filename == "capabilities.conf" {
			got = s.body
			found = true
		}
	}
	if !found {
		t.Fatalf("attempt 2 snapshot has no capabilities.conf entry: %+v", snap2)
	}
	if got != "OLD-POLICY" {
		t.Errorf("N7 REGRESSION: attempt 2 must reuse the PERSISTED baseline (%q), got %q — a fresh re-snapshot wrongly captures attempt 1's own uncommitted write as if it were the true pre-attempt content", "OLD-POLICY", got)
	}

	// clearDropInSnapshotStore ends the (ID, digest) pair's lifetime — a
	// LATER, genuinely fresh attempt at the SAME digest string (a re-bump
	// after commit, in practice never the same digest twice, but the store
	// must not accidentally pin one forever) must re-snapshot from disk.
	clearDropInSnapshotStore(statePath, "m1", "d2")
	if err := os.WriteFile(capPath, []byte("YET-ANOTHER-POLICY"), 0o644); err != nil {
		t.Fatal(err)
	}
	snap3, err := loadOrTakeDropInSnapshot(statePath, "m1", "d2", "d1", "stamp-a", []string{unit})
	if err != nil {
		t.Fatalf("attempt 3 (after clear): %v", err)
	}
	got = ""
	for _, s := range snap3 {
		if s.filename == "capabilities.conf" {
			got = s.body
		}
	}
	if got != "YET-ANOTHER-POLICY" {
		t.Errorf("N7: after clearDropInSnapshotStore, the NEXT attempt must re-snapshot fresh from disk, got %q", got)
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

// TestRunOnce_BootstrapsAttachedSnapshotForPreN3Attach is O7's bootstrap
// case (review round 12): a module attached before the N3 attached-snapshot
// store existed (round 11) — or one whose snapshot write previously failed
// and was never retried — has no attached/<digest>.json for its currently
// running digest. Without a bootstrap, the FIRST upgrade attempt against
// such a module falls back to previousManifests (fine for one attempt), but
// a SECOND attempt reads the wrong "old" content back — the exact
// second-failed-tick bug N3 exists to prevent. Simulated here by deleting
// the snapshot file a normal attach already wrote, leaving only the
// ID-keyed manifest cache (exactly what a pre-N3 build's on-disk state
// looks like) — then asserting an otherwise-no-op reconcile tick recreates
// it from that cache, matching the currently-attached digest exactly.
func TestRunOnce_BootstrapsAttachedSnapshotForPreN3Attach(t *testing.T) {
	r, _, _, _, _, manifestRoot, _ := upgradeTestReconciler(t)

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1: %v", err)
	}
	if _, err := manifest.LoadAttachedSnapshot(manifestRoot, "m1", "d1"); err != nil {
		t.Fatalf("precondition: expected pass 1's own attach to have saved a d1 snapshot: %v", err)
	}
	snapPath := filepath.Join(manifestRoot, "m1", "attached", "d1.json")
	if err := os.Remove(snapPath); err != nil {
		t.Fatalf("precondition: removing %s to simulate a pre-N3 attach: %v", snapPath, err)
	}
	if _, err := manifest.LoadAttachedSnapshot(manifestRoot, "m1", "d1"); err == nil {
		t.Fatalf("precondition: expected no snapshot after removing %s", snapPath)
	}

	// PASS 2: nothing changed — same digest, same manifest body. Nothing in
	// the ordinary attach/reattach path has any reason to run, so ONLY the
	// O7 bootstrap can be what recreates the snapshot.
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 2: %v", err)
	}
	got, err := manifest.LoadAttachedSnapshot(manifestRoot, "m1", "d1")
	if err != nil {
		t.Fatalf("O7 REGRESSION: expected pass 2 to bootstrap the missing d1 snapshot, got: %v", err)
	}
	if got.ID != "m1" || got.Digest != "d1" {
		t.Errorf("O7 REGRESSION: bootstrapped snapshot content mismatch, got id=%q digest=%q", got.ID, got.Digest)
	}
}

// TestRunOnce_BootstrapDoesNotAdoptARefusedManifestOnlyEditAtTheSameDigest is
// P6 (review round 13, LOW): the digest-only guard in O7's bootstrap loop
// trusted previousManifests[mod.ID] as "what's genuinely attached right now"
// once its digest matched mod.Digest. previousManifests is the ID-keyed
// "latest fetch" cache, and a REFUSED reattach never rolls it back — the
// fetch that populates it runs before the reattach attempt, so the cache is
// left holding the new, never-applied content regardless of whether the
// reattach that follows succeeds. A manifest-only edit at the SAME digest
// (capabilities widen, no digest change — the toReattach path, not
// upgradeModule) that fetches successfully and is then refused at reattach
// (here: a blocked capabilities.conf write) leaves
// LastAttachedManifestHashes["m1"] pointing at the OLD, still-genuinely-
// attached content's stamp. If the module's own attached-snapshot is ALSO
// missing at exactly this tick (the pre-N3 gap O7's bootstrap exists to
// close), the digest-only guard wrongly bootstraps the snapshot with the
// refused content; the stamp comparison this fix adds must refuse instead.
func TestRunOnce_BootstrapDoesNotAdoptARefusedManifestOnlyEditAtTheSameDigest(t *testing.T) {
	r, client, _, _, _, manifestRoot, dropInRoot := upgradeTestReconciler(t)
	unit := lifecycle.UnitName("m1", "app")

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1: %v", err)
	}
	snapPath := filepath.Join(manifestRoot, "m1", "attached", "d1.json")
	if _, err := os.Stat(snapPath); err != nil {
		t.Fatalf("precondition: expected %s after pass 1: %v", snapPath, err)
	}

	// Manifest-only edit at the SAME digest (d1): capability set widens, no
	// digest change, so this goes through the toReattach path (reconcile.go),
	// never upgradeModule.
	unitDropInDir := filepath.Join(dropInRoot, unit+".d")
	blocked := filepath.Join(unitDropInDir, "capabilities.conf")
	block := func() {
		if err := os.RemoveAll(blocked); err != nil {
			t.Fatal(err)
		}
		if err := os.MkdirAll(blocked, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	block()
	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture("d1", []string{"CAP_CHOWN", "CAP_NET_BIND_SERVICE"}, upgradeAppService)
	backdateManifestCache(t, manifestRoot, "m1")

	// Pass 2: the reattach is attempted and refused (capabilities.conf write
	// blocked). attachModule's error return short-circuits before either
	// LastAttachedManifestHashes["m1"] or d1's attach-snapshot is touched —
	// both must still describe the ORIGINAL, narrower-capability content.
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 2 (refused reattach): %v", err)
	}
	if _, err := manifest.LoadAttachedSnapshot(manifestRoot, "m1", "d1"); err != nil {
		t.Fatalf("precondition: expected d1's snapshot to survive the refused reattach untouched: %v", err)
	}

	// Simulate the pre-N3 gap: the snapshot the original attach wrote is
	// lost. previousManifests["m1"] on disk was overwritten by pass 2's own
	// fetch loop and now holds the REFUSED, widened-capability content — the
	// exact mismatch P6 exists to catch.
	if err := os.Remove(snapPath); err != nil {
		t.Fatalf("simulating pre-N3 loss of the d1 snapshot: %v", err)
	}
	if _, err := manifest.LoadAttachedSnapshot(manifestRoot, "m1", "d1"); err == nil {
		t.Fatalf("precondition: expected no snapshot after removing %s", snapPath)
	}

	// Pass 3: nothing about the fixture changes. The bootstrap loop runs
	// against previousManifests as captured at the START of this tick (pass
	// 2's refused-and-cached widened content) — the digest-only guard would
	// reconstruct d1's snapshot from that REFUSED content; the P6 fix must
	// refuse, since attachStamp(refused content) != LastAttachedManifestHashes["m1"].
	// capabilities.conf stays blocked so this tick's OWN reattach attempt is
	// refused too, keeping the assertion isolated to the bootstrap loop alone.
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 3: %v", err)
	}
	if _, err := manifest.LoadAttachedSnapshot(manifestRoot, "m1", "d1"); err == nil {
		t.Fatalf("P6 REGRESSION (SECURITY): bootstrap wrongly adopted a refused manifest-only edit as d1's attached snapshot")
	}
}

// TestRunOnce_PrunesAttachedSnapshotsForDigestsNeitherAttachedNorPending is
// O7's GC case (review round 12): manifest.SaveAttachedSnapshot writes a new
// file per digest a module ID is ever attached under and nothing previously
// deleted one — every version bump over a module's life leaves its old
// digest's snapshot behind forever. After a bump from d1 to d2 commits
// (PendingDigest cleared, Digest now d2), a LATER no-op tick's GC pass must
// remove d1's now-orphaned snapshot while keeping d2's (still the
// currently-attached digest).
func TestRunOnce_PrunesAttachedSnapshotsForDigestsNeitherAttachedNorPending(t *testing.T) {
	r, client, runner, _, _, manifestRoot, _ := upgradeTestReconciler(t)
	unit := lifecycle.UnitName("m1", "app")
	d1Path := filepath.Join(manifestRoot, "m1", "attached", "d1.json")
	d2Path := filepath.Join(manifestRoot, "m1", "attached", "d2.json")

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1: %v", err)
	}
	if _, err := os.Stat(d1Path); err != nil {
		t.Fatalf("precondition: expected %s after pass 1: %v", d1Path, err)
	}

	// PASS 2: version bump d1 -> d2, settling immediately (app reads active).
	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture("d2", []string{"CAP_CHOWN"}, upgradeAppService)
	backdateManifestCache(t, manifestRoot, "m1")
	runner.StubOutput = map[string][]byte{"systemctl is-active " + unit: []byte("active\n")}
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 2: %v", err)
	}
	if _, err := os.Stat(d2Path); err != nil {
		t.Fatalf("precondition: expected %s after pass 2's commit: %v", d2Path, err)
	}
	// d1's snapshot must survive pass 2 itself — this tick's own GC runs
	// against the PRE-bump state (Digest still d1, PendingDigest still
	// empty at the top of the tick), so d1 is exactly what it keeps; the
	// bump that abandons d1 happens later in this SAME tick.
	if _, err := os.Stat(d1Path); err != nil {
		t.Fatalf("precondition: expected %s to still exist immediately after pass 2 (GC ran before the bump): %v", d1Path, err)
	}

	// PASS 3: a genuine no-op tick — nothing changed since the commit. GC
	// now sees Digest=d2, PendingDigest="" from the START of this tick, so
	// d1's file has no reader left and must be removed.
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 3: %v", err)
	}
	if _, err := os.Stat(d1Path); !os.IsNotExist(err) {
		t.Errorf("O7 REGRESSION: expected orphaned snapshot %s to be pruned by pass 3, stat err=%v", d1Path, err)
	}
	if _, err := os.Stat(d2Path); err != nil {
		t.Errorf("O7 REGRESSION: pass 3's GC must not touch the currently-attached digest's own snapshot %s: %v", d2Path, err)
	}
}

// TestUpgradeModule_RevertClearsPendingDigestOnEveryDuplicateStateEntry is
// O8(a)'s own test (review round 12, the one item review A flagged as an
// actual RULE-1 violation among the O8 items): the M4 duplicate-state-entry
// case (see TestReconcile_DuplicateStateEntryNeverStopsTheLiveModule) means
// current.AttachedModules can hold TWO rows for the same module ID. Before
// this fix, the revert path's PendingDigest-clearing loop stopped at the
// FIRST matching entry (`break`) — a second duplicate row that also carried
// PendingDigest stayed stuck forever, so a module the revert just recovered
// would still read as pending-a-revert on the very next tick and get
// force-restarted again: an unforced, invisible restart of an
// already-healthy unit, forever.
func TestUpgradeModule_RevertClearsPendingDigestOnEveryDuplicateStateEntry(t *testing.T) {
	r, client, runner, _, statePath, manifestRoot, _ := upgradeTestReconciler(t)
	appUnit := lifecycle.UnitName("m1", "app")

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1: %v", err)
	}

	// Drive the SAME genuine crash-inside-settle-window refusal
	// TestUpgradeModule_RevertAfterSettleFailureRestartsAndClearsPending
	// uses, so PendingDigest=d2 is set the same way production would set it.
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
	if pd, ok := pendingDigest(t, statePath, "m1"); !ok || pd != "d2" {
		t.Fatalf("tick 2: expected PendingDigest=d2, got %q ok=%v", pd, ok)
	}

	// Inject the M4 duplicate: a SECOND row for the same module ID, also
	// mid-revert of its own — a state.json shape this reconciler should
	// never itself produce, but the code must not silently mishandle if it
	// occurs (see the M4 fix's own test for the analogous attach-side case).
	st, err := mount.LoadState(statePath)
	if err != nil {
		t.Fatalf("LoadState: %v", err)
	}
	var original mount.Module
	for _, m := range st.AttachedModules {
		if m.ID == "m1" {
			original = m
			break
		}
	}
	if original.ID == "" {
		t.Fatalf("precondition: expected an m1 entry after tick 2, got %+v", st.AttachedModules)
	}
	duplicate := original
	st.AttachedModules = append(st.AttachedModules, duplicate)
	if err := mount.SaveState(statePath, st); err != nil {
		t.Fatalf("SaveState (inject duplicate): %v", err)
	}
	if pd, ok := pendingDigest(t, statePath, "m1"); !ok || pd != "d2" {
		t.Fatalf("precondition: expected both m1 rows to read PendingDigest=d2 after injection, got %q ok=%v", pd, ok)
	}

	// Revert to d1 — recovers cleanly (app comes back active).
	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture("d1", []string{"CAP_CHOWN"}, upgradeAppService)
	backdateManifestCache(t, manifestRoot, "m1")
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 3 (revert): %v", err)
	}

	final, err := mount.LoadState(statePath)
	if err != nil {
		t.Fatalf("LoadState after revert: %v", err)
	}
	count := 0
	for _, m := range final.AttachedModules {
		if m.ID != "m1" {
			continue
		}
		count++
		if m.PendingDigest != "" {
			t.Errorf("O8(a) REGRESSION: expected EVERY m1 entry to have PendingDigest cleared after a successful revert, entry %d still has %q: %+v", count, m.PendingDigest, m)
		}
	}
	if count != 2 {
		t.Fatalf("precondition drifted: expected both injected m1 rows to survive the tick, got %d: %+v", count, final.AttachedModules)
	}
}

// TestReconcile_RevertUnionsUnitsTouchedAcrossDuplicateStateEntries is P9
// (review round 13, LOW, rule-1 edge): the revert path read
// PendingDigestUnitsTouched, PendingIntroducedUnits and PendingUndoUnits
// from the FIRST matching duplicate row only (see the M4 duplicate-state-
// entry case, TestUpgradeModule_RevertClearsPendingDigestOnEveryDuplicateStateEntry,
// for how such a shape arises). Two DISAGREEING rows for the same module ID
// — one saying "nothing touched", the other saying "app was touched,
// unit-a introduced, unit-b stuck" — must still force-restart app and stop
// AND retry both units: touched units are touched, and stuck units are
// stuck, regardless of which row recorded them.
func TestReconcile_RevertUnionsUnitsTouchedAcrossDuplicateStateEntries(t *testing.T) {
	r, client, runner, _, statePath, manifestRoot, _ := upgradeTestReconciler(t)
	appUnit := lifecycle.UnitName("m1", "app")
	unitA := lifecycle.UnitName("m1", "unit-a")
	unitB := lifecycle.UnitName("m1", "unit-b")

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1 (attach d1, app only): %v", err)
	}

	// Get a genuine PendingDigest=d2 row on disk (irrelevant to the
	// disagreement itself — only its presence matters, so the revert path
	// below is reached at all).
	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture("d2", []string{"CAP_CHOWN"}, upgradeAppService)
	backdateManifestCache(t, manifestRoot, "m1")
	r.cfg.Puller = &failingPuller{PullerAPI: r.cfg.Puller, failDigest: "d2"}
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 2 (d2 refused at step 1): %v", err)
	}
	if pd, ok := pendingDigest(t, statePath, "m1"); !ok || pd != "d2" {
		t.Fatalf("precondition: expected PendingDigest=d2 after pass 2, got %q ok=%v", pd, ok)
	}

	// Inject the M4 duplicate, deliberately DISAGREEING on every field P9
	// touches. Row 1 (the one an unfixed reader would see FIRST) claims
	// nothing was ever touched and has no introduced/undo units at all —
	// if the revert only ever consulted this row, it would run the
	// UNFORCED, no-restart path entirely. Row 2 carries the real facts.
	st, err := mount.LoadState(statePath)
	if err != nil {
		t.Fatalf("LoadState: %v", err)
	}
	var original mount.Module
	for _, m := range st.AttachedModules {
		if m.ID == "m1" {
			original = m
			break
		}
	}
	if original.ID == "" {
		t.Fatalf("precondition: expected an m1 entry after pass 2, got %+v", st.AttachedModules)
	}
	row1 := original
	row1.PendingDigestUnitsTouched = false
	row1.PendingIntroducedUnits = nil
	row1.PendingUndoUnits = nil
	row2 := original
	row2.PendingDigestUnitsTouched = true
	row2.PendingIntroducedUnits = []string{unitA}
	row2.PendingUndoUnits = []string{unitB}
	st.AttachedModules = []mount.Module{row1, row2}
	if err := mount.SaveState(statePath, st); err != nil {
		t.Fatalf("SaveState (inject disagreeing duplicates): %v", err)
	}

	// Revert to d1 (stable). app stays active; the revert must force-
	// restart it back onto d1's binary, because ROW 2 (not row 1) says it
	// was touched.
	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture("d1", []string{"CAP_CHOWN"}, upgradeAppService)
	backdateManifestCache(t, manifestRoot, "m1")
	runner.StubOutput = map[string][]byte{"systemctl is-active " + appUnit: []byte("active\n")}

	pass3Start := len(runner.Invocations)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 3 (revert): %v", err)
	}
	pass3 := runner.Invocations[pass3Start:]

	if !hasSystemctlOp(pass3, "restart", appUnit) {
		t.Errorf("P9 REGRESSION: the revert must force-restart %s — row 2 says it was touched, and touched units are touched regardless of which duplicate row recorded them: %v", appUnit, pass3)
	}
	if !hasSystemctlOp(pass3, "stop", unitA) {
		t.Errorf("P9 REGRESSION: the revert must stop %s — row 2's own PendingIntroducedUnits names it, and reading only row 1 (empty) must not hide it: %v", unitA, pass3)
	}
	if !hasSystemctlOp(pass3, "start", unitB) {
		t.Errorf("P9 REGRESSION: the revert must retry %s via retryPendingUndoUnits — row 2's own PendingUndoUnits names it, and reading only row 1 (empty) must not hide it: %v", unitB, pass3)
	}
	if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "d1" {
		t.Errorf("expected m1 at d1 after the revert, got digest=%q ok=%v", digest, ok)
	}
}

// failingPuller wraps a PullerAPI, forcing an error for one specific
// digest — O8(d)'s own test uses it to simulate a pure step-1 (artifact
// pull/mount) refusal that never gets anywhere near step 2, 3 or 4.
type failingPuller struct {
	PullerAPI
	failDigest string
}

func (f *failingPuller) Pull(ref *oci.ModuleArtifactRef) (string, string, error) {
	if ref.Digest == f.failDigest {
		return "", "", fmt.Errorf("stub pull failure for digest %s (test)", ref.Digest)
	}
	return f.PullerAPI.Pull(ref)
}

// TestUpgradeModule_Step1RefusalSetsPendingDigestForN4Visibility is O8(d)'s
// own test (review round 12): a refusal at step 1 (artifact pull/mount)
// never touches a single unit — but before this fix, it also never set
// PendingDigest, so N4 (the server-side stuck-pending-digest sensor, which
// watches PendingDigest/the heartbeat's PendingModuleDigests) had no way to
// see a node stuck failing to even PULL a new digest's artifact, forever.
func TestUpgradeModule_Step1RefusalSetsPendingDigestForN4Visibility(t *testing.T) {
	r, client, _, _, statePath, manifestRoot, _ := upgradeTestReconciler(t)

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1: %v", err)
	}
	r.cfg.Puller = &failingPuller{PullerAPI: r.cfg.Puller, failDigest: "d2"}

	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture("d2", []string{"CAP_CHOWN"}, upgradeAppService)
	backdateManifestCache(t, manifestRoot, "m1")
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 2 (step 1 refused): %v", err)
	}

	if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "d1" {
		t.Fatalf("pass 2: expected the step-1 refusal to leave m1 at d1, got digest=%q ok=%v", digest, ok)
	}
	if pd, ok := pendingDigest(t, statePath, "m1"); !ok || pd != "d2" {
		t.Errorf("O8(d) REGRESSION: expected a step-1 refusal to still set PendingDigest=d2 (for N4 visibility), got %q ok=%v", pd, ok)
	}
	st, err := mount.LoadState(statePath)
	if err != nil {
		t.Fatalf("LoadState: %v", err)
	}
	for _, m := range st.AttachedModules {
		if m.ID == "m1" && m.PendingDigestUnitsTouched {
			t.Errorf("O8(d) REGRESSION: a step-1-only refusal must never reach step 4 — PendingDigestUnitsTouched must stay false, got true")
		}
	}
}

// countingFailingPuller is failingPuller plus a call counter for failDigest —
// P7's own test uses the counter to prove a backed-off tick issues NO pull
// attempt at all, not merely another refused one.
type countingFailingPuller struct {
	PullerAPI
	failDigest string
	calls      int
}

func (f *countingFailingPuller) Pull(ref *oci.ModuleArtifactRef) (string, string, error) {
	if ref.Digest == f.failDigest {
		f.calls++
		return "", "", fmt.Errorf("stub pull failure for digest %s (test)", ref.Digest)
	}
	return f.PullerAPI.Pull(ref)
}

func pendingDigestAttempts(t *testing.T, statePath, moduleID string) int {
	t.Helper()
	st, err := mount.LoadState(statePath)
	if err != nil {
		t.Fatalf("LoadState: %v", err)
	}
	for _, m := range st.AttachedModules {
		if m.ID == moduleID {
			return m.PendingDigestAttempts
		}
	}
	return 0
}

// TestUpgradeModule_Step1RefusalBacksOffLikeAStep4Failure is P7 (review
// round 13, LOW): before this fix, steps 1-3's own refusals never counted
// against backoffAllows — only step 4's own restart attempt did. A
// persistently failing artifact pull was therefore re-attempted on EVERY
// single reconcile tick forever, unlike an equally persistent step-4
// (restart) failure, which already backed off (see
// TestUpgradeModule_BackoffBoundsRepeatedRetries). The very first attempt
// and its first retry (attempts < 2) still proceed immediately, matching
// that same test's own tolerance — only the SECOND retry on is gated.
func TestUpgradeModule_Step1RefusalBacksOffLikeAStep4Failure(t *testing.T) {
	r, client, _, _, statePath, manifestRoot, _ := upgradeTestReconciler(t)

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1: %v", err)
	}
	puller := &countingFailingPuller{PullerAPI: r.cfg.Puller, failDigest: "d2"}
	r.cfg.Puller = puller

	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture("d2", []string{"CAP_CHOWN"}, upgradeAppService)
	backdateManifestCache(t, manifestRoot, "m1")

	fakeNow := time.Now()
	origNow := nowForUpgradeBackoff
	nowForUpgradeBackoff = func() time.Time { return fakeNow }
	t.Cleanup(func() { nowForUpgradeBackoff = origNow })

	// Attempt 1 (tick 2) and its free retry, attempt 2 (tick 3) — both
	// proceed immediately, no time advanced. Each is a genuine pull attempt.
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 2 (attempt 1): %v", err)
	}
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 3 (attempt 2): %v", err)
	}
	if got, want := puller.calls, 2; got != want {
		t.Fatalf("after attempt 2: expected %d genuine pull attempts, got %d", want, got)
	}
	if got, want := pendingDigestAttempts(t, statePath, "m1"), 2; got != want {
		t.Fatalf("after attempt 2: expected PendingDigestAttempts=%d, got %d", want, got)
	}

	// Tick 4: attempt 3 would be the SECOND retry — backed off, since no
	// time has passed. No pull attempt must be issued at all.
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 4 (backed off): %v", err)
	}
	if got, want := puller.calls, 2; got != want {
		t.Errorf("P7 REGRESSION: a backed-off tick must issue no pull attempt at all, got %d calls (want still %d)", got, want)
	}
	if got, want := pendingDigestAttempts(t, statePath, "m1"), 2; got != want {
		t.Errorf("P7 REGRESSION: a backed-off tick must leave PendingDigestAttempts unchanged, got %d want %d", got, want)
	}
	if pd, ok := pendingDigest(t, statePath, "m1"); !ok || pd != "d2" {
		t.Errorf("P7 REGRESSION: a backed-off tick must leave PendingDigest visible (still d2, for N4), got %q ok=%v", pd, ok)
	}

	// Advance the clock past the backoff window (attempts=2 → 20s) — the
	// next tick must retry (and, still blocked, count as attempt 3).
	fakeNow = fakeNow.Add(30 * time.Second)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 5 (backoff elapsed): %v", err)
	}
	if got, want := puller.calls, 3; got != want {
		t.Errorf("P7 REGRESSION: once the backoff window elapses, the next tick must retry the pull, got %d calls want %d", got, want)
	}
}

// TestUpgradeModule_RevertAfterStep1RefusalNeverRestartsTheUntouchedUnit is
// O8(d)'s own safety test: setting PendingDigest as early as step 1 (the
// fix above) must NOT make the revert path force-restart a unit that was
// NEVER TOUCHED by the abandoned attempt — that would be exactly the class
// of Rule-1 violation O8(a) fixed elsewhere in this round, just triggered a
// different way. After a step-1-only refusal, a revert to the stable digest
// must issue no restart of the (perfectly healthy, never-disturbed) unit at
// all, and must still clear PendingDigest.
func TestUpgradeModule_RevertAfterStep1RefusalNeverRestartsTheUntouchedUnit(t *testing.T) {
	r, client, runner, _, statePath, manifestRoot, _ := upgradeTestReconciler(t)
	appUnit := lifecycle.UnitName("m1", "app")

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1: %v", err)
	}
	r.cfg.Puller = &failingPuller{PullerAPI: r.cfg.Puller, failDigest: "d2"}
	// app is ACTIVE throughout (never disturbed by the abandoned d2 attempt,
	// which never got past the pull). This is the shape that actually fires
	// the guard: AttachServicesModeOpts only ever issues `restart` (as
	// opposed to the always-idempotent `start`) when the unit reads active
	// AND (ForceRestartActive or a body change) — an inactive unit would
	// read `start` on EITHER the buggy forced path or the correct unforced
	// one, silently passing this test either way. See
	// TestUpgradeModule_DeltaStopHappensOnlyAfterNewUnitStarts's own M1
	// doc for the same reasoning.
	runner.StubOutput = map[string][]byte{"systemctl is-active " + appUnit: []byte("active\n")}

	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture("d2", []string{"CAP_CHOWN"}, upgradeAppService)
	backdateManifestCache(t, manifestRoot, "m1")
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 2 (step 1 refused): %v", err)
	}
	if pd, ok := pendingDigest(t, statePath, "m1"); !ok || pd != "d2" {
		t.Fatalf("precondition: expected PendingDigest=d2 after the step-1 refusal, got %q ok=%v", pd, ok)
	}

	// Revert: point back at d1. The unit was NEVER touched by the abandoned
	// d2 attempt (it never got past the pull), so this must be a plain,
	// unforced no-op — a forced RESTART of the still-active, still-healthy
	// unit is the exact Rule-1 violation this test exists to catch.
	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture("d1", []string{"CAP_CHOWN"}, upgradeAppService)
	backdateManifestCache(t, manifestRoot, "m1")
	pass3Start := len(runner.Invocations)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 3 (revert): %v", err)
	}
	pass3 := runner.Invocations[pass3Start:]
	if hasSystemctlOp(pass3, "restart", appUnit) {
		t.Errorf("O8(d) REGRESSION: reverting an attempt that never touched %s must never RESTART it, invocations: %v", appUnit, pass3)
	}
	if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "d1" {
		t.Errorf("pass 3: expected m1 at d1, got digest=%q ok=%v", digest, ok)
	}
	if pd, ok := pendingDigest(t, statePath, "m1"); ok && pd != "" {
		t.Errorf("O8(d) REGRESSION: the revert must still clear PendingDigest, got %q", pd)
	}
}

// TestUpgradeBackoffFor_CapsAtFiveMinutes is O9's own mutant-kill test
// (review round 12, "5m backoff cap removed"): upgradeBackoffFor grows
// geometrically (10s * 2^(attempts-1)) but must never exceed 5 minutes — a
// crash-looping binary must be retried eventually, not backed off into the
// next hour. Direct unit test: no existing test pinned this cap at all
// (the O3/backoffAllows tests only ever exercise a couple of attempts, well
// under where the cap would bite).
func TestUpgradeBackoffFor_CapsAtFiveMinutes(t *testing.T) {
	const maxWait = 5 * time.Minute
	// 10s * 2^5 = 320s > 300s (5m) — attempts=6 is the first value the
	// UNCAPPED formula would exceed 5m at; anything beyond must stay pinned
	// at exactly maxWait, never keep growing.
	for _, attempts := range []int{6, 7, 20, 1000} {
		if got := upgradeBackoffFor(attempts); got != maxWait {
			t.Errorf("upgradeBackoffFor(%d) = %v, want the capped %v", attempts, got, maxWait)
		}
	}
	// Sanity: below the cap, it still actually grows (the cap engages
	// somewhere, not everywhere) — a mutant that always returns maxWait
	// would otherwise slip through the assertions above undetected.
	if got := upgradeBackoffFor(1); got != 10*time.Second {
		t.Errorf("upgradeBackoffFor(1) = %v, want 10s (uncapped)", got)
	}
	if got := upgradeBackoffFor(3); got != 40*time.Second {
		t.Errorf("upgradeBackoffFor(3) = %v, want 40s (uncapped)", got)
	}
	if got := upgradeBackoffFor(5); got >= maxWait {
		t.Errorf("upgradeBackoffFor(5) = %v, want still below the %v cap (160s uncapped)", got, maxWait)
	}
}

// TestUpgradeModule_N8DeclinesWhenTheFailingUnitIsShared is O9's own
// mutant-kill test (review round 12, "N8 shared-unit guard removed"):
// recoverFromDepartingUnitConflict's own oldUnitSet check declines to act
// at all when a FAILING unit is one the OLD digest also owned — a unit
// that existed before this upgrade cannot be "a new unit that lost a bind
// race against a departing one", so its failure is a genuine crash, never
// N8's class of bug.
//
// TestUpgradeModule_CrashAfterRestartRefusesCommitAndLeavesOldRunning
// already has a shared unit (app) fail, but its departing unit (old-worker)
// is never marked active there, so N8 would ALSO decline via its separate
// "nothing departing is even holding anything" check even with the
// oldUnitSet guard removed entirely — that test cannot tell the two guards
// apart. This test marks the departing unit ACTIVE, so removing JUST the
// oldUnitSet guard would let N8 proceed: stop the healthy departing unit
// and retry the shared unit, wrongly treating a genuine crash as a port
// conflict.
func TestUpgradeModule_N8DeclinesWhenTheFailingUnitIsShared(t *testing.T) {
	r, client, runner, _, statePath, manifestRoot, _ := upgradeTestReconciler(t)

	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture(
		"d1", []string{"CAP_CHOWN"}, upgradeAppService+","+upgradeWorkerService)
	appUnit := lifecycle.UnitName("m1", "app")
	oldWorkerUnit := lifecycle.UnitName("m1", "old-worker")

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1: %v", err)
	}

	// Bump drops old-worker (a genuine departure) but app — SHARED by both
	// digests — is what actually crashes on restart, exactly like
	// TestUpgradeModule_CrashAfterRestartRefusesCommitAndLeavesOldRunning,
	// except old-worker is explicitly ACTIVE so a guard-removed N8 would
	// find something to "recover" from.
	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture("d2", []string{"CAP_CHOWN"}, upgradeAppService)
	backdateManifestCache(t, manifestRoot, "m1")

	appIsActiveKey := "systemctl is-active " + appUnit
	runner.StubOutput = map[string][]byte{
		appIsActiveKey:                         []byte("active\n"),
		"systemctl is-active " + oldWorkerUnit: []byte("active\n"),
	}
	origSleep := sleepForUpgradeSettle
	sleepForUpgradeSettle = func(d time.Duration) {
		delete(runner.StubOutput, appIsActiveKey) // app crashes inside the settle window
		origSleep(d)
	}
	t.Cleanup(func() { sleepForUpgradeSettle = origSleep })

	tick2Start := len(runner.Invocations)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 2: %v", err)
	}
	tick2 := runner.Invocations[tick2Start:]

	if hasSystemctlOp(tick2, "stop", oldWorkerUnit) {
		t.Errorf("O9 REGRESSION (N8 shared-unit guard removed): a SHARED unit's genuine crash must never trigger N8's conflict recovery — old-worker (healthy, departing) must not be stopped: %v", tick2)
	}
	if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "d1" {
		t.Errorf("expected the genuine crash to refuse the commit, m1 still at d1, got digest=%q ok=%v", digest, ok)
	}
	if pd, ok := pendingDigest(t, statePath, "m1"); !ok || pd != "d2" {
		t.Errorf("expected PendingDigest=d2 to remain set after the refusal, got %q ok=%v", pd, ok)
	}
}

// TestUpgradeModule_CommitClearsTheDropInSnapshotStoreFile is O9's own
// mutant-kill test (review round 12, "N7 snapshot clear on commit
// dropped"): upgradeModule's step 7 commit prunes the STATE-dir drop-in
// snapshot store for (moduleID, committedDigest) via
// pruneDropInSnapshotsForModule(..., ""). TestLoadOrTakeDropInSnapshot_
// PersistsAndReusesAcrossAttempts already pins clearDropInSnapshotStore's
// OWN reuse semantics by calling it directly, but never exercises whether
// upgradeModule's actual commit path calls it AT ALL — a mutant that drops
// just that call site survives that test untouched. This test goes through
// RunOnce end to end and checks the on-disk file itself.
func TestUpgradeModule_CommitClearsTheDropInSnapshotStoreFile(t *testing.T) {
	r, client, runner, _, statePath, manifestRoot, _ := upgradeTestReconciler(t)
	unit := lifecycle.UnitName("m1", "app")

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1: %v", err)
	}

	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture("d2", []string{"CAP_CHOWN"}, upgradeAppService)
	backdateManifestCache(t, manifestRoot, "m1")
	runner.StubOutput = map[string][]byte{"systemctl is-active " + unit: []byte("active\n")}
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 2 (commits to d2): %v", err)
	}
	if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "d2" {
		t.Fatalf("precondition: expected m1 committed to d2, got digest=%q ok=%v", digest, ok)
	}

	snapPath := dropInSnapshotStorePath(filepath.Dir(statePath), "m1", "d2")
	if _, err := os.Stat(snapPath); !os.IsNotExist(err) {
		t.Errorf("O9 REGRESSION (N7 snapshot clear on commit dropped): expected the drop-in snapshot file %s to be removed once the upgrade commits, stat err=%v", snapPath, err)
	}
}

// TestUpgradeModule_RevertActuallyRestartsAnActiveUnit is O9's own
// mutant-kill test (review round 12, "revert with forceRestartActive=false"):
// the revert path's own attachModuleServicesOpts call passes
// forceRestartActive=true specifically so a unit the failed attempt left
// running the OLD binary in a bad state gets RESTARTED, not merely left
// alone. Every existing revert test (e.g.
// TestUpgradeModule_RevertAfterSettleFailureRestartsAndClearsPending)
// leaves app at RecorderRunner's default "not active" and asserts only
// "SOME start/restart" — AttachServicesModeOpts issues a plain `start` for
// an inactive unit regardless of forceRestartActive, so those tests cannot
// tell true from false. This test marks app ACTIVE throughout and asserts
// the exact verb: only forceRestartActive=true (with the unit active)
// produces `restart`; false would produce nothing at all here (Skipped,
// since d1's manifest body is unchanged).
func TestUpgradeModule_RevertActuallyRestartsAnActiveUnit(t *testing.T) {
	r, client, runner, _, statePath, manifestRoot, _ := upgradeTestReconciler(t)
	appUnit := lifecycle.UnitName("m1", "app")

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1: %v", err)
	}

	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture("d2", []string{"CAP_CHOWN"}, upgradeAppService)
	backdateManifestCache(t, manifestRoot, "m1")
	appIsActiveKey := "systemctl is-active " + appUnit
	runner.StubOutput = map[string][]byte{appIsActiveKey: []byte("active\n")}
	origSleep := sleepForUpgradeSettle
	sleepForUpgradeSettle = func(d time.Duration) {
		delete(runner.StubOutput, appIsActiveKey) // crash inside the settle window
		origSleep(d)
	}
	t.Cleanup(func() { sleepForUpgradeSettle = origSleep })
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 2 (crash inside settle window): %v", err)
	}
	if pd, ok := pendingDigest(t, statePath, "m1"); !ok || pd != "d2" {
		t.Fatalf("precondition: expected PendingDigest=d2, got %q ok=%v", pd, ok)
	}

	// Revert to d1 — app is marked ACTIVE this time (the crash left SOME
	// process running, e.g. a supervisor that respawned it) so the verb
	// choice is actually observable.
	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture("d1", []string{"CAP_CHOWN"}, upgradeAppService)
	backdateManifestCache(t, manifestRoot, "m1")
	runner.StubOutput = map[string][]byte{appIsActiveKey: []byte("active\n")}

	tick3Start := len(runner.Invocations)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 3 (revert): %v", err)
	}
	tick3 := runner.Invocations[tick3Start:]
	if !hasSystemctlOp(tick3, "restart", appUnit) {
		t.Errorf("O9 REGRESSION (forceRestartActive=false): the revert must RESTART an active unit left over from the failed attempt, got: %v", tick3)
	}
}

// TestUpgradeModule_SettleCheckRejectsOnFailureUnitReportingSuccess is O5's
// own hardening test (review round 12, Review B's DO-NOT-SHIP blocker):
// TestUpgradeModule_SettleCheckRejectsPersistentUnitReportingSuccess only
// ever exercised restart_policy:"always". restart_policy:"on-failure" — the
// manifest DEFAULT (lifecycle.restartDirective maps both "on-failure" and
// an OMITTED restart_policy to systemd's Restart=on-failure) — is a
// DIFFERENT, and more common, shape: systemd does NOT restart an
// on-failure unit that exits 0, so a broken new binary that starts and
// immediately exits cleanly just stays dead, forever, with Result=success
// and no restart loop at all — no crash-loop signature to notice by eye,
// unlike the "always" case. unitSettled's runsOnce gate (true only for
// restart_policy:"never") must refuse this exactly like the "always" case:
// runsOnceByUnit keys ONLY off "never", so "on-failure" and "always" are
// already handled identically by construction — this test exists to prove
// that with a fixture no future refactor can quietly special-case around.
func TestUpgradeModule_SettleCheckRejectsOnFailureUnitReportingSuccess(t *testing.T) {
	r, client, runner, _, statePath, manifestRoot, _ := upgradeTestReconciler(t)
	onFailureService := `{"name":"app", "start_command":"/bin/true", "restart_policy":"on-failure"}`
	unit := lifecycle.UnitName("m1", "app")

	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture("d1", []string{"CAP_CHOWN"}, onFailureService)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1: %v", err)
	}

	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture("d2", []string{"CAP_CHOWN"}, onFailureService)
	backdateManifestCache(t, manifestRoot, "m1")

	// app is active going in; the new binary starts and immediately exits
	// cleanly — Result=success, no ConditionResult opinion, exactly what a
	// broken-but-not-crashing on-failure unit reports. systemd's own
	// Restart=on-failure semantics mean this unit will NEVER restart on its
	// own from here — it just stays dead.
	appIsActiveKey := "systemctl is-active " + unit
	runner.StubOutput = map[string][]byte{
		appIsActiveKey: []byte("active\n"),
		"systemctl show " + unit + " --property=Result --value": []byte("success\n"),
	}
	origSleep := sleepForUpgradeSettle
	sleepForUpgradeSettle = func(d time.Duration) {
		delete(runner.StubOutput, appIsActiveKey)
		origSleep(d)
	}
	t.Cleanup(func() { sleepForUpgradeSettle = origSleep })

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 2: %v", err)
	}

	if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "d1" {
		t.Errorf("O5 REGRESSION (Review B blocker): an on-failure unit reporting Result=success while inactive must NOT settle — a broken binary that exits 0 once and never restarts stays dead forever with no alert otherwise. Expected m1 still at d1, got digest=%q ok=%v", digest, ok)
	}
	if pd, ok := pendingDigest(t, statePath, "m1"); !ok || pd != "d2" {
		t.Errorf("expected PendingDigest=d2 to remain set (visible, not silently dropped) after the refusal, got %q ok=%v", pd, ok)
	}
}

// TestReconcile_DuplicateBumpEntryRunsUpgradeExactlyOnce is O10's own test
// (review round 12, review B): N9's dedupe-by-ID guard (reconcile.go's
// bumpedIDs check) has never been directly tested — deleting that whole
// block leaves the suite green. Constructs the exact shape N9 exists for:
// state.json somehow carries TWO entries for module id "m1" at two
// DIFFERENT stale digests (d1, d2), while the platform now assigns a THIRD
// digest (d3) — mount.Reconcile diffs by DIGEST, so both stale entries land
// in toDetach and BOTH match d3 in the bump partition's newByID lookup.
// Without the dedupe, upgradeModule would run TWICE for "m1" in the same
// tick: a second `start`/`restart` of the SAME unit mid an already-running
// attempt, and a second step-7 replace of an entry the first run already
// replaced.
func TestReconcile_DuplicateBumpEntryRunsUpgradeExactlyOnce(t *testing.T) {
	r, client, runner, _, statePath, _, _ := upgradeTestReconciler(t)
	appUnit := lifecycle.UnitName("m1", "app")

	if err := mount.SaveState(statePath, &mount.State{
		AttachedModules: []mount.Module{
			{ID: "m1", Digest: "d1", Priority: 100, Units: []string{appUnit}},
			{ID: "m1", Digest: "d2", Priority: 100, Units: []string{appUnit}},
		},
		LastAttachedManifestHashes: map[string]string{},
	}); err != nil {
		t.Fatalf("SaveState (seed duplicate stale entries): %v", err)
	}

	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture("d3", []string{"CAP_CHOWN"}, upgradeAppService)
	// app must actually settle for the surviving bump to COMMIT — otherwise
	// this test can't tell "N9 dedupe worked" apart from "the settle check
	// simply refused both attempts", which would trivially satisfy
	// starts==1 for the wrong reason (only the first attempt would even
	// reach step 4 before the dedupe drops the second's whole invocation
	// either way, but without this the commit-count assertion below is
	// meaningless).
	runner.StubOutput = map[string][]byte{"systemctl is-active " + appUnit: []byte("active\n")}

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce: %v", err)
	}

	starts := 0
	for _, inv := range runner.Invocations {
		if inv.Name == "systemctl" && inv.Op == "Run" && containsArg(inv.Args, appUnit) &&
			(containsArg(inv.Args, "start") || containsArg(inv.Args, "restart")) {
			starts++
		}
	}
	if starts != 1 {
		t.Errorf("O10 REGRESSION (N9 dedupe removed): expected exactly ONE start/restart of %s, got %d: %v", appUnit, starts, runner.Invocations)
	}

	// The dropped duplicate's OWN state row (d1 or d2, whichever the
	// surviving bump did not use as `old`) is left untouched by N9's dedupe
	// on THIS tick — N9's own scope is only "don't run upgradeModule twice",
	// not state cleanup. That is not a dangling bug: it is exactly the
	// shape the PRE-EXISTING M4 fix (b) path (reconcile.go's desiredIDs
	// check) exists to clean up — "the module is still desired and already
	// satisfied by a different attached digest" — just deferred to the
	// FIRST tick where the orphan no longer also matches newByID (i.e. the
	// very next tick, once d3 already satisfies desired and is no longer a
	// bump target). Confirmed here rather than assumed: one more no-op tick
	// must leave exactly one m1 entry, at d3, with NO unit touched during
	// that cleanup.
	orphanTick := len(runner.Invocations)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce (orphan cleanup tick): %v", err)
	}
	if hasSystemctlOp(runner.Invocations[orphanTick:], "stop", appUnit) || hasSystemctlOp(runner.Invocations[orphanTick:], "start", appUnit) || hasSystemctlOp(runner.Invocations[orphanTick:], "restart", appUnit) {
		t.Errorf("M4 fix (b) REGRESSION: cleaning up the orphaned duplicate must never touch %s, invocations: %v", appUnit, runner.Invocations[orphanTick:])
	}

	st, err := mount.LoadState(statePath)
	if err != nil {
		t.Fatalf("LoadState: %v", err)
	}
	count := 0
	for _, m := range st.AttachedModules {
		if m.ID == "m1" {
			count++
			if m.Digest != "d3" {
				t.Errorf("expected the surviving m1 entry at d3, got %s", m.Digest)
			}
		}
	}
	if count != 1 {
		t.Errorf("O10 REGRESSION: expected exactly ONE m1 entry once the orphaned duplicate is cleaned up, got %d: %+v", count, st.AttachedModules)
	}
}

// loadModuleServiceUnitBody reads THE REAL modules/<moduleDir>/manifest.yaml
// (not a fixture reproducing it — same posture as
// qga_manifest_capabilities_test.go's loadModuleManifestYAML) and returns
// the verbatim unit_body: block for the named service, so P1's own test
// (review round 13) pins the settle check against the actual claude-tmux
// credential unit shape, not a hand-written approximation that could drift
// from it.
func loadModuleServiceUnitBody(t *testing.T, moduleDir, serviceName string) string {
	t.Helper()
	path := filepath.Join("..", "..", "..", "modules", moduleDir, "manifest.yaml")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v (run from agent/internal/runtime? cwd assumption may be stale)", path, err)
	}
	var doc struct {
		Services []struct {
			Name     string `yaml:"name"`
			UnitBody string `yaml:"unit_body"`
		} `yaml:"services"`
	}
	if err := yaml.Unmarshal(raw, &doc); err != nil {
		t.Fatalf("parse %s: %v", path, err)
	}
	for _, s := range doc.Services {
		if s.Name == serviceName {
			if s.UnitBody == "" {
				t.Fatalf("%s: service %q has no unit_body — fixture drifted from what this test expects", path, serviceName)
			}
			return s.UnitBody
		}
	}
	t.Fatalf("%s: no service named %q", path, serviceName)
	return ""
}

// unitBodyServiceJSON builds a raw services: entry declaring ONLY name +
// unit_body — no restart_policy at all, matching every real unit_body
// service in this repo (P1, review round 13: restart_policy is INERT for a
// unit_body service — lifecycle.renderUnitBodyMode never reads it — so a
// fixture that also set restart_policy would test a shape no real manifest
// has).
func unitBodyServiceJSON(t *testing.T, name, unitBody string) string {
	t.Helper()
	encodedBody, err := json.Marshal(unitBody)
	if err != nil {
		t.Fatalf("marshal unit_body: %v", err)
	}
	encodedName, err := json.Marshal(name)
	if err != nil {
		t.Fatalf("marshal name: %v", err)
	}
	return fmt.Sprintf(`{"name":%s, "unit_body":%s}`, encodedName, encodedBody)
}

// TestUpgradeModule_RealClaudeTmuxCredentialUnitCommitsInOneTick is P1's own
// test (review round 13, HIGH — Review A verified, Review B independently
// confirmed): the real claude-tmux credential unit is Type=oneshot with NO
// RemainAfterExit, declared via unit_body (option A2), and declares NO
// restart_policy field at all — exactly the shape O5 (round 12) got wrong,
// misjudging it as PERSISTENT (restart_policy:"never" was the only signal
// O5 consulted) and refusing every bump forever, which force-restarted
// every active unit of the module on every retry (including a live tmux
// session) roughly every 5 minutes, fleet-wide, once this module was
// assigned anywhere.
//
// Deliberately does NOT stub `systemctl show <unit> --property=Type
// --value` — RecorderRunner's unstubbed default is an empty string, so this
// exercises unitRunsOnce's SECOND signal (parsing Type=oneshot out of the
// real unit_body text) rather than the live-systemd-query path, which
// TestUpgradeModule_LiveSystemdTypeQueryOverridesUnitBodyOneshotGuess below
// exercises on its own.
func TestUpgradeModule_RealClaudeTmuxCredentialUnitCommitsInOneTick(t *testing.T) {
	credentialBody := loadModuleServiceUnitBody(t, "claude-tmux", "credential")
	credentialService := unitBodyServiceJSON(t, "credential", credentialBody)

	r, client, runner, _, statePath, manifestRoot, _ := upgradeTestReconciler(t)
	credentialUnit := lifecycle.UnitName("m1", "credential")

	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture(
		"d1", []string{"CAP_CHOWN"}, upgradeAppService+","+credentialService)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1: %v", err)
	}

	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture(
		"d2", []string{"CAP_CHOWN"}, upgradeAppService+","+credentialService)
	backdateManifestCache(t, manifestRoot, "m1")

	appUnit := lifecycle.UnitName("m1", "app")
	// app (a normal persistent unit) settles by staying active. credential
	// runs its course and exits cleanly EVERY time this module reconciles —
	// that is its designed steady state, exactly as real staging behaves
	// (see the manifest's own comment: "no RemainAfterExit ... the session
	// unit reads the staged file"). No is-active stub for credentialUnit at
	// all (RecorderRunner's default, "not active", matches a oneshot that
	// has already finished by the time the settle check looks).
	runner.StubOutput = map[string][]byte{
		"systemctl is-active " + appUnit:                                  []byte("active\n"),
		"systemctl show " + credentialUnit + " --property=Result --value": []byte("success\n"),
	}

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 2: %v", err)
	}

	if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "d2" {
		t.Errorf("P1 REGRESSION: the real claude-tmux credential unit (Type=oneshot via unit_body, no restart_policy) must not block the commit — expected m1 at d2, got digest=%q ok=%v", digest, ok)
	}
}

// TestUpgradeModule_LiveSystemdTypeQueryOverridesUnitBodyOneshotGuess proves
// unitRunsOnce's PRIMARY signal — the live `systemctl show -p Type` query —
// works standalone, independent of both the unit_body-text fallback and the
// restart_policy field: a plain generated-unit service (no unit_body at
// all, restart_policy left at the "on-failure" default) whose LIVE Type
// property nonetheless reports "oneshot" must still be treated as run-once.
// This is the review's own stated priority ("Query systemctl show -p Type
// at settle time; that is authoritative") — a fixture using only the
// unit_body-parse fallback (as the claude-tmux test above does) cannot
// distinguish "the live query works" from "the fallback alone is doing all
// the work".
func TestUpgradeModule_LiveSystemdTypeQueryOverridesUnitBodyOneshotGuess(t *testing.T) {
	r, client, runner, _, statePath, manifestRoot, _ := upgradeTestReconciler(t)
	unit := lifecycle.UnitName("m1", "app")

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1: %v", err)
	}

	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture("d2", []string{"CAP_CHOWN"}, upgradeAppService)
	backdateManifestCache(t, manifestRoot, "m1")

	runner.StubOutput = map[string][]byte{
		"systemctl is-active " + unit:                           []byte("active\n"),
		"systemctl show " + unit + " --property=Type --value":   []byte("oneshot\n"),
		"systemctl show " + unit + " --property=Result --value": []byte("success\n"),
	}
	origSleep := sleepForUpgradeSettle
	sleepForUpgradeSettle = func(d time.Duration) {
		delete(runner.StubOutput, "systemctl is-active "+unit)
		origSleep(d)
	}
	t.Cleanup(func() { sleepForUpgradeSettle = origSleep })

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 2: %v", err)
	}

	if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "d2" {
		t.Errorf("P1 REGRESSION: a unit whose LIVE systemd Type= reports oneshot must settle on Result=success even with no unit_body and no restart_policy:\"never\" declared — expected m1 at d2, got digest=%q ok=%v", digest, ok)
	}
}

// TestUpgradeModule_RevertAfterReTargetStillForcesRestartAndStopsIntroducedUnit
// is P2's own test (review round 13, HIGH — a regression O8(d), round 12,
// introduced): d2 is TOUCHED (step 4 actually restarts app and starts the
// new-only new-worker) but never commits (new-worker never settles). The
// platform then re-targets to d3, which is refused at step 1 — never
// touching a single unit itself. A later revert to the stable digest d1
// must still (a) FORCE-RESTART app, because d2's own step 4 already put it
// on a different binary, and (b) STOP new-worker, because d2 introduced it
// and nothing else ever will. Before this fix, re-targeting to d3 reset
// PendingDigestUnitsTouched to false, so the revert read "nothing touched"
// and did neither.
func TestUpgradeModule_RevertAfterReTargetStillForcesRestartAndStopsIntroducedUnit(t *testing.T) {
	r, client, runner, _, statePath, manifestRoot, _ := upgradeTestReconciler(t)
	appUnit := lifecycle.UnitName("m1", "app")
	newWorkerUnit := lifecycle.UnitName("m1", "new-worker")

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1 (attach d1, app only): %v", err)
	}

	// d2 TOUCHES: app force-restarts (active going in), new-worker is
	// started but never becomes active — a permanent settle failure (no
	// departing unit exists to blame, so N8 conflict-recovery declines and
	// this stays refused). PendingDigest=d2, UnitsTouched=true,
	// IntroducedUnits=[new-worker] from here on.
	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture(
		"d2", []string{"CAP_CHOWN"}, upgradeAppService+","+upgradeNewWorkerService)
	backdateManifestCache(t, manifestRoot, "m1")
	runner.StubOutput = map[string][]byte{"systemctl is-active " + appUnit: []byte("active\n")}
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 2 (d2 touched, refused): %v", err)
	}
	if pd, ok := pendingDigest(t, statePath, "m1"); !ok || pd != "d2" {
		t.Fatalf("precondition: expected PendingDigest=d2 after pass 2, got %q ok=%v", pd, ok)
	}

	// Re-target to d3 — refused at step 1, before touching anything.
	r.cfg.Puller = &failingPuller{PullerAPI: r.cfg.Puller, failDigest: "d3"}
	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture("d3", []string{"CAP_CHOWN"}, upgradeAppService)
	backdateManifestCache(t, manifestRoot, "m1")
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 3 (d3 refused at step 1): %v", err)
	}
	if pd, ok := pendingDigest(t, statePath, "m1"); !ok || pd != "d3" {
		t.Fatalf("precondition: expected the re-target to set PendingDigest=d3, got %q ok=%v", pd, ok)
	}

	// Revert to d1 (stable). app stays active (d2's own restart put it
	// there); the revert must force-restart it back onto d1's binary.
	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture("d1", []string{"CAP_CHOWN"}, upgradeAppService)
	backdateManifestCache(t, manifestRoot, "m1")
	runner.StubOutput = map[string][]byte{"systemctl is-active " + appUnit: []byte("active\n")}

	pass4Start := len(runner.Invocations)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 4 (revert): %v", err)
	}
	pass4 := runner.Invocations[pass4Start:]

	if !hasSystemctlOp(pass4, "restart", appUnit) {
		t.Errorf("P2 REGRESSION: the revert must FORCE-RESTART %s — d2's own step 4 already put it on a different binary, and a re-target to d3 must not have erased that fact: %v", appUnit, pass4)
	}
	if !hasSystemctlOp(pass4, "stop", newWorkerUnit) {
		t.Errorf("P2 REGRESSION: the revert must STOP %s — d2 introduced it and nothing else ever will once d2 is abandoned: %v", newWorkerUnit, pass4)
	}
	if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "d1" {
		t.Errorf("expected m1 at d1 after the revert, got digest=%q ok=%v", digest, ok)
	}
	if pd, ok := pendingDigest(t, statePath, "m1"); ok && pd != "" {
		t.Errorf("expected PendingDigest cleared after the revert, got %q", pd)
	}
}

// TestUpgradeModule_LaterCommitStopsAnEarlierAbandonedTargetsIntroducedUnit
// is P2's own second test (review round 13): d2 is TOUCHED and introduces
// new-worker (same setup as above), but instead of reverting, d3 is
// re-targeted AND COMMITS. d3's own manifest never names new-worker either
// (it matches d1's shape) — step 5's delta-stop must still stop it, using
// old.PendingIntroducedUnits unioned into oldUnits, since new-worker is
// absent from BOTH the stable digest's own units AND the committing
// target's manifest.
func TestUpgradeModule_LaterCommitStopsAnEarlierAbandonedTargetsIntroducedUnit(t *testing.T) {
	r, client, runner, _, statePath, manifestRoot, _ := upgradeTestReconciler(t)
	appUnit := lifecycle.UnitName("m1", "app")
	newWorkerUnit := lifecycle.UnitName("m1", "new-worker")

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1 (attach d1, app only): %v", err)
	}

	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture(
		"d2", []string{"CAP_CHOWN"}, upgradeAppService+","+upgradeNewWorkerService)
	backdateManifestCache(t, manifestRoot, "m1")
	runner.StubOutput = map[string][]byte{"systemctl is-active " + appUnit: []byte("active\n")}
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 2 (d2 touched, refused): %v", err)
	}
	if pd, ok := pendingDigest(t, statePath, "m1"); !ok || pd != "d2" {
		t.Fatalf("precondition: expected PendingDigest=d2 after pass 2, got %q ok=%v", pd, ok)
	}

	// Re-target to d3 — app only, same shape as d1, and this time it
	// SETTLES (app stays active throughout).
	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture("d3", []string{"CAP_CHOWN"}, upgradeAppService)
	backdateManifestCache(t, manifestRoot, "m1")
	runner.StubOutput = map[string][]byte{"systemctl is-active " + appUnit: []byte("active\n")}

	pass3Start := len(runner.Invocations)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 3 (d3 commits): %v", err)
	}
	pass3 := runner.Invocations[pass3Start:]

	if !hasSystemctlOp(pass3, "stop", newWorkerUnit) {
		t.Errorf("P2 REGRESSION: d3's commit must STOP %s — d2 introduced it, d3's own manifest never names it, and the stable digest never owned it either: %v", newWorkerUnit, pass3)
	}
	if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "d3" {
		t.Errorf("expected m1 committed to d3, got digest=%q ok=%v", digest, ok)
	}
	if pd, ok := pendingDigest(t, statePath, "m1"); ok && pd != "" {
		t.Errorf("expected PendingDigest cleared after the commit, got %q", pd)
	}
}

// upgradeModuleFixturePrivilegedWithSudoer builds a fixture that declares a
// sudoers grant and, when privileged is true, requests security.privileged
// with no operator approval — decideModuleSecurityPolicy refuses that
// deterministically at step 2, every tick, with no need to stub systemctl
// at all (P3's own test, review round 13).
func upgradeModuleFixturePrivilegedWithSudoer(digest string, privileged bool, sudoerID string) string {
	return fmt.Sprintf(`{
		"success": true,
		"data": {
			"id":"m1", "name":"app-mod",
			"priority":100, "effective_priority":100,
			"digest":"%s",
			"config": {"security": {"capabilities": ["CAP_CHOWN"], "user_namespace": false, "privileged": %v}},
			"sudoers": [{"id":%q,"user":"pnadmin","runas_user":"root","commands":["/bin/true"]}],
			"services": [%s]
		}
	}`, digest, privileged, sudoerID, upgradeAppService)
}

// TestReconcile_RefusedBumpNeverRendersItsOwnSudoersGrant is P3's own test
// (review round 13, MEDIUM, security): the identity/sudoers old∪new union
// previously applied to ANY bump unconditionally, so a digest refused at
// step 2 (an unapproved security.privileged request, here) still widened
// sudoers with a grant NOTHING approved — and kept doing so on EVERY tick
// it stayed refused, since a step-2 refusal alone never clears
// PendingDigest. Runs the SAME refused d2 for three ticks and asserts its
// sudoers grant is never once rendered.
func TestReconcile_RefusedBumpNeverRendersItsOwnSudoersGrant(t *testing.T) {
	r, client, _, _, statePath, manifestRoot, _ := upgradeTestReconciler(t)

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1 (attach d1, no sudoers): %v", err)
	}

	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixturePrivilegedWithSudoer("d2", true, "d2-only-grant")
	backdateManifestCache(t, manifestRoot, "m1")

	var renderedGrantIDs []string
	origSudoers := applySudoers
	applySudoers = func(grants []etcsudoers.Grant) error {
		for _, g := range grants {
			renderedGrantIDs = append(renderedGrantIDs, g.Grant.ID)
		}
		return nil
	}
	t.Cleanup(func() { applySudoers = origSudoers })

	for tick := 1; tick <= 3; tick++ {
		if err := r.RunOnce(context.Background()); err != nil {
			t.Fatalf("RunOnce tick %d (d2 refused at step 2): %v", tick, err)
		}
	}

	for _, id := range renderedGrantIDs {
		if id == "d2-only-grant" {
			t.Fatalf("P3 REGRESSION: d2's own sudoers grant was rendered even though d2 was refused at step 2 on every tick: %v", renderedGrantIDs)
		}
	}
	if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "d1" {
		t.Errorf("precondition drifted: expected m1 to stay refused at d1, got digest=%q ok=%v", digest, ok)
	}
}

// TestReconcile_RevertRetriesPendingUndoUnitsAtTheTop is P4's own test
// (review round 13, MEDIUM): a departing unit N8's own undo could not
// restart, even after its in-attempt retry (O6, review round 12) — a
// genuine outage, persisted onto PendingUndoUnits. Before this fix, a
// module that re-targeted or reverted away from THAT digest never reached
// upgradeModule again at all (it goes through reconcile.go's own revert
// branch instead), so PendingUndoUnits sat unattended: the revert's own
// force-restart might coincidentally restart the same unit as part of the
// stable digest's manifest, but nothing ever CONFIRMED it or cleared the
// list — a unit that recovered stayed marked down forever.
func TestReconcile_RevertRetriesPendingUndoUnitsAtTheTop(t *testing.T) {
	r, client, runner, _, statePath, manifestRoot, _ := upgradeTestReconciler(t)

	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture(
		"d1", []string{"CAP_CHOWN"}, upgradeAppService+","+upgradeWorkerService)
	appUnit := lifecycle.UnitName("m1", "app")
	oldWorkerUnit := lifecycle.UnitName("m1", "old-worker")
	newWorkerUnit := lifecycle.UnitName("m1", "new-worker")

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1: %v", err)
	}

	// Bump to d2: new-worker never comes up (N8 fires, stops old-worker to
	// free whatever it held), and old-worker's own undo restart fails on
	// BOTH attempts within N8's own call — a genuine, still-unresolved
	// outage, persisted onto PendingUndoUnits.
	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture(
		"d2", []string{"CAP_CHOWN"}, upgradeAppService+","+upgradeNewWorkerService)
	backdateManifestCache(t, manifestRoot, "m1")
	oldWorkerStartKey := "systemctl start " + oldWorkerUnit
	runner.StubOutput = map[string][]byte{
		"systemctl is-active " + appUnit:       []byte("active\n"),
		"systemctl is-active " + oldWorkerUnit: []byte("active\n"),
		"systemctl is-active " + newWorkerUnit: []byte("inactive\n"), // never comes up
	}
	runner.StubErr = map[string]error{oldWorkerStartKey: errors.New("undo failed (both attempts)")}

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 2 (N8 fires, undo fails twice): %v", err)
	}
	st, err := mount.LoadState(statePath)
	if err != nil {
		t.Fatalf("LoadState: %v", err)
	}
	found := false
	for _, m := range st.AttachedModules {
		if m.ID == "m1" {
			found = containsArg(m.PendingUndoUnits, oldWorkerUnit)
		}
	}
	if !found {
		t.Fatalf("precondition: expected PendingUndoUnits to contain %s after pass 2, got state: %+v", oldWorkerUnit, st.AttachedModules)
	}

	// Revert to d1 (stable). Whatever was blocking old-worker's restart is
	// now fixed — old-worker starts INACTIVE this tick (still down from N8's
	// failed undo) and flips active the moment ANY `start` call succeeds
	// against it, whichever code path issues it. This is the discriminator
	// that actually distinguishes P4's fix from its absence: if the
	// priority retry runs FIRST (at the top of the revert branch, per the
	// fix) and reactivates old-worker, the ORDINARY force-restart section
	// later in the SAME tick sees it already active and issues `restart`;
	// without the fix, old-worker is still inactive when the ordinary
	// section's own is-active check runs, and it issues a plain `start`
	// instead — asserting "some start happened" cannot tell the two apart,
	// since both paths eventually issue a successful start somewhere.
	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture(
		"d1", []string{"CAP_CHOWN"}, upgradeAppService+","+upgradeWorkerService)
	backdateManifestCache(t, manifestRoot, "m1")
	delete(runner.StubErr, oldWorkerStartKey)
	runner.StubOutput["systemctl is-active "+oldWorkerUnit] = []byte("inactive\n")
	hooked := &hookRunner{Runner: runner, onRun: func(name string, args []string) {
		if name == "systemctl" && containsArg(args, "start") && containsArg(args, oldWorkerUnit) {
			runner.StubOutput["systemctl is-active "+oldWorkerUnit] = []byte("active\n")
		}
	}}
	r.cfg.MountRunner = hooked

	pass3Start := len(runner.Invocations)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 3 (revert): %v", err)
	}
	pass3 := runner.Invocations[pass3Start:]

	if !hasSystemctlOp(pass3, "restart", oldWorkerUnit) {
		t.Errorf("P4 REGRESSION: expected the priority retry to reactivate %s BEFORE the ordinary revert force-restart runs (which would then see it active and RESTART it, not start it): %v", oldWorkerUnit, pass3)
	}
	st, err = mount.LoadState(statePath)
	if err != nil {
		t.Fatalf("LoadState after revert: %v", err)
	}
	for _, m := range st.AttachedModules {
		if m.ID == "m1" && len(m.PendingUndoUnits) > 0 {
			t.Errorf("P4 REGRESSION: PendingUndoUnits must be cleared once %s is confirmed active, got %v", oldWorkerUnit, m.PendingUndoUnits)
		}
	}
}

// TestRetryPendingUndoUnits_ClearsOnlyTheConfirmedActiveUnit is P5's own
// mutant-kill test (review round 13, MEDIUM — "never clear it after
// success"): a direct, isolated call to retryPendingUndoUnits, bypassing
// the higher-level RunOnce plumbing entirely. TestReconcile_
// RevertRetriesPendingUndoUnitsAtTheTop (P4) also asserts PendingUndoUnits
// ends up cleared, but that assertion is MASKED by a LATER, unconditional
// clear in reconcile.go's own revert-success path (O8(a)'s clear loop),
// which runs regardless of what retryPendingUndoUnits itself decided — a
// mutant that made retryPendingUndoUnits never clear anything still passes
// that test. This test calls the function directly so nothing downstream
// can hide the bug: one unit confirmed active must be cleared, one that
// stays inactive must remain, in the SAME call.
func TestRetryPendingUndoUnits_ClearsOnlyTheConfirmedActiveUnit(t *testing.T) {
	r, _, runner, _, statePath, _, _ := upgradeTestReconciler(t)
	okUnit := lifecycle.UnitName("m1", "ok-unit")
	stuckUnit := lifecycle.UnitName("m1", "stuck-unit")

	current := &mount.State{
		AttachedModules: []mount.Module{
			{ID: "m1", Digest: "d1", PendingUndoUnits: []string{okUnit, stuckUnit}},
		},
		LastAttachedManifestHashes: map[string]string{},
	}
	if err := mount.SaveState(statePath, current); err != nil {
		t.Fatalf("SaveState: %v", err)
	}
	runner.StubOutput = map[string][]byte{
		"systemctl is-active " + okUnit: []byte("active\n"),
		// stuckUnit stays at RecorderRunner's default ("not active").
	}

	r.retryPendingUndoUnits(context.Background(), current, "m1", []string{okUnit, stuckUnit})

	var got []string
	for _, m := range current.AttachedModules {
		if m.ID == "m1" {
			got = m.PendingUndoUnits
		}
	}
	if containsArg(got, okUnit) {
		t.Errorf("P5 REGRESSION (never clear after success): %s is confirmed active and must be cleared, got %v", okUnit, got)
	}
	if !containsArg(got, stuckUnit) {
		t.Errorf("expected %s (still inactive) to remain in the list, got %v", stuckUnit, got)
	}
}

// TestUpgradeModule_RetryOfTheSameBumpRetriesPendingUndoUnitsFirst is P5's
// own mutant-kill test (review round 13, MEDIUM — "remove the
// retryPendingUndoUnits call"): the TOP-of-upgradeModule priority retry
// (O6, review round 12 — "try it again BEFORE ANYTHING ELSE this tick")
// has no dedicated test of its own; every existing O6/P4 test exercises
// EITHER the in-attempt undo retry inside recoverFromDepartingUnitConflict
// OR reconcile.go's separate revert-branch call (P4) — neither reaches
// this call site. Retries the SAME bump digest on the next tick (not a
// re-target or a revert) and asserts old-worker is retried and cleared.
func TestUpgradeModule_RetryOfTheSameBumpRetriesPendingUndoUnitsFirst(t *testing.T) {
	r, client, runner, _, statePath, manifestRoot, _ := upgradeTestReconciler(t)

	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture(
		"d1", []string{"CAP_CHOWN"}, upgradeAppService+","+upgradeWorkerService)
	appUnit := lifecycle.UnitName("m1", "app")
	oldWorkerUnit := lifecycle.UnitName("m1", "old-worker")
	newWorkerUnit := lifecycle.UnitName("m1", "new-worker")

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1: %v", err)
	}

	// Bump to d2: new-worker never comes up, N8 fires, and old-worker's
	// undo restart fails on BOTH attempts — PendingUndoUnits=[old-worker].
	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture(
		"d2", []string{"CAP_CHOWN"}, upgradeAppService+","+upgradeNewWorkerService)
	backdateManifestCache(t, manifestRoot, "m1")
	oldWorkerStartKey := "systemctl start " + oldWorkerUnit
	runner.StubOutput = map[string][]byte{
		"systemctl is-active " + appUnit:       []byte("active\n"),
		"systemctl is-active " + oldWorkerUnit: []byte("active\n"),   // active+departing, so N8 stops it
		"systemctl is-active " + newWorkerUnit: []byte("inactive\n"), // never comes up
	}
	runner.StubErr = map[string]error{oldWorkerStartKey: errors.New("undo failed (both attempts)")}
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 2 (N8 fires, undo fails twice): %v", err)
	}
	// N8's own stop already flips old-worker to inactive on THIS runner
	// (RecorderRunner does not model state transitions on its own); make
	// that explicit for pass 3's own is-active reads below.
	runner.StubOutput["systemctl is-active "+oldWorkerUnit] = []byte("inactive\n")
	st, err := mount.LoadState(statePath)
	if err != nil {
		t.Fatalf("LoadState: %v", err)
	}
	found := false
	for _, m := range st.AttachedModules {
		if m.ID == "m1" {
			found = containsArg(m.PendingUndoUnits, oldWorkerUnit)
		}
	}
	if !found {
		t.Fatalf("precondition: expected PendingUndoUnits to contain %s after pass 2, got state: %+v", oldWorkerUnit, st.AttachedModules)
	}

	// Tick 3: SAME digest d2 still assigned — a retry of the SAME bump
	// (attempts=1 after pass 2, so M2's own immediate-retry rule applies —
	// no backoff wait needed). Whatever was blocking old-worker's restart
	// is now fixed; new-worker still never comes up, so this attempt is
	// refused again too — irrelevant to what this test checks.
	delete(runner.StubErr, oldWorkerStartKey)
	hooked := &hookRunner{Runner: runner, onRun: func(name string, args []string) {
		if name == "systemctl" && containsArg(args, "start") && containsArg(args, oldWorkerUnit) {
			runner.StubOutput["systemctl is-active "+oldWorkerUnit] = []byte("active\n")
		}
	}}
	r.cfg.MountRunner = hooked

	pass3Start := len(runner.Invocations)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 3 (same-digest retry): %v", err)
	}
	pass3 := runner.Invocations[pass3Start:]

	if !hasSystemctlOp(pass3, "start", oldWorkerUnit) {
		t.Errorf("P5 REGRESSION (retryPendingUndoUnits call removed): expected the top-of-upgradeModule priority retry to attempt %s, got: %v", oldWorkerUnit, pass3)
	}
	st, err = mount.LoadState(statePath)
	if err != nil {
		t.Fatalf("LoadState after pass 3: %v", err)
	}
	for _, m := range st.AttachedModules {
		if m.ID == "m1" && containsArg(m.PendingUndoUnits, oldWorkerUnit) {
			t.Errorf("P5 REGRESSION: %s was confirmed active but stayed in PendingUndoUnits: %v", oldWorkerUnit, m.PendingUndoUnits)
		}
	}
}

// TestReconcile_RevertClearsUnitsTouchedSoALaterUnrelatedBumpStartsFresh is
// P5's own mutant-kill test (review round 13, MEDIUM — "pin P2's sticky
// flag, since the re-target-keeps-touched mutant currently survives both
// ways"): P2 (round 13) correctly made PendingDigestUnitsTouched SURVIVE a
// re-target, but a successful REVERT — unlike a commit, which replaces the
// whole state entry with a fresh struct — mutates fields in place and had
// no line resetting this one at all. Left true forever after a revert, a
// LATER, completely unrelated bump of the SAME module ID would start its
// very first tick already reading "touched" — bypassing P3's own
// predicted-refusal check (round 13) and rendering that new episode's
// sudoers grant immediately, even though its step 2 refuses it.
func TestReconcile_RevertClearsUnitsTouchedSoALaterUnrelatedBumpStartsFresh(t *testing.T) {
	r, client, runner, _, statePath, manifestRoot, _ := upgradeTestReconciler(t)
	appUnit := lifecycle.UnitName("m1", "app")

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1 (attach d1, app only): %v", err)
	}

	// d2 touches: app force-restarts, new-worker never settles — refused.
	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture(
		"d2", []string{"CAP_CHOWN"}, upgradeAppService+","+upgradeNewWorkerService)
	backdateManifestCache(t, manifestRoot, "m1")
	runner.StubOutput = map[string][]byte{"systemctl is-active " + appUnit: []byte("active\n")}
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 2 (d2 touched, refused): %v", err)
	}
	if pd, ok := pendingDigest(t, statePath, "m1"); !ok || pd != "d2" {
		t.Fatalf("precondition: expected PendingDigest=d2 after pass 2, got %q ok=%v", pd, ok)
	}

	// Revert to d1 — succeeds cleanly.
	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture("d1", []string{"CAP_CHOWN"}, upgradeAppService)
	backdateManifestCache(t, manifestRoot, "m1")
	runner.StubOutput = map[string][]byte{"systemctl is-active " + appUnit: []byte("active\n")}
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 3 (revert): %v", err)
	}
	if pd, ok := pendingDigest(t, statePath, "m1"); ok && pd != "" {
		t.Fatalf("precondition: expected PendingDigest cleared after the revert, got %q", pd)
	}
	st, err := mount.LoadState(statePath)
	if err != nil {
		t.Fatalf("LoadState: %v", err)
	}
	for _, m := range st.AttachedModules {
		if m.ID == "m1" && m.PendingDigestUnitsTouched {
			t.Fatalf("P5 REGRESSION: expected PendingDigestUnitsTouched cleared after a successful revert, got true")
		}
	}

	// A LATER, completely UNRELATED bump: d1 -> d3, refused at step 2
	// (unapproved privileged, same deterministic shape P3's own test uses).
	// This is a brand-new episode that has touched nothing yet.
	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixturePrivilegedWithSudoer("d3", true, "d3-only-grant")
	backdateManifestCache(t, manifestRoot, "m1")

	var renderedGrantIDs []string
	origSudoers := applySudoers
	applySudoers = func(grants []etcsudoers.Grant) error {
		for _, g := range grants {
			renderedGrantIDs = append(renderedGrantIDs, g.Grant.ID)
		}
		return nil
	}
	t.Cleanup(func() { applySudoers = origSudoers })

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 4 (d3 refused at step 2, unrelated episode): %v", err)
	}
	for _, id := range renderedGrantIDs {
		if id == "d3-only-grant" {
			t.Fatalf("P5 REGRESSION (stale PendingDigestUnitsTouched leaked into a later episode): d3's own sudoers grant was rendered on its VERY FIRST tick despite being refused at step 2: %v", renderedGrantIDs)
		}
	}
}
