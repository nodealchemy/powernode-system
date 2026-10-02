package runtime

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/etcsudoers"
	"github.com/nodealchemy/powernode-system/agent/internal/lifecycle"
	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
)

// IMP-a6d61b01490d. A known-degraded unit and a refused sudoers grant used to
// reach only OnError (stderr / the node journal), which the operator cannot
// read, so the platform could not show either. They now ride the heartbeat as
// ONE generic "agent condition" list. The three properties that make it usable:
//   - a standing condition is reported with a STABLE first_seen on every tick;
//   - a cleared condition is reported as cleared (an empty, measured list),
//     not by the key vanishing;
//   - an agent that has not measured yet (or is too old) OMITS the key, so the
//     server can tell "no conditions" from "cannot report".

func TestAgentConditions_KnownDegradedUnit_StandingThenCleared(t *testing.T) {
	credentialBody := loadModuleServiceUnitBody(t, "claude-tmux", "credential")
	credentialService := unitBodyServiceJSON(t, "credential", credentialBody)

	r, client, runner, _, statePath, manifestRoot, _ := upgradeTestReconciler(t)
	r.cfg.OnError = func(string, error) {}
	appUnit := lifecycle.UnitName("m1", "app")
	credentialUnit := lifecycle.UnitName("m1", "credential")
	resultKey := "systemctl show " + credentialUnit + " --property=Result --value"
	appActiveKey := "systemctl is-active " + appUnit

	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture(
		"d1", []string{"CAP_CHOWN"}, upgradeAppService+","+credentialService)
	runner.StubOutput = map[string][]byte{
		resultKey:    []byte("exit-code\n"),
		appActiveKey: []byte("active\n"),
	}
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("pass 1: %v", err)
	}
	client.responses["/api/v1/system/node_api/modules/m1"] = upgradeModuleFixture(
		"d2", []string{"CAP_CHOWN"}, upgradeAppService+","+credentialService)
	backdateManifestCache(t, manifestRoot, "m1")
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("pass 2 (exempted commit): %v", err)
	}
	if degraded := knownDegradedUnits(t, statePath, "m1"); len(degraded) != 1 {
		t.Fatalf("precondition: expected one known-degraded unit, got %v", degraded)
	}

	// Steady-state tick: the condition is standing.
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("pass 3: %v", err)
	}
	got, measured := r.AgentConditions()
	if !measured || len(got) != 1 {
		t.Fatalf("AgentConditions = %+v measured=%v, want exactly one known_degraded_unit", got, measured)
	}
	c := got[0]
	if c.Kind != ConditionKnownDegradedUnit || c.Subject != credentialUnit || c.FirstSeen == "" {
		t.Fatalf("condition = %+v, want kind=%s subject=%s and a first_seen", c, ConditionKnownDegradedUnit, credentialUnit)
	}
	if !strings.Contains(c.Detail, "m1") || !strings.Contains(c.Detail, "exit-code") {
		t.Errorf("detail should name the module and the Result, got %q", c.Detail)
	}

	// Another tick: same condition, SAME first_seen (it is not re-minted).
	first := c.FirstSeen
	time.Sleep(1100 * time.Millisecond)
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("pass 4: %v", err)
	}
	got, _ = r.AgentConditions()
	if len(got) != 1 || got[0].FirstSeen != first {
		t.Fatalf("first_seen must be stable across ticks: was %q, now %+v", first, got)
	}

	// Recovery: reported as CLEARED, i.e. measured and empty.
	runner.StubOutput[resultKey] = []byte("success\n")
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("pass 5 (recovery): %v", err)
	}
	got, measured = r.AgentConditions()
	if !measured || len(got) != 0 {
		t.Fatalf("after recovery want measured=true and no conditions, got %+v measured=%v", got, measured)
	}
}

func TestAgentConditions_SudoersRefusal_ReportedAndCleared(t *testing.T) {
	r := &Reconciler{nowUnix: func() int64 { return 1000 }}
	r.cfg.OnError = func(string, error) {}

	origSudoers := applySudoers
	t.Cleanup(func() { applySudoers = origSudoers })
	refusal := &etcsudoers.RefusedGrantError{ModuleName: "mod-a", GrantID: "bad name", Reason: "illegal drop-in name"}
	applySudoers = func([]etcsudoers.Grant) error { return refusal }

	if err := r.applyIdentityAndSudoers([]*manifest.Manifest{}, "reconciler:"); err != nil {
		t.Fatalf("a refusal alone must not be returned (it would stall other modules' upgrades): %v", err)
	}
	r.publishAgentConditions()

	got, measured := r.AgentConditions()
	if !measured || len(got) != 1 {
		t.Fatalf("AgentConditions = %+v measured=%v, want one sudoers_refused", got, measured)
	}
	if got[0].Kind != ConditionSudoersRefused || got[0].Subject != "mod-a/bad name" || !strings.Contains(got[0].Detail, "illegal drop-in name") {
		t.Fatalf("condition = %+v", got[0])
	}

	// The next render has no refusal: cleared.
	applySudoers = func([]etcsudoers.Grant) error { return nil }
	if err := r.applyIdentityAndSudoers([]*manifest.Manifest{}, "reconciler:"); err != nil {
		t.Fatal(err)
	}
	r.publishAgentConditions()
	got, measured = r.AgentConditions()
	if !measured || len(got) != 0 {
		t.Fatalf("after a clean render want measured and empty, got %+v measured=%v", got, measured)
	}
}

