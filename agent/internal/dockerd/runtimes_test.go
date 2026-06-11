package dockerd

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/kata"
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

func TestReconcile_RuntimeEnsureFailureSkipsButStarts(t *testing.T) {
	a := &stubApplier{Cert: &CertMaterial{ServerCertPEM: "exists"}}
	m, fp, _ := newTestManager(t, []string{"docker-engine"}, a)
	defer fp.close()
	m.Runtimes = &fakeEnsurer{err: errors.New("install failed")}
	m.RequestedRuntimes = []string{"gvisor"}

	m.Reconcile(context.Background())

	// Resilient (substrate L0): an unavailable isolation runtime is logged +
	// skipped, NOT fatal — the daemon still starts for every other workload.
	if a.WriteCfgCalls == 0 {
		t.Fatal("expected WriteDaemonConfig despite runtime ensure failure")
	}
	if a.StartCalls == 0 {
		t.Fatal("expected StartDaemon despite runtime ensure failure")
	}
	// The failed runtime must not be registered.
	if a.Config != nil {
		if rt, _ := a.Config.ExtraConfig["runtimes"].(map[string]any); rt["runsc"] != nil {
			t.Fatalf("failed runtime should not be registered: %v", rt)
		}
	}
}

func TestCompositeRuntimeEnsurer_Dispatch(t *testing.T) {
	// KVM present so kata readiness passes (runscPresentRunner makes both
	// runsc and kata-runtime --version succeed).
	kvm := filepath.Join(t.TempDir(), "kvm")
	if err := os.WriteFile(kvm, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	orig := kata.KVMDevice
	kata.KVMDevice = kvm
	defer func() { kata.KVMDevice = orig }()

	c := CompositeRuntimeEnsurer{
		GvisorRuntimeEnsurer{Runner: runscPresentRunner{}},
		KataRuntimeEnsurer{Runner: runscPresentRunner{}},
	}
	cfg := map[string]any{}
	for _, rt := range []string{"gvisor", "kata", "firecracker"} {
		if err := c.Ensure(context.Background(), rt, cfg); err != nil {
			t.Fatalf("ensure %s: %v", rt, err)
		}
	}
	rt, _ := cfg["runtimes"].(map[string]any)
	for _, name := range []string{"runsc", "kata-runtime", "kata-fc"} {
		if _, ok := rt[name]; !ok {
			t.Fatalf("%s not registered by composite: %v", name, rt)
		}
	}

	// Unknown runtime → ErrUnsupportedRuntime from every handler → composite.
	if err := c.Ensure(context.Background(), "nope", cfg); !errors.Is(err, ErrUnsupportedRuntime) {
		t.Fatalf("expected ErrUnsupportedRuntime for unknown runtime, got %v", err)
	}
}

// F2-01 — fleet-path enforcement: the instance's tier OCI runtime becomes the
// daemon default so every workload container actually runs under it.
func TestReconcile_SetsDefaultRuntimeWhenRegistered(t *testing.T) {
	a := &stubApplier{Cert: &CertMaterial{ServerCertPEM: "exists"}}
	m, fp, _ := newTestManager(t, []string{"docker-engine"}, a)
	defer fp.close()
	m.Runtimes = &fakeEnsurer{}
	m.RequestedRuntimes = []string{"gvisor"}
	m.DefaultRuntime = "runsc"

	m.Reconcile(context.Background())

	if a.Config == nil {
		t.Fatal("no daemon config written")
	}
	if got, _ := a.Config.ExtraConfig["default-runtime"].(string); got != "runsc" {
		t.Fatalf("expected default-runtime runsc, got %v", a.Config.ExtraConfig["default-runtime"])
	}
}

// A default runtime whose ensure failed must NOT become the daemon default —
// dockerd refuses to start with an unknown default-runtime, which would take
// down every other workload on the node.
func TestReconcile_SkipsDefaultRuntimeWhenEnsureFailed(t *testing.T) {
	a := &stubApplier{Cert: &CertMaterial{ServerCertPEM: "exists"}}
	m, fp, _ := newTestManager(t, []string{"docker-engine"}, a)
	defer fp.close()
	m.Runtimes = &fakeEnsurer{err: errors.New("install failed")}
	m.RequestedRuntimes = []string{"gvisor"}
	m.DefaultRuntime = "runsc"

	m.Reconcile(context.Background())

	if a.Config == nil {
		t.Fatal("no daemon config written")
	}
	if _, ok := a.Config.ExtraConfig["default-runtime"]; ok {
		t.Fatalf("default-runtime must not be set when the runtime was never registered: %v", a.Config.ExtraConfig)
	}
}
