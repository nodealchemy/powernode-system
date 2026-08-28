package runtime

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Hardware inventory detection tests (IMP-657e05418572).
//
// These drive the REAL detector — detectCapabilities, the same function
// DetectCapabilities calls in Service.New — through its filesystem and
// command seams. Nothing here hand-injects a NodeCapabilities field: the
// assertions are against the marshalled heartbeat payload the agent
// actually emits, because the consuming Rails ingest test is pinned to
// that same wire JSON and a hand-built fixture on both sides would let
// the lane go green against an input no node ever sends.

// hwFixture lays out a fake /proc + /sys tree and returns the probes
// pointed at it.
type hwFixture struct {
	procRoot string
	sysRoot  string
}

func newHWFixture(t *testing.T) *hwFixture {
	t.Helper()
	root := t.TempDir()
	f := &hwFixture{
		procRoot: filepath.Join(root, "proc"),
		sysRoot:  filepath.Join(root, "sys"),
	}
	f.writeFile(t, filepath.Join(f.procRoot, "sys/kernel/osrelease"), "6.8.0-136-generic\n")
	f.writeFile(t, filepath.Join(f.procRoot, "filesystems"), "nodev\toverlay\n\terofs\n\text4\n")
	return f
}

func (f *hwFixture) writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir %s: %v", path, err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}

func (f *hwFixture) kernelProbe() kernelProbe {
	return kernelProbe{procRoot: f.procRoot, modulesRoot: filepath.Join(f.procRoot, "..", "lib", "modules")}
}

func (f *hwFixture) hardwareProbe(run func(string, ...string) ([]byte, error)) hardwareProbe {
	return hardwareProbe{procRoot: f.procRoot, sysRoot: f.sysRoot, run: run}
}

// fakeRun serves canned stdout per binary name. A name absent from the
// map returns exec-style "not found" — which is the ORDINARY state of
// nvidia-smi on the fleet, not a fault.
func fakeRun(outputs map[string]string) func(string, ...string) ([]byte, error) {
	return func(name string, _ ...string) ([]byte, error) {
		out, ok := outputs[name]
		if !ok {
			return nil, errors.New("exec: \"" + name + "\": executable file not found in $PATH")
		}
		return []byte(out), nil
	}
}

const lspciNvidiaFixture = `00:1f.2 SATA controller [0106]: Intel Corporation C620 [8086:a182] (rev 09)
07:00.0 VGA compatible controller [0300]: ASPEED Technology, Inc. ASPEED Graphics Family [1a03:2000] (rev 41)
3b:00.0 3D controller [0302]: NVIDIA Corporation GA100 [10de:20b2] (rev a1)
d8:00.0 3D controller [0302]: NVIDIA Corporation GA100 [10de:20b2] (rev a1)
`

const lspciNoAcceleratorFixture = `00:1f.2 SATA controller [0106]: Intel Corporation C620 [8086:a182] (rev 09)
07:00.0 VGA compatible controller [0300]: ASPEED Technology, Inc. ASPEED Graphics Family [1a03:2000] (rev 41)
`

// goldenPayloadPath is the CROSS-LANGUAGE ORACLE. This file is written
// by the detector below and READ BACK, verbatim, by the Rails ingest spec
// (server/spec/models/system/node_instance_hardware_hints_spec.rb). One
// artifact, two consumers: a change to the agent's wire shape fails this
// test AND flows straight into the Rails spec's input, so neither side
// can quietly drift onto a payload the other never sees. Two hand-kept
// copies of the same literal would only have tripped the Go side.
//
// Regenerate after an intentional wire change with:
//
//	UPDATE_GOLDEN=1 go test ./internal/runtime/ -run TestDetectCapabilitiesWirePayload
const goldenPayloadPath = "testdata/node_capabilities_golden.json"

