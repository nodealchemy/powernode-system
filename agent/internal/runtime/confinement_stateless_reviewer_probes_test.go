package runtime

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/lifecycle"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// Round Y (IMP-caef5c00d63f) reviewer probes, design section 6 — RunOnce
// driven, unlike confinement_recheck_n4_n5_test.go's and
// confinement_probe_test.go's own direct-call unit tests. These exercise
// the stateless redesign end to end: nothing here is bookkept across ticks
// (X1's persisted pending set is gone), so every tick independently
// re-derives whatever it reports from the manifest and /proc.
//
// SCOPE NOTE: this file covers probes 1/2 (multi-tick self-hosted +
// operator-restart-clears), 4 (renamed unit), 5 (detection Unknown on the
// changed-caps tick), 6 (crash mid-tick), and 8 (non-self-hosted edge
// restart failure). Probe 3 (reboot/legacy-ambient-file clearing) and probe
// 9 (recheck N5 independence) are NOT re-covered here — they are already
// exercised at the RunOnce level by TestReconcile_NewBootCompositionRewritesADivergentDropInAndW1ThenApplies
// (confinement_reattach_test.go, pre-existing W2 coverage unaffected by
// round Y) and by TestReconfirmConfinement_N5_PerModuleIndependence /
// TestReconfirmConfinement_N4Gate_* (confinement_recheck_n4_n5_test.go,
// direct-call per the design's own test-plan split) respectively. Flagged
// to team-lead as a scope reduction under time, not silently skipped.

// testExtraCapBit is a bit position GUARANTEED outside the 41 known
// capability bits (0-40, CAP_CHOWN..CAP_CHECKPOINT_RESTORE) — ORing it onto
// a real declared mask always produces a genuinely wider value, regardless
// of which capabilities happen to be in the declared list. Using an
// arbitrary literal like 0x1000 is a trap: CAP_NET_ADMIN's own bit is 12
// (0x1000), so "declared | 0x1000" is a silent no-op whenever CAP_NET_ADMIN
// is already declared.
const testExtraCapBit = uint64(1) << 45

// staleProbeStub merges a unit's is-active AND ShowProperties stub outputs —
// both systemctl calls a single reconcile tick needs (the ordinary
// attach/reattach path's is-active restart-decision, and the stale probe's
// own ActiveState/MainPID/NeedDaemonReload read) into one map.
func staleProbeStub(unit string, activeState string, mainPID int, needReload bool) map[string][]byte {
	reload := "no"
	if needReload {
		reload = "yes"
	}
	activeLine := "inactive\n"
	if activeState == "active" {
		activeLine = "active\n"
	}
	return map[string][]byte{
		"systemctl is-active " + unit: []byte(activeLine),
		showPropsKey(unit):            []byte("ActiveState=" + activeState + "\nMainPID=" + itoaTest(mainPID) + "\nNeedDaemonReload=" + reload + "\n"),
	}
}

func itoaTest(n int) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		buf[i] = '-'
	}
	return string(buf[i:])
}

