package runtime

import (
	"bufio"
	"os"
	"strings"
)

// NodeCapabilities is the kernel-feature snapshot the agent advertises
// in every heartbeat. The platform reads it for fleet introspection
// ("which nodes can mount erofs?") and as a sanity gate before
// reconciling modules onto a node — if the kernel can't mount erofs,
// the module assignment is rejected before any blob is pulled.
//
// Detection runs once at service startup. The set is stable across
// agent restarts until the kernel itself changes (kexec, upgrade,
// downgrade); persisting it would only save microseconds, so we
// re-detect on each boot for simplicity.
type NodeCapabilities struct {
	KernelVersion      string `json:"kernel_version,omitempty"`
	ErofsAvailable     bool   `json:"erofs_available"`
	OverlayfsAvailable bool   `json:"overlayfs_available"`
	FsverityAvailable  bool   `json:"fsverity_available"`
}

// DetectCapabilities scans /proc/filesystems + /proc/sys/kernel/osrelease
// to figure out what the on-node kernel supports. Each capability check
// is independent — a partial failure (e.g. /proc/filesystems unreadable)
// returns a struct with conservative defaults rather than an error,
// because every kernel that runs systemd has the basics enabled.
func DetectCapabilities() *NodeCapabilities {
	caps := &NodeCapabilities{}

	// Kernel version. /proc/sys/kernel/osrelease is the canonical
	// uname -r value and avoids the syscall.Utsname int8/uint8
	// portability split between linux/amd64 (int8) and linux/arm64
	// (uint8). Falls back to empty string on read failure.
	if b, err := os.ReadFile("/proc/sys/kernel/osrelease"); err == nil {
		caps.KernelVersion = strings.TrimSpace(string(b))
	}

	// Parse /proc/filesystems for the kernel-registered filesystem
	// names. erofs and overlay show up in column 2 when the driver
	// is built in or already loaded as a module; for built-in
	// drivers that haven't been used yet, they'll still appear.
	fs := readProcFilesystems()
	caps.ErofsAvailable = fs["erofs"]
	caps.OverlayfsAvailable = fs["overlay"]

	// fs-verity is a per-superblock feature, not a "filesystem" in
	// /proc/filesystems. The reliable check is "does the running
	// kernel have the syscall registered" — testing without
	// touching real files is non-trivial, so we infer from the
	// kernel version (>=5.4 ships fs-verity unconditionally in
	// stock distro configs). Conservative: false if uname failed.
	caps.FsverityAvailable = kernelAtLeast(caps.KernelVersion, 5, 4)

	return caps
}

// readProcFilesystems returns a name → present? map for the kernel's
// registered filesystems. Returns empty map on read failure (caller
// treats missing keys as "unavailable").
func readProcFilesystems() map[string]bool {
	f, err := os.Open("/proc/filesystems")
	if err != nil {
		return map[string]bool{}
	}
	defer f.Close()

	out := make(map[string]bool, 32)
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		// Lines are either "nodev <name>" or "<name>" (block-backed).
		// Both are kernel-known filesystems we can mount.
		fields := strings.Fields(scanner.Text())
		switch len(fields) {
		case 1:
			out[fields[0]] = true
		case 2:
			out[fields[1]] = true
		}
	}
	return out
}

// kernelAtLeast reports whether a uname-reported version string
// "6.8.0-106-generic" meets the major.minor threshold (e.g. 5.4).
// Returns false on parse failure (conservative).
func kernelAtLeast(version string, major, minor int) bool {
	if version == "" {
		return false
	}
	parts := strings.SplitN(version, ".", 3)
	if len(parts) < 2 {
		return false
	}
	maj, err := atoiBest(parts[0])
	if err {
		return false
	}
	// "8-106-generic" — keep only digits prefix.
	min, err := atoiBest(stripNonDigits(parts[1]))
	if err {
		return false
	}
	if maj > major {
		return true
	}
	if maj < major {
		return false
	}
	return min >= minor
}

// atoiBest parses the leading decimal-digit run of s. Returns
// (value, errored=true) when s has no leading digit. Stops at the
// first non-digit, so "12abc" → (12, false) and "abc" → (0, true).
func atoiBest(s string) (int, bool) {
	n := 0
	parsed := false
	for _, c := range s {
		if c < '0' || c > '9' {
			break
		}
		n = n*10 + int(c-'0')
		parsed = true
	}
	return n, !parsed
}

func stripNonDigits(s string) string {
	for i, c := range s {
		if c < '0' || c > '9' {
			return s[:i]
		}
	}
	return s
}
