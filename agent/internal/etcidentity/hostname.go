package etcidentity

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"

	"github.com/nodealchemy/powernode-system/agent/internal/fsutil"
)

// HostNameMax is the kernel's HOST_NAME_MAX. sethostname(2) rejects a name
// longer than this with EINVAL, so ApplyHostname caps the value to fit —
// a mis-sized platform name degrades to truncated-but-valid rather than a
// failed apply.
const HostNameMax = 64

// ApplyHostname makes <root>/etc/hostname authoritatively equal to name and,
// when applyLive is true, also sets the running kernel hostname via
// sethostname(2). It is the hostname analogue of this package's passwd/group
// authority: the agent OWNS /etc/hostname, the write is atomic
// (fsutil.AtomicWrite), and the whole thing is idempotent — a name already on
// disk (and already live) is a no-op, so reconcile ticks never churn the file
// or the kernel.
//
// root == "" targets the live filesystem ("/etc/hostname"); a non-empty root
// targets a composed union (e.g. the pivot sysroot) so the file lands in the
// rootfs that becomes / after switch_root. On the pivot path callers pass
// applyLive=false: the initramfs's own hostname is irrelevant and
// systemd-in-the-union applies /etc/hostname when it boots post-switch_root.
//
// name is trimmed of surrounding whitespace and capped at HostNameMax. An
// empty name is a no-op — this function never invents a hostname; the caller
// owns sourcing the authoritative value (see runtime.desiredHostname).
//
// Returns (changed, error): changed is true when the file or the live kernel
// hostname was actually mutated.
func ApplyHostname(root, name string, applyLive bool) (changed bool, err error) {
	name = strings.TrimSpace(name)
	if name == "" {
		return false, nil
	}
	if len(name) > HostNameMax {
		name = name[:HostNameMax]
	}

	path := "/etc/hostname"
	if root != "" {
		path = filepath.Join(root, "etc", "hostname")
	}

	// Write the file only when it actually differs — AtomicWrite is cheap but
	// a no-op write still fsyncs + renames, and skipping it keeps reconcile
	// ticks quiet (mirrors etcidentity.Apply's byte-stable rationale).
	if cur, rerr := os.ReadFile(path); rerr != nil || !bytes.Equal(bytes.TrimSpace(cur), []byte(name)) {
		if werr := fsutil.AtomicWrite(path, []byte(name+"\n"), 0o644); werr != nil {
			return changed, fmt.Errorf("write %s: %w", path, werr)
		}
		changed = true
	}

	// Pin the name systemd-networkd announces to DHCP. The base image bakes a
	// build-time /etc/hostname (a random machine name), and networkd's DHCP
	// client sends whatever /etc/hostname holds at request time. Writing
	// /etc/hostname above is only sufficient when this pass runs on the
	// pre-pivot sysroot BEFORE networkd's first DHCP; a stale lease or an early
	// DHCP still leaks the baked name into DNS. An explicit [DHCPv4]/[DHCPv6]
	// Hostname= drop-in decouples the announced name from /etc/hostname timing
	// entirely. Best-effort: the hostname write above is the primary contract,
	// so a read-only or missing networkd dir never fails ApplyHostname.
	dropinDir := "/etc/systemd/network/10-dhcp.network.d"
	if root != "" {
		dropinDir = filepath.Join(root, "etc", "systemd", "network", "10-dhcp.network.d")
	}
	if os.MkdirAll(dropinDir, 0o755) == nil {
		dropin := []byte("[DHCPv4]\nHostname=" + name + "\n[DHCPv6]\nHostname=" + name + "\n")
		dropinPath := filepath.Join(dropinDir, "50-powernode-hostname.conf")
		if cur, rerr := os.ReadFile(dropinPath); rerr != nil || !bytes.Equal(cur, dropin) {
			if fsutil.AtomicWrite(dropinPath, dropin, 0o644) == nil {
				changed = true
			}
		}
	}

	if applyLive {
		if cur, _ := os.Hostname(); cur != name {
			if serr := syscall.Sethostname([]byte(name)); serr != nil {
				return changed, fmt.Errorf("sethostname %q: %w", name, serr)
			}
			changed = true
		}
	}
	return changed, nil
}
