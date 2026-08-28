package runtime

import (
	"context"
	"os"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// Hardware inventory detection (IMP-657e05418572).
//
// Three facts the platform's capacity readers already fall back to but
// which, until this file existed, NOTHING produced:
//
//	NodeInstance#gpu_count / #gpu_type / #gpu_memory_mb → config["gpu"]
//	NodeInstance#available_memory_mb                    → config["memory_mb"]
//	NodeInstance#hardware_model_hint                    → config["hardware_model"]
//
// All three ride inside the EXISTING node_capabilities heartbeat block
// (see NodeCapabilities) rather than opening a fourth telemetry channel.
// The server maps them into the config hints on ingest; see
// System::NodeInstance.hardware_hints_from_capabilities.
//
// Detection runs ONCE at service construction, alongside the kernel
// capability probe: installed RAM, chassis model and PCI accelerator
// inventory are all boot-stable facts. Nothing here logs — nvidia-smi is
// absent on the overwhelming majority of nodes and that is the NORMAL
// case, not a fault.
//
// ABSENCE VS ZERO. Every numeric field is a pointer. A nil pointer is
// omitted from the wire and means NOT MEASURED; a non-nil pointer to 0
// means a detector ran and measured zero. A node with no GPU and a node
// whose GPU detection could not run are different facts, and the server
// must be able to tell them apart — collapsing them into a bare `int`
// would make "we could not look" indistinguishable from "we looked and
// there is nothing", which is exactly how the capacity readers end up
// scheduling inference onto a node that cannot run it.

// hardwareProbe bundles the filesystem and command seams hardware
// detection needs. Tests drive the REAL detector through this struct
// against fixture trees and a fake command runner, so the assertion is
// against the payload the agent actually builds rather than a hand-
// injected struct literal.
type hardwareProbe struct {
	procRoot string // "/proc" in production
	sysRoot  string // "/sys" in production
	// run executes a detection binary and returns its stdout. A non-nil
	// error means the binary is missing or failed — for nvidia-smi that
	// is the ordinary case on a GPU-less node.
	run func(name string, args ...string) ([]byte, error)
}

// hardwareProbeTimeout bounds each detection binary. DetectCapabilities
// runs synchronously in Service.New — before Run() starts the heartbeat,
// task lease and cert rotation goroutines — so a wedged nvidia-smi (a
// hung driver is a real failure mode on a node with a sick GPU) must not
// block the agent from starting. A block there does not crash the unit:
// systemd would report it active while the platform watched the node go
// SILENT, with nothing to point at.
const hardwareProbeTimeout = 5 * time.Second

func defaultHardwareProbe() hardwareProbe {
	return hardwareProbe{
		procRoot: "/proc",
		sysRoot:  "/sys",
		run: func(name string, args ...string) ([]byte, error) {
			ctx, cancel := context.WithTimeout(context.Background(), hardwareProbeTimeout)
			defer cancel()
			cmd := exec.CommandContext(ctx, name, args...)
			// WaitDelay is load-bearing, not belt-and-braces. Context
			// cancellation only sends a signal, and Wait then blocks until
			// the process actually exits — a process parked in
			// uninterruptible D-state on a wedged NVIDIA ioctl cannot be
			// killed at all, so Output() would never return and the
			// timeout above would bound nothing. WaitDelay makes Wait
			// return regardless, which is the only thing that actually
			// caps this call.
			cmd.WaitDelay = hardwareProbeTimeout
			return cmd.Output()
		},
	}
}

// detectHardware fills the hardware inventory fields of caps. Each of
// the three probes is independent: a failure in one leaves ONLY its own
// fields nil (not measured) and never aborts the others.
func detectHardware(p hardwareProbe, caps *NodeCapabilities) {
	if caps == nil {
		return
	}
	caps.GPUCount, caps.GPUType, caps.GPUMemoryMB = detectGPU(p)
	caps.MemoryTotalMB = detectMemoryTotalMB(p)
	caps.HardwareModel = detectHardwareModel(p)
}

// detectGPU returns the node's accelerator inventory.
//
// nvidia-smi first: it is the only source that yields per-device VRAM
// and a usable marketing name. Its ABSENCE is the normal case and is
// silently treated as "try the next source", never as a failure.
//
// lspci second: it cannot report VRAM, but it CAN establish the count
// and the device name, which is what system_find_node_with_gpu needs to
// stop treating a bare-metal GPU node as GPU-less.
//
// When neither binary is runnable the count stays nil — unknown. That
// is deliberately NOT reported as 0: a node whose detection tooling is
// missing has not been shown to lack a GPU.
func detectGPU(p hardwareProbe) (*int, string, *int64) {
	nvCount, nvType, nvMemMB, nvOK := detectGPUViaNvidiaSMI(p)
	if nvOK && nvCount != nil && *nvCount > 0 {
		return nvCount, nvType, nvMemMB
	}

	// nvidia-smi either could not run, or ran and found nothing. The
	// second case still needs lspci: a driver-only nvidia-smi (the
	// package is installed, the card is AMD or absent) answers 0 for a
	// host that does have an accelerator lspci can see. Short-circuiting
	// on nvidia-smi's 0 would make every non-NVIDIA GPU invisible on any
	// host where the NVIDIA userland happens to be installed.
	if count, gpuType, ok := detectGPUViaLspci(p); ok && (count != nil && *count > 0 || !nvOK) {
		return count, gpuType, nil
	}
	if nvOK {
		return nvCount, nvType, nvMemMB
	}
	return nil, "", nil
}

// detectGPUViaNvidiaSMI queries the NVIDIA driver. ok=false means the
// binary is absent or errored (no driver, no card, wedged driver) — the
// caller falls through to lspci rather than concluding anything.
func detectGPUViaNvidiaSMI(p hardwareProbe) (*int, string, *int64, bool) {
	if p.run == nil {
		return nil, "", nil, false
	}
	out, err := p.run("nvidia-smi",
		"--query-gpu=name,memory.total", "--format=csv,noheader,nounits")
	if err != nil {
		return nil, "", nil, false
	}

	count := 0
	var gpuType string
	var memMB *int64
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		fields := strings.Split(line, ",")
		name := strings.TrimSpace(fields[0])
		if name == "" {
			continue
		}
		count++
		if count > 1 {
			// Heterogeneous GPU hosts are out of scope: the platform's
			// config["gpu"] hint carries ONE type/vram pair, so the
			// first device defines the node's advertised accelerator.
			continue
		}
		gpuType = name
		if len(fields) > 1 {
			if mb, ok := parseGPUMemoryMB(fields[1]); ok {
				memMB = &mb
			}
		}
	}
	// nvidia-smi succeeded, so the driver answered: a 0 here is a real
	// measurement ("driver present, no devices"), not an unknown.
	return &count, gpuType, memMB, true
}