// TestDetectCapabilitiesWirePayload pins the exact heartbeat wire shape.
func TestDetectCapabilitiesWirePayload(t *testing.T) {
	f := newHWFixture(t)
	f.writeFile(t, filepath.Join(f.procRoot, "meminfo"),
		"MemTotal:       263168000 kB\nMemFree:         1000000 kB\nMemAvailable:  200000000 kB\n")
	f.writeFile(t, filepath.Join(f.sysRoot, "class/dmi/id/product_name"), "PowerEdge R740\n")

	caps := detectCapabilities(f.kernelProbe(), f.hardwareProbe(fakeRun(map[string]string{
		"nvidia-smi": "NVIDIA H100 PCIe, 81559\nNVIDIA H100 PCIe, 81559\n",
	})))

	got, err := json.Marshal(caps)
	if err != nil {
		t.Fatalf("marshal capabilities: %v", err)
	}
	if os.Getenv("UPDATE_GOLDEN") != "" {
		if err := os.MkdirAll(filepath.Dir(goldenPayloadPath), 0o755); err != nil {
			t.Fatalf("mkdir testdata: %v", err)
		}
		if err := os.WriteFile(goldenPayloadPath, append(got, '\n'), 0o644); err != nil {
			t.Fatalf("write golden: %v", err)
		}
		t.Logf("golden regenerated: %s", goldenPayloadPath)
	}

	goldenBytes, err := os.ReadFile(goldenPayloadPath)
	if err != nil {
		t.Fatalf("read golden %s (regenerate with UPDATE_GOLDEN=1): %v", goldenPayloadPath, err)
	}
	want := strings.TrimSpace(string(goldenBytes))
	if string(got) != want {
		t.Errorf("capability wire payload drifted from the golden the Rails ingest spec reads.\n"+
			" got: %s\nwant: %s\nIf the new shape is intended, regenerate with UPDATE_GOLDEN=1 "+
			"and re-run the Rails spec, which consumes this same file.", got, want)
	}

	// And the same block as the server actually receives it: nested under
	// node_capabilities inside the heartbeat body.
	body, err := json.Marshal(HeartbeatPayload{BootID: "b1", Capabilities: caps})
	if err != nil {
		t.Fatalf("marshal heartbeat: %v", err)
	}
	if !strings.Contains(string(body), `"node_capabilities":`+want) {
		t.Errorf("heartbeat body does not carry the capability block verbatim: %s", body)
	}
}

// A node with no GPU and a node whose GPU detection could not run must
// stay distinguishable on the wire. This is the property that a bare Go
// scalar with omitempty silently destroys.
func TestGPUAbsenceIsDistinguishableFromZero(t *testing.T) {
	f := newHWFixture(t)

	t.Run("detector ran and found none: explicit zero, key PRESENT", func(t *testing.T) {
		caps := detectCapabilities(f.kernelProbe(), f.hardwareProbe(fakeRun(map[string]string{
			"lspci": lspciNoAcceleratorFixture,
		})))
		if caps.GPUCount == nil {
			t.Fatalf("expected a measured count, got nil (not measured)")
		}
		if *caps.GPUCount != 0 {
			t.Errorf("GPUCount = %d, want 0", *caps.GPUCount)
		}
		b, _ := json.Marshal(caps)
		if !strings.Contains(string(b), `"gpu_count":0`) {
			t.Errorf("a measured zero must survive to the wire, got %s", b)
		}
	})

	t.Run("no detector available: key OMITTED", func(t *testing.T) {
		caps := detectCapabilities(f.kernelProbe(), f.hardwareProbe(fakeRun(map[string]string{})))
		if caps.GPUCount != nil {
			t.Fatalf("expected nil (not measured), got %d", *caps.GPUCount)
		}
		b, _ := json.Marshal(caps)
		if strings.Contains(string(b), `"gpu_count"`) {
			t.Errorf("an unmeasured count must not appear on the wire, got %s", b)
		}
	})
}

// nvidia-smi absent is the NORMAL case: fall through to lspci, which
// establishes count + type but knows nothing about VRAM.
func TestGPULspciFallbackWhenNvidiaSMIMissing(t *testing.T) {
	f := newHWFixture(t)

	caps := detectCapabilities(f.kernelProbe(), f.hardwareProbe(fakeRun(map[string]string{
		"lspci": lspciNvidiaFixture,
	})))

	if caps.GPUCount == nil || *caps.GPUCount != 2 {
		t.Fatalf("GPUCount = %v, want 2 (the two 3D controllers; the ASPEED BMC must not count)", caps.GPUCount)
	}
	if caps.GPUType != "NVIDIA Corporation GA100" {
		t.Errorf("GPUType = %q, want %q", caps.GPUType, "NVIDIA Corporation GA100")
	}
	if caps.GPUMemoryMB != nil {
		t.Errorf("lspci cannot see VRAM; GPUMemoryMB must stay nil, got %d", *caps.GPUMemoryMB)
	}
}

