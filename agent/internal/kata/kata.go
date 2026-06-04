// Package kata provisions Kata Containers microVM runtimes on a node — the
// second real isolation tier of the AI/MCP workload substrate (L0), one rung
// stronger than gVisor: each container runs in a lightweight hardware-virtualized
// VM (KVM) rather than a userspace kernel. It supports two Docker runtime
// registrations that System::IsolationTier maps to:
//
//   - "kata-runtime" (tier "kata")        — the default hypervisor (QEMU/cloud-hypervisor)
//   - "kata-fc"      (tier "firecracker") — the Firecracker VMM, via a kata config
//
// Unlike gVisor (a single self-installable runsc binary), Kata is a MULTI-ARTIFACT
// runtime: the kata-runtime/shim binary, a guest kernel, a guest rootfs/initrd,
// and a VMM. Those are large and host-specific, so this package does NOT download
// them — it VALIDATES that the runtime is installed and that KVM is available, then
// registers the runtime in daemon.json. The install itself is provisioned out of
// band (a kata-containers NodeModule or the host image), the honest model for a
// hypervisor-backed runtime.
package kata

import (
	"context"
	"fmt"
	"os"
	"strings"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

const (
	// RuntimeName is the Docker runtime name for the default (QEMU/CLH) hypervisor.
	RuntimeName = "kata-runtime"
	// FCRuntimeName is the Docker runtime name for the Firecracker variant.
	FCRuntimeName = "kata-fc"
	// DefaultBinaryPath is where the kata runtime/shim binary lives.
	DefaultBinaryPath = "/usr/bin/kata-runtime"
	// DefaultFCConfigPath is the kata configuration that selects the Firecracker VMM.
	DefaultFCConfigPath = "/opt/kata/share/defaults/kata-containers/configuration-fc.toml"

	// Confidential-compute runtimes: Kata selecting a TEE-enabled hypervisor
	// config so guest memory is hardware-encrypted + attestable.
	SNPRuntimeName = "kata-qemu-snp" // AMD SEV-SNP
	TDXRuntimeName = "kata-qemu-tdx" // Intel TDX
	DefaultSNPConfigPath = "/opt/kata/share/defaults/kata-containers/configuration-qemu-snp.toml"
	DefaultTDXConfigPath = "/opt/kata/share/defaults/kata-containers/configuration-qemu-tdx.toml"
)

// KVMDevice must exist for any microVM runtime to boot guests. SEVDevice /
// TDXDevice are the host indicators that the CPU's trusted-execution environment
// is available for a confidential (encrypted-memory) guest. Vars (not consts) —
// host-kernel-dependent, so operators can tune them and tests can point them at
// a present/absent path.
var (
	KVMDevice = "/dev/kvm"
	SEVDevice = "/dev/sev"
	TDXDevice = "/dev/tdx_guest"
)

// Variant describes how one requested isolation runtime registers with Docker.
type Variant struct {
	RuntimeName string   // daemon.json runtimes key, e.g. "kata-runtime" / "kata-fc"
	RuntimeArgs []string // optional runtimeArgs (FC / TEE variants select their config here)
	TEEDevice   string   // host TEE device a confidential variant requires ("" = none)
}

// Confidential reports whether this variant needs a hardware TEE (SEV/TDX).
func (v Variant) Confidential() bool { return v.TEEDevice != "" }

// VariantFor maps a requested runtime/tier name to its Docker registration, or
// false if this package doesn't handle that name. Accepts both the tier name
// ("kata"/"firecracker"/"sev"/"tdx") and the docker runtime name
// ("kata-runtime"/"kata-fc"/"kata-qemu-snp"/"kata-qemu-tdx").
func VariantFor(name, fcConfigPath string) (Variant, bool) {
	switch strings.ToLower(strings.TrimSpace(name)) {
	case "kata", RuntimeName:
		return Variant{RuntimeName: RuntimeName}, true
	case "firecracker", FCRuntimeName:
		return Variant{RuntimeName: FCRuntimeName, RuntimeArgs: []string{"--config", orDefault(fcConfigPath, DefaultFCConfigPath)}}, true
	case "sev", SNPRuntimeName:
		return Variant{RuntimeName: SNPRuntimeName, RuntimeArgs: []string{"--config", DefaultSNPConfigPath}, TEEDevice: SEVDevice}, true
	case "tdx", TDXRuntimeName:
		return Variant{RuntimeName: TDXRuntimeName, RuntimeArgs: []string{"--config", DefaultTDXConfigPath}, TEEDevice: TDXDevice}, true
	default:
		return Variant{}, false
	}
}

// Handles reports whether this package provisions the given runtime/tier name.
func Handles(name string) bool {
	_, ok := VariantFor(name, "")
	return ok
}

// runtimeEntry is the daemon.json value registering a kata runtime.
func runtimeEntry(binaryPath string, args []string) map[string]any {
	entry := map[string]any{"path": resolveBinary(binaryPath)}
	if len(args) > 0 {
		entry["runtimeArgs"] = args
	}
	return entry
}

// MergeRuntime registers one kata variant in a daemon.json config map without
// clobbering other runtimes. Returns true if cfg changed.
func MergeRuntime(cfg map[string]any, v Variant, binaryPath string) bool {
	runtimes, _ := cfg["runtimes"].(map[string]any)
	if runtimes == nil {
		runtimes = map[string]any{}
	}
	entry := runtimeEntry(binaryPath, v.RuntimeArgs)
	if cur, ok := runtimes[v.RuntimeName].(map[string]any); ok && sameEntry(cur, entry) {
		return false
	}
	runtimes[v.RuntimeName] = entry
	cfg["runtimes"] = runtimes
	return true
}

// Status is the on-node Kata readiness state.
type Status struct {
	BinaryPresent bool   `json:"binary_present"`
	Version       string `json:"version,omitempty"`
	KVMPresent    bool   `json:"kvm_present"`
	Registered    bool   `json:"registered"`
}

// Ready reports whether Kata can actually boot a microVM: runtime binary
// runnable AND /dev/kvm present. Registration is tracked separately so callers
// can tell "installed but not yet wired" from "not installed".
func (s Status) Ready() bool { return s.BinaryPresent && s.KVMPresent }

// Detect reports Kata's state: binary runnable (kata-runtime --version), KVM
// device present, and whether the variant is registered in daemonCfg.
func Detect(ctx context.Context, runner mount.Runner, binaryPath, runtimeName string, daemonCfg map[string]any) Status {
	st := Status{KVMPresent: kvmPresent()}
	if out, err := runner.Output(ctx, resolveBinary(binaryPath), "--version"); err == nil {
		st.BinaryPresent = true
		st.Version = firstLine(string(out))
	}
	if runtimes, ok := daemonCfg["runtimes"].(map[string]any); ok {
		_, st.Registered = runtimes[runtimeName]
	}
	return st
}

// EnsureReady validates that the variant can run (KVM, plus a host TEE device
// for confidential variants, plus a runnable runtime binary) WITHOUT downloading
// anything. Returns an actionable error when prerequisites are missing — the
// multi-artifact runtime must be provisioned out of band (kata-containers module
// / host image). Unlike gVisor.EnsureInstalled there is no install path here.
func EnsureReady(ctx context.Context, runner mount.Runner, binaryPath string, v Variant) error {
	if !pathPresent(KVMDevice) {
		return fmt.Errorf("kata: %s not present — hardware virtualization (KVM) is required for microVM isolation", KVMDevice)
	}
	if v.Confidential() && !pathPresent(v.TEEDevice) {
		return fmt.Errorf("kata: confidential runtime %q requires a host TEE device at %s (CPU SEV-SNP/TDX support) — not present",
			v.RuntimeName, v.TEEDevice)
	}
	if _, err := runner.Output(ctx, resolveBinary(binaryPath), "--version"); err != nil {
		return fmt.Errorf("kata: runtime not runnable at %s (provision the kata-containers module / host image first): %w",
			resolveBinary(binaryPath), err)
	}
	return nil
}

func kvmPresent() bool { return pathPresent(KVMDevice) }

func pathPresent(p string) bool {
	_, err := os.Stat(p)
	return err == nil
}

func sameEntry(a, b map[string]any) bool {
	if a["path"] != b["path"] {
		return false
	}
	aa, _ := a["runtimeArgs"].([]string)
	bb, _ := b["runtimeArgs"].([]string)
	if len(aa) != len(bb) {
		// also handle []any from a round-tripped config
		ai, _ := a["runtimeArgs"].([]any)
		if len(ai) != len(bb) {
			return false
		}
		for i := range bb {
			if fmt.Sprint(ai[i]) != bb[i] {
				return false
			}
		}
		return true
	}
	for i := range aa {
		if aa[i] != bb[i] {
			return false
		}
	}
	return true
}

func resolveBinary(p string) string {
	if strings.TrimSpace(p) == "" {
		return DefaultBinaryPath
	}
	return p
}

func orDefault(v, d string) string {
	if strings.TrimSpace(v) == "" {
		return d
	}
	return v
}

func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return strings.TrimSpace(s[:i])
	}
	return strings.TrimSpace(s)
}
