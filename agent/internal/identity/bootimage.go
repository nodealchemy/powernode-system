package identity

import (
	"os"
)

// DefaultCmdlinePath is the kernel command-line pseudo-file.
const DefaultCmdlinePath = "/proc/cmdline"

// BootedImageGitSHA returns the git_sha of the disk image this node actually
// booted from, read from the UKI kernel cmdline (powernode.image_git_sha=<sha>).
//
// The cmdline is the ONLY trustworthy source: the sha is baked into the UKI at
// disk-image build time (build-disk-image-*-uefi.sh), and /proc/cmdline reflects
// the UKI that actually booted and survives switch_root. We deliberately do NOT
// fall back to /etc/powernode/boot-image.json: that file ships in every initramfs
// the kernel-initrd build produces, including any served over netboot (image_base),
// where the sha has no binding to the platform's promotion flow — reading it would
// manufacture false boot-image drift. When the cmdline carries no sha (netboot,
// rpi4, or an image built before campaign 019f505f) this returns "" and the agent
// reports the field as omitempty, i.e. "unknown" — never drift.
func BootedImageGitSHA() string {
	return bootedImageGitSHA(DefaultCmdlinePath)
}

// bootedImageGitSHA is the testable core with an injectable cmdline path.
func bootedImageGitSHA(cmdlinePath string) string {
	raw, err := os.ReadFile(cmdlinePath)
	if err != nil {
		return ""
	}
	return parseCmdline(string(raw))["powernode.image_git_sha"]
}
