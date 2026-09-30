package runtime

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/lifecycle"
	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// IMP-9f4e162d9ed1 — the platform's explicit, per-module statement that a
// module was unassigned (data.confirmed_unassigned on the assigned-modules
// response). An empty or config-only list still fails closed (IMP-1023e79cc82d);
// only a module the platform NAMES may be detached on such a list, and only
// because a server action recorded that unassignment, never because a list was
// empty.

const confirmedM2Body = `{"success": true,"data": {"id":"m2","name":"other","priority":100,"effective_priority":100,"digest":"e1",
	"config": {"security": {"capabilities": ["CAP_CHOWN"], "user_namespace": false}},
	"users": [{"name":"pguser","uid":6001,"primary_gid":6001,"primary_group":"pguser","shell":"/bin/false","home":"/home/pguser"}],
	"groups": [{"name":"pguser","gid":6001}], "services": []}}`

const listM1M2 = `{"success": true,"data": {"modules": [
	{"id":"m1", "name":"app-mod", "priority":100, "effective_priority":100, "has_data_file":true},
	{"id":"m2", "name":"other", "priority":100, "effective_priority":100, "has_data_file":true}]}}`

func emptyListConfirming(ids ...string) string {
	entries := make([]string, 0, len(ids))
	for _, id := range ids {
		entries = append(entries, `{"module_id":"`+id+`","reason":"assignment_destroyed"}`)
	}
	return `{"success": true, "data": {"modules": [], "count": 0, "confirmed_unassigned": [` + strings.Join(entries, ",") + `]}}`
}

func attachM1(t *testing.T) (*Reconciler, *stubModulesClient, *mount.RecorderRunner, string, *[]string) {
	t.Helper()
	r, client, runner, _, statePath, _, _ := upgradeTestReconciler(t)
	signals := &[]string{}
	r.cfg.OnError = func(stage string, err error) { *signals = append(*signals, stage) }
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("pass 1 (attach m1): %v", err)
	}
	if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "d1" {
		t.Fatalf("precondition: m1 must be attached at d1, got %q ok=%v", digest, ok)
	}
	return r, client, runner, statePath, signals
}

// The platform names m1 as unassigned and its list is empty: m1 goes, exactly
// as it did before the empty-list guard existed, and nothing is deferred.
func TestRunOnce_EmptyListDetachesAModuleThePlatformConfirmedUnassigned(t *testing.T) {
	r, client, runner, statePath, signals := attachM1(t)
	appUnit := lifecycle.UnitName("m1", "app")
	client.responses["/api/v1/system/node_api/modules"] = emptyListConfirming("m1")
	pre := len(runner.Invocations)
	*signals = nil

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("pass 2 (empty list, m1 confirmed unassigned): %v", err)
	}

	if _, ok := attachedDigest(t, statePath, "m1"); ok {
		t.Error("a module the platform confirmed unassigned must be detached on an empty list")
	}
	if !hasSystemctlOp(runner.Invocations[pre:], "stop", appUnit) {
		t.Errorf("m1's unit must be stopped, invocations: %v", runner.Invocations[pre:])
	}
	if strings.Contains(strings.Join(*signals, " "), "reconciler:detach_deferred_empty_assignment") {
		t.Errorf("a fully confirmed empty list defers nothing, got %v", *signals)
	}
	if got := r.AssignmentDeferral(); len(got) != 0 {
		t.Errorf("a fully confirmed empty list is not a health condition, got %+v", got)
	}
}

// A confirmation naming some OTHER module confirms nothing about m1: the empty
// list stays untrusted for it.
func TestRunOnce_EmptyListConfirmingAnotherModuleStillRetainsM1(t *testing.T) {
	r, client, runner, statePath, signals := attachM1(t)
	appUnit := lifecycle.UnitName("m1", "app")
	client.responses["/api/v1/system/node_api/modules"] = emptyListConfirming("some-other-module")
	pre := len(runner.Invocations)
	*signals = nil

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("pass 2: %v", err)
	}

	if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "d1" {
		t.Errorf("a confirmation for another module must not detach m1: digest=%q ok=%v", digest, ok)
	}
	if hasSystemctlOp(runner.Invocations[pre:], "stop", appUnit) {
		t.Errorf("m1 must not be stopped: %v", runner.Invocations[pre:])
	}
	if !strings.Contains(strings.Join(*signals, " "), "reconciler:detach_deferred_empty_assignment") {
		t.Errorf("the unconfirmed retention must stay surfaced, got %v", *signals)
	}
}