// TestConfinementProbe_SelfHostedMultiTickThenOperatorRestartClears is
// reviewer probes 1+2. Tick 1 attaches cleanly and latches self-hosted.
// Tick 2 is a manifest-only capabilities-list edit (m1 stays at digest
// abc123): the reattach loop writes the new drop-in, reloads, and withholds
// the restart (rule 1) — the ONLY daemon-reload in the whole sequence.
// Ticks 3-5 change nothing in the manifest at all (m1 goes fully inert in
// the reattach loop) — the stale probe alone keeps finding the SAME wider
// fixture and keeps reporting it, with NO systemctl mutation whatsoever
// (proving N1 is closed: nothing forces a reattach/reload churn on a
// self-hosted node that never actually converges). The final tick rewrites
// the /proc fixture to the declared mask (an operator having restarted the
// unit by hand) and the report/heartbeat entry vanishes on the very next
// tick, with still no additional systemctl mutation from THIS agent.
func TestConfinementProbe_SelfHostedMultiTickThenOperatorRestartClears(t *testing.T) {
	r, client, runner, statePath, manifestRoot, _ := newConfinementReattachReconciler(t)
	unit := lifecycle.UnitName("m1", "app")
	var onErrors []string
	r.cfg.OnError = func(stage string, err error) { onErrors = append(onErrors, stage+": "+err.Error()) }

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 1: %v", err)
	}
	r.selfHostLatched = true

	// Tick 2: capabilities-list edit, same digest. The fixture reports the
	// OLD (pre-edit), now-wider-than-declared capability set, as if the
	// unit is still running under whatever it started with.
	if err := os.RemoveAll(filepath.Join(manifestRoot, "m1")); err != nil {
		t.Fatal(err)
	}
	client.responses["/api/v1/system/node_api/modules/m1"] = manifestFixtureWithCaps("abc123", []string{"CAP_CHOWN", "CAP_NET_ADMIN"})
	declared := capMaskFor(t, []string{"CAP_CHOWN", "CAP_NET_ADMIN"})
	wider := declared | testExtraCapBit
	root := withProcRoot(t)
	fakeProcPID(t, root, 4242, wider, 0x0)
	runner.StubOutput = staleProbeStub(unit, "active", 4242, false)

	pre2 := len(runner.Invocations)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 2: %v", err)
	}
	tick2 := runner.Invocations[pre2:]
	if hasSystemctlOp(tick2, "restart", unit) {
		t.Errorf("invariant 1 REGRESSION: self-hosted must never restart on tick 2, invocations=%v", tick2)
	}
	if n := countSystemctlOp(tick2, "daemon-reload"); n != 1 {
		t.Errorf("expected exactly ONE daemon-reload on tick 2, got %d (invocations=%v)", n, tick2)
	}
	if _, stamped := mustLoadState(t, statePath).LastAttachedManifestHashes["m1"]; !stamped {
		t.Error("expected m1 to stay stamped after tick 2 despite the withheld restart")
	}
	if !convergenceFailuresContain(onErrors, "reconciler:confinement_stale") || !convergenceFailuresContain(onErrors, unit) {
		t.Errorf("expected a confinement_stale report on tick 2, got %v", onErrors)
	}
	if got := r.ConfinementStaleUnits(); len(got) != 1 || got[0] != unit {
		t.Errorf("ConfinementStaleUnits() after tick 2 = %v, want [%s]", got, unit)
	}

	// Ticks 3-5: NOTHING changes — same manifest, same (still wider) /proc
	// fixture. N1's own failure mode was a full reattach+reload EVERY tick
	// here; assert none of that churn happens.
	for i := 3; i <= 5; i++ {
		onErrors = nil
		preN := len(runner.Invocations)
		if err := r.RunOnce(context.Background()); err != nil {
			t.Fatalf("RunOnce tick %d: %v", i, err)
		}
		tickN := runner.Invocations[preN:]
		if hasSystemctlOp(tickN, "restart", unit) {
			t.Errorf("tick %d: invariant 1 REGRESSION: unexpected restart, invocations=%v", i, tickN)
		}
		if countSystemctlOp(tickN, "daemon-reload") != 0 {
			t.Errorf("N1 REGRESSION: tick %d issued an extra daemon-reload — self-hosted node re-forcing a reattach it can never resolve, invocations=%v", i, tickN)
		}
		if len(r.ConvergenceFailures()) != 0 {
			t.Errorf("tick %d: expected ConvergenceFailures() empty (withheld restart is not durably unconverged), got %v", i, r.ConvergenceFailures())
		}
		if got := r.ConfinementStaleUnits(); len(got) != 1 || got[0] != unit {
			t.Errorf("tick %d: ConfinementStaleUnits() = %v, want [%s] every tick, not just once", i, got, unit)
		}
		if !convergenceFailuresContain(onErrors, "reconciler:confinement_stale") {
			t.Errorf("tick %d: expected a FRESH confinement_stale report, got %v", i, onErrors)
		}
	}

	// Probe 2: operator restarts the unit by hand — /proc now matches
	// declared exactly. The very next tick must clear, with no systemctl
	// mutation of its own (the agent did not cause this).
	fakeProcPID(t, root, 4242, declared, 0x0)
	preClear := len(runner.Invocations)
	onErrors = nil
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce clearing tick: %v", err)
	}
	clearTick := runner.Invocations[preClear:]
	if hasSystemctlOp(clearTick, "restart", unit) || countSystemctlOp(clearTick, "daemon-reload") != 0 {
		t.Errorf("expected NO systemctl mutation on the clearing tick, invocations=%v", clearTick)
	}
	if got := r.ConfinementStaleUnits(); len(got) != 0 {
		t.Errorf("expected ConfinementStaleUnits() empty after the operator's own restart, got %v", got)
	}
	if convergenceFailuresContain(onErrors, "reconciler:confinement_stale") {
		t.Errorf("expected no confinement_stale report once the running unit matches declared, got %v", onErrors)
	}
}