// parseGPUMemoryMB parses an `--format=nounits` memory.total field,
// which is MiB. Returns ok=false for the "[N/A]" the driver emits for
// devices it cannot query.
func parseGPUMemoryMB(field string) (int64, bool) {
	v := strings.TrimSpace(field)
	if v == "" {
		return 0, false
	}
	mb, err := strconv.ParseInt(v, 10, 64)
	if err != nil || mb < 0 {
		return 0, false
	}
	return mb, true
}

// lspciGPULine matches an accelerator-bearing PCI class in `lspci -nn`
// output, capturing the device description and the vendor ID:
//
//	01:00.0 3D controller [0302]: NVIDIA Corporation GA100 [10de:20b2] (rev a1)
//
// Classes, all four load-bearing:
//
//	0300 VGA compatible controller — consumer/workstation cards
//	0302 3D controller             — headless datacenter NVIDIA (Tesla/A100/H100)
//	0380 Display controller        — where AMD Instinct (MI250) enumerates
//	1200 Processing accelerator    — where AMD Instinct (MI300) enumerates
//
// 0380/1200 matter specifically because this is the FALLBACK path: NVIDIA
// is covered properly by nvidia-smi, so the only unique value lspci adds
// is catching accelerators nvidia-smi cannot see — which is exactly the
// AMD datacenter parts that live in those two classes.
var lspciGPULine = regexp.MustCompile(`\[(?:0300|0302|0380|1200)\]:\s*(.+?)\s*\[([0-9a-fA-F]{4}):[0-9a-fA-F]{4}\]`)