func TestAgentConditions_NotMeasuredUntilFirstPublish(t *testing.T) {
	r := &Reconciler{}
	if got, measured := r.AgentConditions(); measured || got != nil {
		t.Fatalf("a reconciler that has not published must be UNMEASURED, got %+v measured=%v", got, measured)
	}
}

// The wire: an unmeasured agent OMITS agent_conditions; a measured one with
// nothing wrong sends an explicit empty list; a standing condition is listed.
func TestBuildHeartbeat_AgentConditionsWire(t *testing.T) {
	r := &Reconciler{nowUnix: func() int64 { return 500 }}
	svc := &Service{
		cfg:        Config{AgentVersion: "test", StatePath: t.TempDir() + "/state.json", OnError: func(string, error) {}},
		reconciler: r,
	}

	raw, _ := json.Marshal(svc.buildHeartbeat("boot-1", nil))
	if strings.Contains(string(raw), "agent_conditions") {
		t.Fatalf("an unmeasured agent must omit agent_conditions (absence = unreported), got %s", raw)
	}

	r.publishAgentConditions()
	raw, _ = json.Marshal(svc.buildHeartbeat("boot-1", nil))
	if !strings.Contains(string(raw), `"agent_conditions":[]`) {
		t.Fatalf("a measured, clean agent must send an explicit empty list, got %s", raw)
	}

	r.recordAgentCondition(ConditionKnownDegradedUnit, "powernode-m1-credential.service", "module m1: Result=\"exit-code\"")
	r.publishAgentConditions()
	raw, _ = json.Marshal(svc.buildHeartbeat("boot-1", nil))
	want := `"agent_conditions":[{"kind":"known_degraded_unit","subject":"powernode-m1-credential.service","detail":"module m1: Result=\"exit-code\"","first_seen":`
	if !strings.Contains(string(raw), want) {
		t.Fatalf("wire shape drifted: %s", raw)
	}
}

func TestCollectRefusals_JoinedAndMixed(t *testing.T) {
	a := &etcsudoers.RefusedGrantError{ModuleName: "m1", GrantID: "g1", Reason: "r1"}
	b := &etcsudoers.RefusedGrantError{ModuleName: "m2", GrantID: "g2", Reason: "r2"}
	c := &etcsudoers.RefusedGrantError{ModuleName: "m3", GrantID: "g3", Reason: "r3"}

	got := collectRefusals(errors.Join(a, errors.Join(b, c)))
	if len(got) != 3 || got[0] != a || got[1] != b || got[2] != c {
		t.Fatalf("a nested join must yield every refusal in order, got %+v", got)
	}
	if got := collectRefusals(a); len(got) != 1 || got[0] != a {
		t.Fatalf("a lone refusal must be collected, got %+v", got)
	}
	if got := collectRefusals(nil); len(got) != 0 {
		t.Fatalf("nil must collect nothing, got %+v", got)
	}

	// A write failure in the tree is not a refusals-only verdict: the previous
	// verdict must stand rather than be replaced or cleared.
	r := &Reconciler{nowUnix: func() int64 { return 1 }}
	r.noteSudoersVerdict(a)
	r.noteSudoersVerdict(errors.Join(b, errors.New("write failed")))
	if len(r.sudoersConds) != 1 || r.sudoersConds[0].Subject != "m1/g1" {
		t.Fatalf("a mixed refusal+write-error must leave the previous verdict, got %+v", r.sudoersConds)
	}
}

func TestAgentConditions_ClearThenReturnRestartsFirstSeen(t *testing.T) {
	now := int64(1000)
	r := &Reconciler{nowUnix: func() int64 { return now }}

	r.recordAgentCondition(ConditionKnownDegradedUnit, "u.service", "d")
	r.publishAgentConditions()
	first, _ := r.AgentConditions()

	now = 2000
	r.publishAgentConditions() // cleared
	if got, measured := r.AgentConditions(); !measured || len(got) != 0 {
		t.Fatalf("want cleared, got %+v", got)
	}

	now = 3000
	r.recordAgentCondition(ConditionKnownDegradedUnit, "u.service", "d")
	r.publishAgentConditions()
	again, _ := r.AgentConditions()
	if len(again) != 1 || again[0].FirstSeen == first[0].FirstSeen {
		t.Fatalf("a condition that clears and returns starts a new run: first=%v again=%v", first, again)
	}
}