// TestConfinementProbe_RenamedUnitNeverProbesTheOldName is reviewer probe 4:
// a manifest edit that renames a service means mf.UnitNames() drops the old
// unit entirely — the stale probe iterates mf.UnitNames(), so the old name
// is never even looked up, regardless of what is still running under it.
func TestConfinementProbe_RenamedUnitNeverProbesTheOldName(t *testing.T) {
	r, client, runner, _, manifestRoot, _ := newConfinementReattachReconciler(t)
	oldUnit := lifecycle.UnitName("m1", "app")
	newUnit := lifecycle.UnitName("m1", "web")

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 1: %v", err)
	}

	if err := os.RemoveAll(filepath.Join(manifestRoot, "m1")); err != nil {
		t.Fatal(err)
	}
	client.responses["/api/v1/system/node_api/modules/m1"] = `{
		"success": true,
		"data": {
			"id":"m1", "name":"app-mod",
			"priority":100, "effective_priority":100,
			"digest":"abc123",
			"config": {"security": {"capabilities": ["CAP_CHOWN"], "user_namespace": false}},
			"services": [{"name":"web", "start_command":"/bin/true", "restart_policy":"always"}]
		}
	}`
	runner.StubOutput = map[string][]byte{
		"systemctl is-active " + oldUnit: []byte("inactive\n"), // renamed away: gone
		showPropsKey(oldUnit):            []byte("ActiveState=inactive\nMainPID=0\nNeedDaemonReload=no\n"),
		"systemctl is-active " + newUnit: []byte("inactive\n"),
		showPropsKey(newUnit):            []byte("ActiveState=active\nMainPID=4242\nNeedDaemonReload=no\n"),
	}
	fakeProcPID(t, withProcRoot(t), 4242, capMaskFor(t, []string{"CAP_CHOWN"}), 0x0)

	pre := len(runner.Invocations)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 2 (rename): %v", err)
	}
	tick2 := runner.Invocations[pre:]
	if hasSystemctlOp(tick2, "restart", oldUnit) {
		t.Errorf("expected no restart of the renamed-away old unit, invocations=%v", tick2)
	}
	if !hasSystemctlOp(tick2, "start", newUnit) {
		t.Errorf("expected the new unit to be started normally, invocations=%v", tick2)
	}
	for _, u := range r.ConfinementStaleUnits() {
		if u == oldUnit {
			t.Errorf("REGRESSION: the stale probe named the OLD (renamed-away) unit: %v", r.ConfinementStaleUnits())
		}
	}
}

// TestConfinementProbe_DetectionUnknownWithholdsThenRestartsOnceResolved is
// reviewer probe 5: a resolver hiccup on the changed-caps tick must
// withhold BOTH the edge restart (R1) and any level restart (R2) — Unknown
// is never treated as "safe to restart" — and once detection resolves to a
// definite remote node, R2 restarts exactly once for a fixture still wider.
func TestConfinementProbe_DetectionUnknownWithholdsThenRestartsOnceResolved(t *testing.T) {
	r, client, runner, _, manifestRoot, _ := newConfinementReattachReconciler(t)
	r.cfg.PlatformURL = "https://ops-hub.example.test"
	unit := lifecycle.UnitName("m1", "app")

	withLookups(t, map[string][]string{"ops-hub.example.test": {"192.0.2.22"}}, []string{"192.0.2.99"}, nil)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 1: %v", err)
	}

	// Tick 2: caps change AND the resolver fails this exact tick.
	if err := os.RemoveAll(filepath.Join(manifestRoot, "m1")); err != nil {
		t.Fatal(err)
	}
	client.responses["/api/v1/system/node_api/modules/m1"] = manifestFixtureWithCaps("abc123", []string{"CAP_CHOWN", "CAP_NET_ADMIN"})
	declared := capMaskFor(t, []string{"CAP_CHOWN", "CAP_NET_ADMIN"})
	wider := declared | testExtraCapBit
	root := withProcRoot(t)
	fakeProcPID(t, root, 4242, wider, 0x0)
	runner.StubOutput = staleProbeStub(unit, "active", 4242, false)
	withLookups(t, nil, nil, errors.New("no such host"))

	pre2 := len(runner.Invocations)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 2 (unknown): %v", err)
	}
	if hasSystemctlOp(runner.Invocations[pre2:], "restart", unit) {
		t.Errorf("N2 REGRESSION: Unknown detection must withhold BOTH R1 and R2, invocations=%v", runner.Invocations[pre2:])
	}

	// Tick 3: resolver succeeds, resolves to a DEFINITE remote node.
	// Nothing about the manifest changes this tick — R1 has nothing to do;
	// R2 alone restarts the still-wider unit exactly once.
	withLookups(t, map[string][]string{"ops-hub.example.test": {"192.0.2.22"}}, []string{"192.0.2.99"}, nil)
	pre3 := len(runner.Invocations)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 3 (resolved): %v", err)
	}
	tick3 := runner.Invocations[pre3:]
	if n := countSystemctlOp(tick3, "restart"); n != 1 {
		t.Errorf("expected exactly ONE R2 restart once detection resolves, got %d (invocations=%v)", n, tick3)
	}
}