// nvidia-smi wins when present, and supplies the VRAM lspci cannot.
func TestGPUNvidiaSMIPreferredOverLspci(t *testing.T) {
	f := newHWFixture(t)

	caps := detectCapabilities(f.kernelProbe(), f.hardwareProbe(fakeRun(map[string]string{
		"nvidia-smi": "NVIDIA H100 PCIe, 81559\n",
		"lspci":      lspciNvidiaFixture,
	})))

	if caps.GPUCount == nil || *caps.GPUCount != 1 {
		t.Fatalf("GPUCount = %v, want 1 (nvidia-smi's answer, not lspci's 2)", caps.GPUCount)
	}
	if caps.GPUMemoryMB == nil || *caps.GPUMemoryMB != 81559 {
		t.Fatalf("GPUMemoryMB = %v, want 81559", caps.GPUMemoryMB)
	}
}

// "[N/A]" VRAM must leave the field unmeasured rather than fabricate 0.
func TestGPUMemoryNotAvailableStaysNil(t *testing.T) {
	f := newHWFixture(t)

	caps := detectCapabilities(f.kernelProbe(), f.hardwareProbe(fakeRun(map[string]string{
		"nvidia-smi": "NVIDIA GeForce RTX 4090, [N/A]\n",
	})))

	if caps.GPUCount == nil || *caps.GPUCount != 1 {
		t.Fatalf("GPUCount = %v, want 1", caps.GPUCount)
	}
	if caps.GPUMemoryMB != nil {
		t.Errorf("unparseable VRAM must stay nil, got %d", *caps.GPUMemoryMB)
	}
}

func TestMemoryTotalUnknownStaysNil(t *testing.T) {
	f := newHWFixture(t) // no meminfo written

	caps := detectCapabilities(f.kernelProbe(), f.hardwareProbe(fakeRun(map[string]string{})))

	if caps.MemoryTotalMB != nil {
		t.Fatalf("unreadable /proc/meminfo must leave MemoryTotalMB nil, got %d", *caps.MemoryTotalMB)
	}
	b, _ := json.Marshal(caps)
	if strings.Contains(string(b), `"memory_total_mb"`) {
		t.Errorf("unmeasured memory must not reach the wire, got %s", b)
	}
}

func TestHardwareModelSources(t *testing.T) {
	t.Run("DMI product_name", func(t *testing.T) {
		f := newHWFixture(t)
		f.writeFile(t, filepath.Join(f.sysRoot, "class/dmi/id/product_name"), "PowerEdge R740\n")
		caps := detectCapabilities(f.kernelProbe(), f.hardwareProbe(fakeRun(nil)))
		if caps.HardwareModel != "PowerEdge R740" {
			t.Errorf("HardwareModel = %q, want %q", caps.HardwareModel, "PowerEdge R740")
		}
	})

	t.Run("device-tree fallback for a board with no DMI", func(t *testing.T) {
		f := newHWFixture(t)
		// device-tree properties are NUL-terminated.
		f.writeFile(t, filepath.Join(f.procRoot, "device-tree/model"), "Raspberry Pi 5 Model B Rev 1.0\x00")
		caps := detectCapabilities(f.kernelProbe(), f.hardwareProbe(fakeRun(nil)))
		if caps.HardwareModel != "Raspberry Pi 5 Model B Rev 1.0" {
			t.Errorf("HardwareModel = %q, want the device-tree model without its NUL", caps.HardwareModel)
		}
	})

	t.Run("unprogrammed DMI placeholder falls through", func(t *testing.T) {
		f := newHWFixture(t)
		f.writeFile(t, filepath.Join(f.sysRoot, "class/dmi/id/product_name"), "To be filled by O.E.M.\n")
		f.writeFile(t, filepath.Join(f.procRoot, "device-tree/model"), "Raspberry Pi 4 Model B Rev 1.4\x00")
		caps := detectCapabilities(f.kernelProbe(), f.hardwareProbe(fakeRun(nil)))
		if caps.HardwareModel != "Raspberry Pi 4 Model B Rev 1.4" {
			t.Errorf("a DMI placeholder must not be reported as a model; got %q", caps.HardwareModel)
		}
	})

	t.Run("nothing names the machine", func(t *testing.T) {
		f := newHWFixture(t)
		caps := detectCapabilities(f.kernelProbe(), f.hardwareProbe(fakeRun(nil)))
		if caps.HardwareModel != "" {
			t.Errorf("HardwareModel = %q, want empty", caps.HardwareModel)
		}
		b, _ := json.Marshal(caps)
		if strings.Contains(string(b), `"hardware_model"`) {
			t.Errorf("an unknown model must not reach the wire, got %s", b)
		}
	})
}

