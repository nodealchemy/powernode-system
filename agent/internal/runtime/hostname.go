package runtime

import (
	"os"
	"strings"
)

// instanceNameFwCfgPath is the virtio-fw-cfg blob the platform populates with
// the NodeInstance's human name. Both provider seeds write it:
// System::Providers::LocalQemu::CloudSeed and Proxmox::EnrollmentSeed each
// emit opt/com.powernode/instance_name (= NodeInstance.name). fw-cfg args live
// in the VM config, so QEMU re-presents this blob on every boot — making it
// the authoritative, operator-facing hostname source for an enrolled node
// (e.g. "ops-hub"), not a UUID.
const instanceNameFwCfgPath = "/sys/firmware/qemu_fw_cfg/by_name/opt/com.powernode/instance_name/raw"

// desiredHostname returns the authoritative hostname this node should carry,
// or "" when no authoritative source is present on this boot. Callers pass the
// result to etcidentity.ApplyHostname, which no-ops on "" — so a node with no
// source keeps whatever hostname it already has (the agent never invents one).
//
// GAP (reported, not worked around): a bare-provisioned node that never
// received a fw-cfg identity payload (no CloudSeed/EnrollmentSeed run) has no
// instance_name blob, so this returns "". The instance name is NOT delivered
// over the enrolled mTLS channel today (neither the /node_api/enroll response,
// meta.json, /node_api/modules, nor the heartbeat response carries it), so
// there is no fallback source for that path. Closing it requires the platform
// to send the instance name to the agent post-enroll — see the durable-fix
// report for the exact server-side seam.
func desiredHostname() string {
	raw, err := os.ReadFile(instanceNameFwCfgPath)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(raw))
}