// Two modules attached, one confirmed: only the confirmed one goes, the other is
// deferred and named as the health condition.
func TestRunOnce_EmptyListDetachesOnlyTheConfirmedModule(t *testing.T) {
	r, client, _, statePath, _ := attachM1(t)
	client.responses["/api/v1/system/node_api/modules"] = listM1M2
	client.responses["/api/v1/system/node_api/modules/m2"] = confirmedM2Body
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("pass 2 (attach m2): %v", err)
	}
	if _, ok := attachedDigest(t, statePath, "m2"); !ok {
		t.Fatal("precondition: m2 must be attached")
	}

	client.responses["/api/v1/system/node_api/modules"] = emptyListConfirming("m1")
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("pass 3 (empty list, only m1 confirmed): %v", err)
	}

	if _, ok := attachedDigest(t, statePath, "m1"); ok {
		t.Error("the confirmed module m1 must be detached")
	}
	if digest, ok := attachedDigest(t, statePath, "m2"); !ok || digest != "e1" {
		t.Errorf("the unconfirmed module m2 must be retained: digest=%q ok=%v", digest, ok)
	}
	got := r.AssignmentDeferral()
	if len(got) != 1 || got[0].Reason != DeferralEmptyAssignment || strings.Join(got[0].ModuleIDs, ",") != "m2" {
		t.Errorf("the health condition must name exactly the retained module m2, got %+v", got)
	}
}

// A confirmation that contradicts the list (the same module is still assigned,
// here as a config-only entry) is not a confirmation: contradictory input fails
// closed.
func TestRunOnce_ConfirmationContradictedByTheListIsIgnored(t *testing.T) {
	r, client, runner, statePath, _ := attachM1(t)
	appUnit := lifecycle.UnitName("m1", "app")
	client.responses["/api/v1/system/node_api/modules"] = `{"success": true, "data": {"modules": [
		{"id":"m1", "name":"app-mod", "priority":100, "effective_priority":100, "has_data_file":false}],
		"confirmed_unassigned": [{"module_id":"m1"}]}}`
	pre := len(runner.Invocations)

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("pass 2: %v", err)
	}

	if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "d1" {
		t.Errorf("a module both assigned and confirmed unassigned must be retained: digest=%q ok=%v", digest, ok)
	}
	if hasSystemctlOp(runner.Invocations[pre:], "stop", appUnit) {
		t.Errorf("m1 must not be stopped: %v", runner.Invocations[pre:])
	}
}

// A degraded answer carries no confirmation, so nothing changes from
// IMP-1023e79cc82d: the empty list keeps every attached module.
func TestRunOnce_EmptyListWithoutConfirmationStillFailsClosed(t *testing.T) {
	r, client, _, statePath, signals := attachM1(t)
	client.responses["/api/v1/system/node_api/modules"] = `{"success": true, "data": {"modules": [], "count": 0, "confirmed_unassigned": []}}`
	*signals = nil

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("pass 2: %v", err)
	}

	if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "d1" {
		t.Errorf("an unconfirmed empty list must retain m1: digest=%q ok=%v", digest, ok)
	}
	got := r.AssignmentDeferral()
	if len(got) != 1 || got[0].Reason != DeferralEmptyAssignment || strings.Join(got[0].ModuleIDs, ",") != "m1" {
		t.Errorf("the deferral must be published for the health lane, got %+v", got)
	}
}

// The deferral is a live condition: a trusted tick clears it.
func TestRunOnce_DeferralClearsOnATrustedTick(t *testing.T) {
	r, client, _, _, _ := attachM1(t)
	client.responses["/api/v1/system/node_api/modules"] = `{"success": true, "data": {"modules": [], "count": 0}}`
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("pass 2 (untrusted empty): %v", err)
	}
	if len(r.AssignmentDeferral()) == 0 {
		t.Fatal("precondition: the untrusted empty tick must publish a deferral")
	}

	client.responses["/api/v1/system/node_api/modules"] = upgradeModulesListFixture
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("pass 3 (trusted): %v", err)
	}
	if got := r.AssignmentDeferral(); len(got) != 0 {
		t.Errorf("a trusted tick must clear the deferral, got %+v", got)
	}
}

// PersistedSeconds counts from the FIRST tick of an unbroken run of the same
// condition, not from the latest, so a node stuck for an hour reports an hour.
func TestRunOnce_DeferralPersistedSecondsSpansTheUnbrokenRun(t *testing.T) {
	r, client, _, _, _ := attachM1(t)
	now := int64(1_000_000)
	r.nowUnix = func() int64 { return now }
	client.responses["/api/v1/system/node_api/modules"] = `{"success": true, "data": {"modules": [], "count": 0}}`

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("pass 2: %v", err)
	}
	if got := r.AssignmentDeferral(); len(got) != 1 || got[0].PersistedSeconds != 0 {
		t.Fatalf("first tick of the condition starts at 0, got %+v", got)
	}

	now += 3600
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("pass 3: %v", err)
	}
	if got := r.AssignmentDeferral(); len(got) != 1 || got[0].PersistedSeconds != 3600 {
		t.Errorf("an hour later the same condition reports 3600s, got %+v", got)
	}
}

