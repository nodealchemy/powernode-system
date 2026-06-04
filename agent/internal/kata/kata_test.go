package kata

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

type fakeRunner struct {
	version string
	fail    bool
}

func (fakeRunner) Run(context.Context, string, ...string) error { return nil }
func (f fakeRunner) Output(context.Context, string, ...string) ([]byte, error) {
	if f.fail {
		return nil, errors.New("not runnable")
	}
	return []byte(f.version), nil
}

func TestVariantFor(t *testing.T) {
	if v, ok := VariantFor("kata", ""); !ok || v.RuntimeName != RuntimeName || len(v.RuntimeArgs) != 0 {
		t.Fatalf("kata: %+v ok=%v", v, ok)
	}
	if v, ok := VariantFor("kata-runtime", ""); !ok || v.RuntimeName != RuntimeName {
		t.Fatalf("kata-runtime: %+v ok=%v", v, ok)
	}

	v, ok := VariantFor("firecracker", "/custom/fc.toml")
	if !ok || v.RuntimeName != FCRuntimeName {
		t.Fatalf("firecracker: %+v ok=%v", v, ok)
	}
	if len(v.RuntimeArgs) != 2 || v.RuntimeArgs[0] != "--config" || v.RuntimeArgs[1] != "/custom/fc.toml" {
		t.Fatalf("fc args: %v", v.RuntimeArgs)
	}

	// blank fc config → default path
	v2, _ := VariantFor("kata-fc", "")
	if v2.RuntimeArgs[1] != DefaultFCConfigPath {
		t.Fatalf("default fc config: %v", v2.RuntimeArgs)
	}

	if _, ok := VariantFor("gvisor", ""); ok {
		t.Fatal("gvisor must not be handled by kata")
	}
	if Handles("runsc") {
		t.Fatal("runsc must not be handled by kata")
	}
	if !Handles("firecracker") {
		t.Fatal("firecracker must be handled by kata")
	}
}

func TestMergeRuntime(t *testing.T) {
	cfg := map[string]any{"runtimes": map[string]any{"runsc": map[string]any{"path": "/usr/local/bin/runsc"}}}

	vKata, _ := VariantFor("kata", "")
	if !MergeRuntime(cfg, vKata, "") {
		t.Fatal("expected change registering kata-runtime")
	}
	vFC, _ := VariantFor("firecracker", "")
	MergeRuntime(cfg, vFC, "")

	rt := cfg["runtimes"].(map[string]any)
	if _, ok := rt["runsc"]; !ok {
		t.Fatalf("clobbered an existing runtime: %v", rt)
	}
	kr, _ := rt["kata-runtime"].(map[string]any)
	if kr["path"] != DefaultBinaryPath {
		t.Fatalf("kata-runtime path: %v", kr)
	}
	if kr["runtimeArgs"] != nil {
		t.Fatalf("kata-runtime should have no runtimeArgs: %v", kr)
	}
	fc, _ := rt["kata-fc"].(map[string]any)
	if fc["runtimeArgs"] == nil {
		t.Fatalf("kata-fc must carry runtimeArgs (--config): %v", fc)
	}

	// idempotent
	if MergeRuntime(cfg, vKata, "") {
		t.Fatal("second identical merge should be a no-op")
	}
}

func TestConfidentialVariants(t *testing.T) {
	sev, ok := VariantFor("sev", "")
	if !ok || sev.RuntimeName != SNPRuntimeName || !sev.Confidential() || sev.TEEDevice != SEVDevice {
		t.Fatalf("sev: %+v ok=%v", sev, ok)
	}
	if len(sev.RuntimeArgs) != 2 || sev.RuntimeArgs[1] != DefaultSNPConfigPath {
		t.Fatalf("sev config arg: %v", sev.RuntimeArgs)
	}
	tdx, ok := VariantFor("kata-qemu-tdx", "")
	if !ok || tdx.RuntimeName != TDXRuntimeName || tdx.TEEDevice != TDXDevice {
		t.Fatalf("tdx: %+v ok=%v", tdx, ok)
	}
	// Non-confidential variants must not advertise a TEE requirement.
	if k, _ := VariantFor("kata", ""); k.Confidential() {
		t.Fatal("plain kata must not be confidential")
	}
}

func TestEnsureReadyAndDetect(t *testing.T) {
	dir := t.TempDir()
	kvm := filepath.Join(dir, "kvm")
	origKVM, origSEV := KVMDevice, SEVDevice
	defer func() { KVMDevice, SEVDevice = origKVM, origSEV }()
	basic, _ := VariantFor("kata", "")

	// KVM absent → error mentions the device.
	KVMDevice = filepath.Join(dir, "absent")
	if err := EnsureReady(context.Background(), fakeRunner{version: "kata 3.0"}, "", basic); err == nil {
		t.Fatal("expected error when KVM is absent")
	}

	// KVM present + binary runnable → ready.
	if err := os.WriteFile(kvm, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	KVMDevice = kvm
	if err := EnsureReady(context.Background(), fakeRunner{version: "kata 3.0"}, "", basic); err != nil {
		t.Fatalf("expected ready: %v", err)
	}

	// KVM present but binary not runnable → error.
	if err := EnsureReady(context.Background(), fakeRunner{fail: true}, "", basic); err == nil {
		t.Fatal("expected error when the kata runtime binary is not runnable")
	}

	// Confidential variant: KVM present but TEE device absent → error.
	sev, _ := VariantFor("sev", "")
	SEVDevice = filepath.Join(dir, "no-sev")
	sev.TEEDevice = SEVDevice
	if err := EnsureReady(context.Background(), fakeRunner{version: "kata 3.0"}, "", sev); err == nil {
		t.Fatal("expected error when the confidential TEE device is absent")
	}
	// TEE device present → ready.
	tee := filepath.Join(dir, "sev")
	if err := os.WriteFile(tee, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	sev.TEEDevice = tee
	if err := EnsureReady(context.Background(), fakeRunner{version: "kata 3.0"}, "", sev); err != nil {
		t.Fatalf("expected confidential ready: %v", err)
	}

	// Detect reflects binary + KVM + registration; Version is first line only.
	cfg := map[string]any{"runtimes": map[string]any{RuntimeName: map[string]any{"path": DefaultBinaryPath}}}
	st := Detect(context.Background(), fakeRunner{version: "kata 3.0\n  vmm: qemu"}, "", RuntimeName, cfg)
	if !st.BinaryPresent || !st.KVMPresent || !st.Registered {
		t.Fatalf("detect: %+v", st)
	}
	if !st.Ready() {
		t.Fatal("expected Ready (binary + kvm)")
	}
	if st.Version != "kata 3.0" {
		t.Fatalf("version first line: %q", st.Version)
	}
}
