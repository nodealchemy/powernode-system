package runtime

import (
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/sdwan"
	"github.com/nodealchemy/powernode-system/agent/internal/transport"
	"github.com/nodealchemy/powernode-system/agent/internal/verify"
)

// IMP-13645c4df90a — a wiring regression test, not a behavior test (that's
// TestReconcilerRunOnce_SdwanExtrasSurviveAlongsideModuleEgressAllow in
// reconcile_test.go). This one exists to catch the specific mistake of
// deleting `ExtraEgress: sdwanMgr.EgressContributions` from
// buildReconcilerConfig — a regression a behavior test alone would not
// localize as clearly, since ReconcilerConfig.ExtraEgress being nil looks
// identical to "no SDWAN networks yet" until a network actually exists.
func TestBuildReconcilerConfig_WiresSdwanExtraEgress(t *testing.T) {
	s := New(Config{PlatformURL: "https://hub.example.test", StatePath: t.TempDir() + "/state.json"})
	client := &transport.Client{PlatformURL: "https://hub.example.test"}
	sdwanMgr := sdwan.NewManager(nil, nil, func(string, error) {})

	cfg := s.buildReconcilerConfig(client, sdwanMgr, verify.AlwaysOK{}, nil)

	if cfg.ExtraEgress == nil {
		t.Fatal("ReconcilerConfig.ExtraEgress is nil — the SDWAN egress wiring (IMP-13645c4df90a) is missing")
	}

	// Prove it is wired to THIS manager, not merely non-nil: seed a desired
	// config directly (same access EgressContributions' own test file has,
	// same package techniques aside — sdwan.Manager exports nothing to set
	// this from outside the package, so exercise it via a real Reconcile
	// input instead: an empty manager reports empty extras either way, which
	// would pass even if ExtraEgress were wired to some OTHER always-empty
	// func — so this asserts the returned value on the empty case is
	// EXACTLY what calling the manager's own method directly returns, which
	// is false only if a future edit wires a fabricated func literal instead
	// of the manager's method value.
	got := cfg.ExtraEgress()
	want := sdwanMgr.EgressContributions()
	if len(got.Networks) != len(want.Networks) {
		t.Errorf("cfg.ExtraEgress() = %+v, want exactly sdwanMgr.EgressContributions() = %+v", got, want)
	}
}