// The render-skip is the second persistent condition the health lane carries.
func TestRunOnce_RenderSkipPublishesADeferral(t *testing.T) {
	r, client, _, _, statePath, manifestRoot, _ := upgradeTestReconciler(t)
	_ = statePath
	client.responses["/api/v1/system/node_api/modules"] = listM1M2
	client.responses["/api/v1/system/node_api/modules/m2"] = confirmedM2Body
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("pass 1: %v", err)
	}

	client.statuses = map[string]int{"/api/v1/system/node_api/modules/m2": 404}
	delete(client.responses, "/api/v1/system/node_api/modules/m2")
	if err := os.RemoveAll(filepath.Join(manifestRoot, "m2")); err != nil {
		t.Fatalf("RemoveAll m2 manifest cache: %v", err)
	}
	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("pass 2 (render skipped): %v", err)
	}
	got := r.AssignmentDeferral()
	if len(got) != 1 || got[0].Reason != DeferralIdentityRenderSkipped || strings.Join(got[0].ModuleIDs, ",") != "m2" {
		t.Errorf("a render-skipped tick must publish the skip naming the unresolved module, got %+v", got)
	}
}

func TestFetchAssignedModules_ParsesConfirmedUnassigned(t *testing.T) {
	client := &stubModulesClient{responses: map[string]string{
		"/api/v1/system/node_api/modules": `{"success": true, "data": {"modules": [], "confirmed_unassigned": [
			{"module_id":"a","reason":"assignment_destroyed"}, {"module_id":"a"}, {"module_id":""}, {"reason":"x"}, "junk", 7]}}`,
	}}
	_, meta, err := FetchAssignedModules(context.Background(), client)
	if err != nil {
		t.Fatalf("FetchAssignedModules: %v", err)
	}
	if strings.Join(meta.ConfirmedUnassigned, ",") != "a" {
		t.Errorf("only well-formed, de-duplicated module ids may be carried, got %v", meta.ConfirmedUnassigned)
	}

	client.responses["/api/v1/system/node_api/modules"] = `{"success": true, "data": {"modules": [], "confirmed_unassigned": "everything"}}`
	_, meta, err = FetchAssignedModules(context.Background(), client)
	if err != nil {
		t.Fatalf("FetchAssignedModules (malformed): %v", err)
	}
	if len(meta.ConfirmedUnassigned) != 0 {
		t.Errorf("a malformed confirmation is no confirmation, got %v", meta.ConfirmedUnassigned)
	}
}

// Staging the next boot's composition is the third reader of the empty list: a
// confirmation for every data module this boot composed makes the empty set the
// truth, a confirmation for only some leaves it untrusted.
func TestStagePendingCompose_ConfirmationGovernsTheEmptyListGuard(t *testing.T) {
	stage := func(t *testing.T, confirmed []string) []string {
		t.Helper()
		dir := t.TempDir()
		t.Cleanup(SetPendingComposePathForTest(dir + "/pending.json"))
		bcPath := dir + "/boot-composed.json"
		if err := WriteBreadcrumb(bcPath, &BootComposedBreadcrumb{
			Modules: []LKGModule{{ID: "m1", HasDataFile: true, Digest: "sha256:old"}, {ID: "m2", HasDataFile: true, Digest: "sha256:old2"}},
		}); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(SetBootBreadcrumbPathForTest(bcPath))
		var signals []string
		r := &Reconciler{cfg: ReconcilerConfig{OnError: func(stage string, err error) { signals = append(signals, stage) }}}
		r.stagePendingCompose(nil, map[string]*manifest.Manifest{}, AssignmentMeta{ConfirmedUnassigned: confirmed})
		return signals
	}

	if got := stage(t, []string{"m1"}); !strings.Contains(strings.Join(got, " "), "reconciler:stage_pending_compose_skipped_empty_assignment") {
		t.Errorf("a partial confirmation must leave the staging guard in force, got %v", got)
	}
	if got := stage(t, []string{"m1", "m2"}); strings.Contains(strings.Join(got, " "), "reconciler:stage_pending_compose_skipped_empty_assignment") {
		t.Errorf("a confirmation covering every composed data module lifts the staging guard, got %v", got)
	}
}

