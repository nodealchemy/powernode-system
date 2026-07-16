package runtime

import (
	"os"
	"path/filepath"
	"strings"
)

// instanceNameFwCfgPath is the virtio-fw-cfg blob the platform populates with
// the NodeInstance's name. Both provider seeds write it:
// System::Providers::LocalQemu::CloudSeed and Proxmox::EnrollmentSeed each emit
// opt/com.powernode/instance_name (= NodeInstance.name). fw-cfg args live in the
// VM config, so QEMU re-presents this blob on every boot. It is a LEGACY /
// fallback source: it carries the (long) instance name, and a bare-provisioned
// node never receives it — so the authoritative source is the mTLS-delivered
// node name (see assignedHostnamePath).
const instanceNameFwCfgPath = "/sys/firmware/qemu_fw_cfg/by_name/opt/com.powernode/instance_name/raw"

// assignedHostnamePath is where the agent persists the platform-assigned
// hostname — node.name, the operator-facing short name (e.g. "ops-hub") —
// delivered over the enrolled mTLS channel in the /node_api/modules envelope.
// It lives under /persist so it survives reboots AND is written by the compose
// fetch (compose.go's FetchAssignedModules) BEFORE that same pass applies the
// hostname, so the pre-pivot sysroot /etc/hostname is correct before
// switch_root + DHCP — closing the fw-cfg-only gap for nodes that never
// received an instance_name blob. A var (not const) so tests can redirect it.
var assignedHostnamePath = "/persist/var/lib/powernode/hostname"

// persistAssignedHostname records the platform-assigned hostname to
// assignedHostnamePath. Best-effort: an absent/read-only /persist just means the
// fw-cfg path or a later tick handles it. Empty names are ignored so a node the
// platform sends no hostname for keeps whatever it had. Idempotent — it skips
// the write when the stored value already matches, so it's cheap every tick.
func persistAssignedHostname(name string) {
	name = strings.TrimSpace(name)
	if name == "" {
		return
	}
	if cur, err := os.ReadFile(assignedHostnamePath); err == nil && strings.TrimSpace(string(cur)) == name {
		return
	}
	if err := os.MkdirAll(filepath.Dir(assignedHostnamePath), 0o755); err != nil {
		return
	}
	_ = os.WriteFile(assignedHostnamePath, []byte(name+"\n"), 0o644)
}

// desiredHostname returns the authoritative hostname this node should carry, or
// "" when no authoritative source is present. Precedence:
//
//  1. the platform-assigned hostname persisted from the mTLS /node_api/modules
//     envelope (node.name — the operator-facing name, e.g. "ops-hub"). This is
//     authoritative and works on bare-provisioned nodes with no fw-cfg.
//  2. the fw-cfg instance_name blob (legacy QEMU/Proxmox seed path; carries the
//     long instance name).
//
// Callers pass the result to etcidentity.ApplyHostname, which no-ops on "" — so
// a node with neither source keeps whatever hostname it already has (the agent
// never invents one).
func desiredHostname() string {
	if raw, err := os.ReadFile(assignedHostnamePath); err == nil {
		if name := strings.TrimSpace(string(raw)); name != "" {
			return name
		}
	}
	raw, err := os.ReadFile(instanceNameFwCfgPath)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(raw))
}
