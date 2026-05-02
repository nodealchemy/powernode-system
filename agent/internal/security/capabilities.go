package security

import (
	"context"
	"strings"

	"github.com/powernode/platform/extensions/system/agent/internal/mount"
)

// KnownCapabilities is the canonical set of Linux capability names the
// agent recognizes. Sourced from man capabilities(7); not exhaustive but
// covers everything modules typically request. Unknown names are rejected
// at Validate time rather than at Apply time so misconfigurations surface
// before the module attempts to start.
var KnownCapabilities = map[string]struct{}{
	"CAP_AUDIT_CONTROL":   {},
	"CAP_AUDIT_READ":      {},
	"CAP_AUDIT_WRITE":     {},
	"CAP_BLOCK_SUSPEND":   {},
	"CAP_BPF":             {},
	"CAP_CHECKPOINT_RESTORE": {},
	"CAP_CHOWN":           {},
	"CAP_DAC_OVERRIDE":    {},
	"CAP_DAC_READ_SEARCH": {},
	"CAP_FOWNER":          {},
	"CAP_FSETID":          {},
	"CAP_IPC_LOCK":        {},
	"CAP_IPC_OWNER":       {},
	"CAP_KILL":            {},
	"CAP_LEASE":           {},
	"CAP_LINUX_IMMUTABLE": {},
	"CAP_MAC_ADMIN":       {},
	"CAP_MAC_OVERRIDE":    {},
	"CAP_MKNOD":           {},
	"CAP_NET_ADMIN":       {},
	"CAP_NET_BIND_SERVICE": {},
	"CAP_NET_BROADCAST":   {},
	"CAP_NET_RAW":         {},
	"CAP_PERFMON":         {},
	"CAP_SETGID":          {},
	"CAP_SETFCAP":         {},
	"CAP_SETPCAP":         {},
	"CAP_SETUID":          {},
	"CAP_SYS_ADMIN":       {},
	"CAP_SYS_BOOT":        {},
	"CAP_SYS_CHROOT":      {},
	"CAP_SYS_MODULE":      {},
	"CAP_SYS_NICE":        {},
	"CAP_SYS_PACCT":       {},
	"CAP_SYS_PTRACE":      {},
	"CAP_SYS_RAWIO":       {},
	"CAP_SYS_RESOURCE":    {},
	"CAP_SYS_TIME":        {},
	"CAP_SYS_TTY_CONFIG":  {},
	"CAP_SYSLOG":          {},
	"CAP_WAKE_ALARM":      {},
}

func isValidCapName(name string) bool {
	_, ok := KnownCapabilities[strings.ToUpper(name)]
	return ok
}

// DropCapabilitiesExcept invokes capsh to drop all capabilities except those
// in the allowlist. capsh is the canonical tool from libcap-bin; it sets
// the bounding set + ambient set + permitted+effective sets in one call.
//
// Empty allowlist = drop everything (the safest default for unknown modules).
func DropCapabilitiesExcept(ctx context.Context, runner mount.Runner, allow []string) error {
	args := []string{"--drop=all"}
	if len(allow) > 0 {
		// capsh wants caps without the CAP_ prefix in --caps=...
		caps := make([]string, 0, len(allow))
		for _, c := range allow {
			caps = append(caps, strings.TrimPrefix(strings.ToLower(c), "cap_"))
		}
		args = append(args, "--caps="+strings.Join(caps, ",")+"=eip")
	}
	args = append(args, "--", "/bin/true") // capsh requires a command tail
	return runner.Run(ctx, "capsh", args...)
}