// The health lane's wire: the published deferral rides the heartbeat under
// assignment_deferral, and a clean reconciler leaves the key out entirely.
func TestBuildHeartbeat_AssignmentDeferralFromReconciler(t *testing.T) {
	r := &Reconciler{nowUnix: func() int64 { return 500 }}
	svc := &Service{
		cfg:        Config{AgentVersion: "test", StatePath: t.TempDir() + "/state.json", OnError: func(string, error) {}},
		reconciler: r,
	}

	if got := svc.buildHeartbeat("boot-1", nil).AssignmentDeferral; len(got) != 0 {
		t.Fatalf("a reconciler with no deferral must report none, got %+v", got)
	}

	r.recordAssignmentDeferral(DeferralEmptyAssignment, []string{"m1", "m1"})
	r.publishAssignmentDeferral()
	got := svc.buildHeartbeat("boot-1", nil).AssignmentDeferral
	if len(got) != 1 || got[0].Reason != DeferralEmptyAssignment || strings.Join(got[0].ModuleIDs, ",") != "m1" {
		t.Fatalf("AssignmentDeferral = %+v, want one empty_assignment report naming m1 once", got)
	}
	raw, err := json.Marshal(svc.buildHeartbeat("boot-1", nil))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(raw), `"assignment_deferral":[{"reason":"empty_assignment","module_ids":["m1"],"persisted_seconds":0}]`) {
		t.Errorf("wire shape drifted: %s", raw)
	}
}

// The predicate the state-rebase guard and the staging guard share: untrusted
// only while a module the platform did not confirm is attached to a list that
// names no data module. A list that names one is never untrusted.
func TestEmptyListUntrusted(t *testing.T) {
	data := []AssignedModule{{ID: "d", HasDataFile: true}}
	cfgOnly := []AssignedModule{{ID: "c", HasDataFile: false}}
	cases := []struct {
		name      string
		assigned  []AssignedModule
		attached  []string
		confirmed map[string]bool
		want      bool
	}{
		{"empty list, nothing confirmed", nil, []string{"a"}, nil, true},
		{"config-only list, nothing confirmed", cfgOnly, []string{"a"}, nil, true},
		{"empty list, every attached module confirmed", nil, []string{"a", "b"}, map[string]bool{"a": true, "b": true}, false},
		{"empty list, one attached module unconfirmed", nil, []string{"a", "b"}, map[string]bool{"a": true}, true},
		{"nothing attached", nil, nil, nil, false},
		{"list names a data module: confirmations never consulted", data, []string{"a"}, nil, false},
	}
	for _, tc := range cases {
		if got := emptyListUntrusted(tc.assigned, tc.attached, tc.confirmed); got != tc.want {
			t.Errorf("%s: emptyListUntrusted = %v, want %v", tc.name, got, tc.want)
		}
	}
}

// A confirmation is a licence to detach only through the normal detach path: on
// a node that hosts its own control plane, a service-bearing module is still
// refused (the 2026-07-28 unrecoverable-outage guard), confirmed or not.
func TestRunOnce_ConfirmedUnassignmentStillPassesTheSelfHostFence(t *testing.T) {
	r, client, runner, statePath, signals := attachM1(t)
	r.selfHostMu.Lock()
	r.selfHostLatched = true
	r.selfHostMu.Unlock()
	appUnit := lifecycle.UnitName("m1", "app")
	client.responses["/api/v1/system/node_api/modules"] = emptyListConfirming("m1")
	pre := len(runner.Invocations)
	*signals = nil

	if err := r.RunOnce(context.Background()); err != nil {
		t.Fatalf("pass 2: %v", err)
	}

	if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "d1" {
		t.Errorf("a service-bearing module on a self-hosted node must survive a confirmed unassignment: digest=%q ok=%v", digest, ok)
	}
	if hasSystemctlOp(runner.Invocations[pre:], "stop", appUnit) {
		t.Errorf("m1 must not be stopped on a self-hosted node: %v", runner.Invocations[pre:])
	}
	if !strings.Contains(strings.Join(*signals, " "), "reconciler:self_host_detach_refused") {
		t.Errorf("the refusal must be surfaced, got %v", *signals)
	}
}

// A response with no `modules` key at all is malformed or degraded, not an empty
// assignment: confirmations riding on it are ignored and the tick fails closed.
func TestRunOnce_ConfirmationWithoutAModulesKeyIsIgnored(t *testing.T) {
	for name, body := range map[string]string{
		"key absent": `{"success": true, "data": {"confirmed_unassigned": [{"module_id":"m1"}]}}`,
		"key null":   `{"success": true, "data": {"modules": null, "confirmed_unassigned": [{"module_id":"m1"}]}}`,
	} {
		t.Run(name, func(t *testing.T) {
			r, client, _, statePath, _ := attachM1(t)
			client.responses["/api/v1/system/node_api/modules"] = body

			if err := r.RunOnce(context.Background()); err != nil {
				t.Fatalf("pass 2: %v", err)
			}
			if digest, ok := attachedDigest(t, statePath, "m1"); !ok || digest != "d1" {
				t.Errorf("confirmations on a response without a modules array must not detach m1: digest=%q ok=%v", digest, ok)
			}
		})
	}
}
