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
