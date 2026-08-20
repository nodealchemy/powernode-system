// heartbeat_ovn_test.go — IMP-57e9a90598ee: the heartbeat carries the
// manager's OVN NB replay observation.
//
// Before this, Manager.OvnNbStatus() had ZERO callers: the observation was
// computed on every reconcile tick and thrown away, and its doc comment
// falsely claimed a heartbeat integration existed. These tests pin the actual
// wiring: buildHeartbeat embeds the snapshot at the payload's top level
// (host-scoped, like the OVN replay itself), absent when nothing was
// measured.
package runtime

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/sdwan"
	"github.com/nodealchemy/powernode-system/agent/internal/transport"
)

// stubWg satisfies sdwan.WgApplier with no-ops; the config below carries zero
// networks so none of these should even be called.
type stubWg struct{}

func (stubWg) ApplyInterface(context.Context, sdwan.InterfaceConf, []sdwan.PeerConf, string) error {
	return nil
}
func (stubWg) RemoveInterface(context.Context, string) error { return nil }
func (stubWg) ReadActualState(context.Context, string) (*sdwan.ActualInterfaceState, error) {
	return &sdwan.ActualInterfaceState{}, nil
}
func (stubWg) ListSdwanInterfaces(context.Context) ([]string, error) { return nil, nil }

// stubNb returns a fixed observation, standing in for a real NB replay.
type stubNb struct{ obs *sdwan.ObservedOvnNbState }

func (s stubNb) Apply(context.Context, *sdwan.OvnNbPlan) (*sdwan.ObservedOvnNbState, error) {
	return s.obs, nil
}

func reconciledManager(t *testing.T, obs *sdwan.ObservedOvnNbState) *sdwan.Manager {
	t.Helper()

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.Method == http.MethodPost {
			w.Write([]byte(`{"success":true,"data":{}}`))
			return
		}
		// Zero networks; a one-command NB plan so the OVN NB subsystem runs.
		w.Write([]byte(`{"success":true,"data":{"instance_id":"inst-1","networks":[],` +
			`"ovn_nb_plan":{"deployment_id":"dep-1","nb_db_endpoint":"tcp:10.0.0.1:6641",` +
			`"plan":[{"cmd":"ls-add","args":["ls-app"]}],"compiled_at":"2026-08-20T00:00:00Z"}}}`))
	}))
	t.Cleanup(srv.Close)

	mgr := &sdwan.Manager{
		Client:       transport.NewForTest(srv.URL, 5*time.Second),
		Applier:      stubWg{},
		OvnNbApplier: stubNb{obs: obs},
		OnError:      func(string, error) {},
	}
	mgr.Reconcile(context.Background())
	return mgr
}

func testService(t *testing.T) *Service {
	t.Helper()
	return &Service{cfg: Config{
		AgentVersion: "test",
		StatePath:    filepath.Join(t.TempDir(), "state.json"),
		OnError:      func(string, error) {},
	}}
}

func TestBuildHeartbeatEmbedsOvnNbObservation(t *testing.T) {
	obs := &sdwan.ObservedOvnNbState{
		DeploymentID:    "dep-1",
		NbDbEndpoint:    "tcp:10.0.0.1:6641",
		PlanCommands:    1,
		AppliedCommands: 1,
		CompiledAt:      "2026-08-20T00:00:00Z",
		LastReplayAt:    "2026-08-20T00:00:01Z",
	}
	payload := testService(t).buildHeartbeat("boot-1", reconciledManager(t, obs))

	if payload.SdwanOvnState == nil {
		t.Fatalf("heartbeat must carry the OVN NB observation the manager holds")
	}
	if payload.SdwanOvnState.DeploymentID != "dep-1" || payload.SdwanOvnState.AppliedCommands != 1 {
		t.Fatalf("wrong observation embedded: %+v", payload.SdwanOvnState)
	}

	body, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if !strings.Contains(string(body), `"sdwan_ovn_state":{`) {
		t.Fatalf("payload JSON must carry sdwan_ovn_state, got: %s", body)
	}
}

func TestBuildHeartbeatOmitsOvnBlockWhenNotMeasured(t *testing.T) {
	// A manager that never reconciled holds no observation — the field must
	// be ABSENT (not measured), never an empty object a consumer could
	// misread as a healthy replay.
	mgr := sdwan.NewManager(transport.NewForTest("http://127.0.0.1:0", time.Second), stubWg{},
		func(string, error) {})
	payload := testService(t).buildHeartbeat("boot-1", mgr)

	if payload.SdwanOvnState != nil {
		t.Fatalf("no reconcile has run; the OVN block must be nil, got %+v", payload.SdwanOvnState)
	}
	body, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if strings.Contains(string(body), "sdwan_ovn_state") {
		t.Fatalf("unmeasured OVN state must be omitted from the wire, got: %s", body)
	}
}