// acceleratorVendorIDs are the PCI vendors whose display-class devices
// are treated as schedulable accelerators.
//
// Deliberately NARROW. Every server has a display-class device — the
// ASPEED/Matrox BMC framebuffer, Intel integrated graphics — and
// counting those would advertise a GPU on essentially the whole fleet,
// which is worse than the current under-reporting: system_find_node_with_gpu
// would place inference work on nodes that cannot run it. The cost is
// that the lspci FALLBACK misses discrete Intel accelerators; NVIDIA
// (the case this task exists for) is covered properly by nvidia-smi.
var acceleratorVendorIDs = map[string]bool{
	"10de": true, // NVIDIA
	"1002": true, // AMD / ATI
}

// detectGPUViaLspci counts accelerator-vendor display devices.
// ok=false means lspci itself could not be run — unknown, not zero.
func detectGPUViaLspci(p hardwareProbe) (*int, string, bool) {
	if p.run == nil {
		return nil, "", false
	}
	out, err := p.run("lspci", "-nn")
	if err != nil {
		return nil, "", false
	}

	count := 0
	var gpuType string
	for _, m := range lspciGPULine.FindAllStringSubmatch(string(out), -1) {
		if !acceleratorVendorIDs[strings.ToLower(m[2])] {
			continue
		}
		count++
		if count == 1 {
			gpuType = strings.TrimSpace(m[1])
		}
	}
	return &count, gpuType, true
}

// detectMemoryTotalMB reads MemTotal from /proc/meminfo and converts to
// MiB. MemTotal (not MemAvailable — that is the per-tick runtime metric
// readMemAvailableKB reports) is the node's INSTALLED capacity, which is
// what NodeInstance#available_memory_mb and the heavyweight network
// profile floor are asking about.
//
// The kernel reserves a little RAM before it reports MemTotal, so this
// reads slightly UNDER nameplate (a "4GB" board reports ~3.8GB). That
// biases the heavyweight floor toward the safe lightweight profile,
// which is the direction the suggester already errs in.
//
// nil when /proc/meminfo is unreadable or carries no MemTotal — never a
// fabricated 0.
func detectMemoryTotalMB(p hardwareProbe) *int64 {
	kb, ok := readMeminfoFieldKB(p.procRoot+"/meminfo", "MemTotal:")
	if !ok {
		return nil
	}
	mb := kb / 1024
	return &mb
}

// dmiPlaceholders are the strings vendors ship in an unprogrammed DMI
// field. They identify no hardware, so reporting them would put noise
// into config["hardware_model"] that reads exactly like a real model.
var dmiPlaceholders = map[string]bool{
	"to be filled by o.e.m.": true,
	"system product name":    true,
	"default string":         true,
	"not specified":          true,
	"not applicable":         true,
	"none":                   true,
	"unknown":                true,
	"o.e.m.":                 true,
}

// detectHardwareModel returns the chassis/board model as the firmware
// reports it, VERBATIM. Normalisation into the platform's vocabulary is
// the server's job (hardware_hints_from_capabilities) — the agent's
// contract is to report the fact it observed.
//
// /sys/class/dmi/id/product_name is the x86/UEFI source and is
// world-readable, so this needs no privilege (unlike dmidecode).
// Raspberry Pi and other device-tree boards expose no DMI at all; there
// the model lives in /proc/device-tree/model as a NUL-terminated string.
//
// Empty string (omitted from the wire) means not determined.
func detectHardwareModel(p hardwareProbe) string {
	if v := readTrimmedFile(p.sysRoot + "/class/dmi/id/product_name"); isRealHardwareModel(v) {
		return v
	}
	if v := readTrimmedFile(p.procRoot + "/device-tree/model"); isRealHardwareModel(v) {
		return v
	}
	return ""
}

func isRealHardwareModel(v string) bool {
	if v == "" {
		return false
	}
	return !dmiPlaceholders[strings.ToLower(v)]
}

// readTrimmedFile reads a small sysfs/procfs string file, trimming the
// trailing newline and the NUL terminator device-tree properties carry.
// Returns "" on any read failure.
func readTrimmedFile(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(strings.TrimRight(string(b), "\x00"))
}