// TestConfinementProbe_DetectionUnknownNarrowerNeverRestarts is the variant
// half of probe 5: a NARROWER (not wider) fixture must never restart, on
// Unknown or once resolved — narrower is report-only regardless of node
// type.
func TestConfinementProbe_DetectionUnknownNarrowerNeverRestarts(t *testing.T) {
	r, client, runner, _, manifestRoot, _ := newConfinementReattachReconciler(t)
	r.cfg.PlatformURL = "https://ops-hub.example.test"
	unit := lifecycle.UnitName("m1", "app")

	withLookups(t, map[string][]string{"ops-hub.example.test": {"192.0.2.22"}}, []string{"192.0.2.99"}, nil)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 1: %v", err)
	}

	if err := os.RemoveAll(filepath.Join(manifestRoot, "m1")); err != nil {
		t.Fatal(err)
	}
	client.responses["/api/v1/system/node_api/modules/m1"] = manifestFixtureWithCaps("abc123", []string{"CAP_CHOWN", "CAP_NET_ADMIN"})
	declared := capMaskFor(t, []string{"CAP_CHOWN", "CAP_NET_ADMIN"})
	narrower := declared & 0x1 // strict subset
	root := withProcRoot(t)
	fakeProcPID(t, root, 4242, narrower, 0x0)
	runner.StubOutput = staleProbeStub(unit, "active", 4242, false)
	withLookups(t, nil, nil, errors.New("no such host"))
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 2 (unknown, narrower): %v", err)
	}

	withLookups(t, map[string][]string{"ops-hub.example.test": {"192.0.2.22"}}, []string{"192.0.2.99"}, nil)
	pre3 := len(runner.Invocations)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 3 (resolved, narrower): %v", err)
	}
	if hasSystemctlOp(runner.Invocations[pre3:], "restart", unit) {
		t.Errorf("expected a narrower-than-declared fixture to NEVER restart, invocations=%v", runner.Invocations[pre3:])
	}
}

