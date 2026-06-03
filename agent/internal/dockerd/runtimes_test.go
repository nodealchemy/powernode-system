package dockerd

import (
	"context"
	"errors"
	"testing"
)

// runscPresentRunner reports runsc as runnable, so EnsureInstalled skips the
// (network) install in tests.
type runscPresentRunner struct{}

func (runscPresentRunner) Run(context.Context, string, ...string) error { return nil }
func (runscPresentRunner) Output(context.Context, string, ...string) ([]byte, error) {
	return []byte("runsc version test"), nil
}

func TestGvisorRuntimeEnsurer_RegistersRunsc(t *testing.T) {
	e := GvisorRuntimeEnsurer{Runner: runscPresentRunner{}}
	cfg := map[string]any{}
	if err := e.Ensure(context.Background(), "gvisor", cfg); err != nil {
		t.Fatalf("ensure: %v", err)
	}
	rt, _ := cfg["runtimes"].(map[string]any)
	if _, ok := rt["runsc"]; !ok {
		t.Fatalf("runsc not registered: %v", cfg)
	}
}

func TestGvisorRuntimeEnsurer_RejectsUnsupported(t *testing.T) {
	e := GvisorRuntimeEnsurer{Runner: runscPresentRunner{}}
	if err := e.Ensure(context.Background(), "kata", map[string]any{}); err == nil {
		t.Fatal("expected an error for an unsupported runtime")
	}
}

// fakeEnsurer records calls and registers a marker runtime.
type fakeEnsurer struct {
	calls []string
	err   error
}

func (f *fakeEnsurer) Ensure(_ context.Context, name string, cfg map[string]any) error {
	f.calls = append(f.calls, name)
	if f.err != nil {
		return f.err
	}
	rt, _ := cfg["runtimes"].(map[string]any)
	if rt == nil {
		rt = map[string]any{}
	}
	rt["runsc"] = map[string]any{"path": "/usr/local/bin/runsc"}
	cfg["runtimes"] = rt
	return nil
}

func TestReconcile_EnsuresRequestedRuntimes(t *testing.T) {
	a := &stubApplier{Cert: &CertMaterial{ServerCertPEM: "exists"}}
	m, fp, _ := newTestManager(t, []string{"docker-engine"}, a)
	defer fp.close()
	fake := &fakeEnsurer{}
	m.Runtimes = fake
	m.RequestedRuntimes = []string{"gvisor"}

	m.Reconcile(context.Background())

	if len(fake.calls) != 1 || fake.calls[0] != "gvisor" {
		t.Fatalf("expected ensure(gvisor) once, got %v", fake.calls)
	}
	if a.Config == nil {
		t.Fatal("no daemon config written")
	}
	rt, _ := a.Config.ExtraConfig["runtimes"].(map[string]any)
	if _, ok := rt["runsc"]; !ok {
		t.Fatalf("runsc not in written daemon.json: %v", a.Config.ExtraConfig)
	}
}

func TestReconcile_RuntimeEnsureFailureAbortsStart(t *testing.T) {
	a := &stubApplier{Cert: &CertMaterial{ServerCertPEM: "exists"}}
	m, fp, _ := newTestManager(t, []string{"docker-engine"}, a)
	defer fp.close()
	m.Runtimes = &fakeEnsurer{err: errors.New("install failed")}
	m.RequestedRuntimes = []string{"gvisor"}

	m.Reconcile(context.Background())

	if a.WriteCfgCalls != 0 {
		t.Fatalf("expected no WriteDaemonConfig when runtime ensure fails, got %d", a.WriteCfgCalls)
	}
	if a.StartCalls != 0 {
		t.Fatalf("expected no StartDaemon when runtime ensure fails, got %d", a.StartCalls)
	}
}
