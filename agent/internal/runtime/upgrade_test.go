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

const upgradeAppService = `{"name":"app", "start_command":"/bin/true", "restart_policy":"always"}`
const upgradeWorkerService = `{"name":"old-worker", "start_command":"/bin/true", "restart_policy":"always"}`

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
	dropInRoot = t.TempDir()
	t.Cleanup(security.SetSystemdDropInRootForTest(dropInRoot))
	t.Setenv("POWERNODE_LIFECYCLE_UNIT_DIR", t.TempDir())

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
		if containsArg(inv.Args, appUnit) && (containsArg(inv.Args, "start") || containsArg(inv.Args, "restart")) && appStartIdx == -1 {
			appStartIdx = i
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
		t.Fatalf("pass 2: expected %s to be (re)started, invocations: %v", appUnit, pass2)
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
	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture("d2", []string{"CAP_CHOWN", "CAP_NET_BIND_SERVICE"}, upgradeAppService)
	backdateManifestCache(t, manifestRoot, "m1")

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
	}

	// Unblock — the bump should now go through normally.
	if err := os.RemoveAll(blocked); err != nil {
		t.Fatal(err)
	}
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
	r, client, runner, layout, statePath, manifestRoot, _ := upgradeTestReconciler(t)
	unit := lifecycle.UnitName("m1", "app")
	forcePivotNative(t)

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce pass 1: %v", err)
	}

	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture("d2", []string{"CAP_CHOWN"}, upgradeAppService)
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