// The kernel-feature half must keep working through the new seams.
func TestDetectCapabilitiesStillReportsKernelFeatures(t *testing.T) {
	f := newHWFixture(t)
	caps := detectCapabilities(f.kernelProbe(), f.hardwareProbe(fakeRun(nil)))

	if caps.KernelVersion != "6.8.0-136-generic" {
		t.Errorf("KernelVersion = %q", caps.KernelVersion)
	}
	if !caps.ErofsAvailable || !caps.OverlayfsAvailable || !caps.FsverityAvailable {
		t.Errorf("kernel features regressed: %+v", caps)
	}
}

// AMD datacenter accelerators enumerate under PCI classes 0380 (Display
// controller, MI250) and 1200 (Processing accelerator, MI300), NOT the
// 0300/0302 classes NVIDIA uses. Since nvidia-smi covers NVIDIA, those
// two classes are the entire unique value of the lspci fallback.
func TestGPULspciCountsAMDAcceleratorClasses(t *testing.T) {
	f := newHWFixture(t)

	const lspciAMD = `07:00.0 VGA compatible controller [0300]: ASPEED Technology, Inc. ASPEED Graphics Family [1a03:2000] (rev 41)
c1:00.0 Display controller [0380]: Advanced Micro Devices, Inc. [AMD/ATI] Aldebaran [1002:7408]
c2:00.0 Display controller [0380]: Advanced Micro Devices, Inc. [AMD/ATI] Aldebaran [1002:7408]
b3:00.0 Processing accelerators [1200]: Advanced Micro Devices, Inc. [AMD/ATI] Device [1002:74a1]
`

	caps := detectCapabilities(f.kernelProbe(), f.hardwareProbe(fakeRun(map[string]string{
		"lspci": lspciAMD,
	})))

	if caps.GPUCount == nil || *caps.GPUCount != 3 {
		t.Fatalf("GPUCount = %v, want 3 (two MI250 + one MI300; the ASPEED BMC must not count)", caps.GPUCount)
	}
	if !strings.Contains(caps.GPUType, "Aldebaran") {
		t.Errorf("GPUType = %q, want the first AMD device's description", caps.GPUType)
	}
}

// A driver-only nvidia-smi (package installed, no NVIDIA card) answers 0.
// Short-circuiting there would make every non-NVIDIA accelerator invisible
// on any host that happens to carry the NVIDIA userland.
func TestGPUNvidiaSMIZeroStillConsultsLspci(t *testing.T) {
	f := newHWFixture(t)

	caps := detectCapabilities(f.kernelProbe(), f.hardwareProbe(fakeRun(map[string]string{
		"nvidia-smi": "\n",
		"lspci": "c1:00.0 Display controller [0380]: Advanced Micro Devices, Inc. " +
			"[AMD/ATI] Aldebaran [1002:7408]\n",
	})))

	if caps.GPUCount == nil || *caps.GPUCount != 1 {
		t.Fatalf("GPUCount = %v, want 1 (lspci saw the AMD card nvidia-smi cannot)", caps.GPUCount)
	}
}

// ...but when BOTH agree there is nothing, the measured zero stands.
func TestGPUBothDetectorsAgreeOnZero(t *testing.T) {
	f := newHWFixture(t)

	caps := detectCapabilities(f.kernelProbe(), f.hardwareProbe(fakeRun(map[string]string{
		"nvidia-smi": "\n",
		"lspci":      lspciNoAcceleratorFixture,
	})))

	if caps.GPUCount == nil {
		t.Fatalf("expected a measured count, got nil (not measured)")
	}
	if *caps.GPUCount != 0 {
		t.Errorf("GPUCount = %d, want 0", *caps.GPUCount)
	}
}

// nvidia-smi answering while lspci is absent must keep nvidia-smi's answer,
// including a measured zero — not degrade to "unknown".
func TestGPUNvidiaSMIZeroWithNoLspciStaysMeasured(t *testing.T) {
	f := newHWFixture(t)

	caps := detectCapabilities(f.kernelProbe(), f.hardwareProbe(fakeRun(map[string]string{
		"nvidia-smi": "\n",
	})))

	if caps.GPUCount == nil || *caps.GPUCount != 0 {
		t.Fatalf("GPUCount = %v, want a measured 0", caps.GPUCount)
	}
}