// TestConfinementProbe_CrashMidTickSelfHealsViaTheStaleProbe is reviewer
// probe 6: a drop-in write that reached disk but never reached a
// reload/restart (an agent crash between the two — N3's own crash window)
// leaves writeIfChanged reporting changed=false on the NEXT tick (bytes
// already match), so R1 stays silent — but the stale probe finds the
// running process still holding the OLD, now-wider-than-declared
// capabilities independent of what changed this tick, and R2 self-heals it
// (or reports it, self-hosted) without needing anything carried over from
// the crashed tick.
func TestConfinementProbe_CrashMidTickSelfHealsViaTheStaleProbe(t *testing.T) {
	r, client, runner, _, manifestRoot, _ := newConfinementReattachReconciler(t)
	unit := lifecycle.UnitName("m1", "app")

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 1: %v", err)
	}

	// Simulate the crash: the NEW manifest's own drop-in bytes are written
	// directly (bypassing the ordinary attach/reattach loop entirely, as if
	// an earlier process wrote them and crashed before reaching
	// attachModuleServices), then the client is pointed at the SAME new
	// manifest so this tick's own attachModule call sees byte-identical
	// bytes (changed=false).
	if err := os.RemoveAll(filepath.Join(manifestRoot, "m1")); err != nil {
		t.Fatal(err)
	}
	client.responses["/api/v1/system/node_api/modules/m1"] = manifestFixtureWithCaps("abc123", []string{"CAP_CHOWN", "CAP_NET_ADMIN"})
	mf := parseManifestEnvelope(t, manifestFixtureWithCaps("abc123", []string{"CAP_CHOWN", "CAP_NET_ADMIN"}))
	mod := mount.Module{ID: "m1", Digest: "abc123", Priority: 100}
	if _, _, err := r.applyModuleSecurityDropInsOnly(mod, mf); err != nil {
		t.Fatalf("precondition (simulated crash write): %v", err)
	}

	declared := capMaskFor(t, []string{"CAP_CHOWN", "CAP_NET_ADMIN"})
	wider := declared | testExtraCapBit // the process is still running under the OLD, wider grant
	root := withProcRoot(t)
	fakeProcPID(t, root, 4242, wider, 0x0)
	runner.StubOutput = staleProbeStub(unit, "active", 4242, false)

	pre := len(runner.Invocations)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce (post-crash tick): %v", err)
	}
	tick := runner.Invocations[pre:]
	if countSystemctlOp(tick, "daemon-reload") != 0 {
		t.Errorf("expected R1 silent (bytes already matched on disk — no edge to fire), got a daemon-reload: %v", tick)
	}
	if n := countSystemctlOp(tick, "restart"); n != 1 {
		t.Errorf("expected R2 to self-heal via the stale probe exactly once, got %d restarts (invocations=%v)", n, tick)
	}

	// Second RunOnce within the 15-minute backoff, fixture still wider (the
	// restart target in this test double never actually changes /proc) —
	// must NOT restart again.
	preSecond := len(runner.Invocations)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce (backoff tick): %v", err)
	}
	if hasSystemctlOp(runner.Invocations[preSecond:], "restart", unit) {
		t.Errorf("R2 REGRESSION: expected the backoff to suppress a second restart, invocations=%v", runner.Invocations[preSecond:])
	}
}

// TestConfinementProbe_NonSelfHostedEdgeRestartFailureIsTransient is
// reviewer probe 8's failure half: a non-self-hosted node's OWN R1 restart
// attempt that fails must surface via ConvergenceFailures() for that tick
// only — never as durable bookkeeping (X1's own now-deleted persisted
// pending set would have kept retrying the SAME stale reason forever).
func TestConfinementProbe_NonSelfHostedEdgeRestartFailureIsTransient(t *testing.T) {
	r, client, runner, _, manifestRoot, _ := newConfinementReattachReconciler(t)
	unit := lifecycle.UnitName("m1", "app")

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 1: %v", err)
	}

	if err := os.RemoveAll(filepath.Join(manifestRoot, "m1")); err != nil {
		t.Fatal(err)
	}
	client.responses["/api/v1/system/node_api/modules/m1"] = manifestFixtureWithCaps("abc123", []string{"CAP_CHOWN", "CAP_NET_ADMIN"})
	runner.StubOutput = map[string][]byte{"systemctl is-active " + unit: []byte("active\n")}
	runner.StubErr = map[string]error{"systemctl restart " + unit: errors.New("restart failed (simulated)")}

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 2 (restart fails): %v", err)
	}
	if !convergenceFailuresContain(r.ConvergenceFailures(), "reconciler:confinement_restart_failed") {
		t.Errorf("expected confinement_restart_failed in ConvergenceFailures() on the failing tick, got %v", r.ConvergenceFailures())
	}

	// Tick 3: the unit now reads inactive (as a failed restart plausibly
	// leaves it) and nothing else changes — the failure must not persist.
	runner.StubErr = nil
	runner.StubOutput = map[string][]byte{
		"systemctl is-active " + unit: []byte("inactive\n"),
		showPropsKey(unit):            []byte("ActiveState=inactive\nMainPID=0\nNeedDaemonReload=no\n"),
	}
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("RunOnce tick 3: %v", err)
	}
	if convergenceFailuresContain(r.ConvergenceFailures(), "reconciler:confinement_restart_failed") {
		t.Errorf("REGRESSION: the tick-2 restart failure must not persist into tick 3, got %v", r.ConvergenceFailures())
	}
}

func countSystemctlOp(invocations []mount.Invocation, op string) int {
	n := 0
	for _, inv := range invocations {
		if inv.Name == "systemctl" && inv.Op == "Run" && len(inv.Args) > 0 && inv.Args[0] == op {
			n++
		}
	}
	return n
}

func mustLoadState(t *testing.T, statePath string) *mount.State {
	t.Helper()
	st, err := mount.LoadState(statePath)
	if err != nil {
		t.Fatalf("LoadState: %v", err)
	}
	return st
}
