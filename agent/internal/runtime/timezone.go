package runtime

import (
	"os"
	"path/filepath"
	"strings"

	"github.com/nodealchemy/powernode-system/agent/internal/etcidentity"
)

// assignedTimezonePath is where the agent persists the timezone the platform
// declared for this node (IMP-87ce46b9a1aa), delivered over the enrolled mTLS
// channel in the /node_api/modules envelope exactly like the hostname
// (assignedHostnamePath). It lives under /persist so it survives reboots, and it
// is written by the fetch BEFORE the same pass renders it, so the pre-pivot
// sysroot carries the zone before switch_root. A var (not const) so tests can
// redirect it.
var assignedTimezonePath = "/persist/var/lib/powernode/timezone"

// applyTimezone is the indirection TestMain redirects, like applyHostname: a test
// that reaches the live-root writer would otherwise render the host's own /etc.
var applyTimezone = etcidentity.ApplyTimezone

// persistAssignedTimezone records the platform-declared timezone to
// assignedTimezonePath. Best-effort and idempotent, like persistAssignedHostname.
//
// The value comes from per-node configuration, so it is checked for SHAPE before
// it is stored (etcidentity.ValidTimezoneName): a malformed value never reaches
// disk and never replaces a good one. Whether the zone actually EXISTS in the
// image is checked where it is rendered (etcidentity.ApplyTimezone), against the
// root being rendered into. An empty value is a no-op: absence from the envelope
// (an older platform, or nothing declared) is not a clearance, so an already
// rendered zone is never reverted by silence.
func persistAssignedTimezone(name string) {
	name = strings.TrimSpace(name)
	if name == "" || !etcidentity.ValidTimezoneName(name) {
		return
	}
	if cur, err := os.ReadFile(assignedTimezonePath); err == nil && strings.TrimSpace(string(cur)) == name {
		return
	}
	if err := os.MkdirAll(filepath.Dir(assignedTimezonePath), 0o755); err != nil {
		return
	}
	_ = os.WriteFile(assignedTimezonePath, []byte(name+"\n"), 0o644)
}

// desiredTimezone returns the timezone the platform declared for this node, or ""
// when none was. Callers pass the result to etcidentity.ApplyTimezone, which
// no-ops on "": a node with nothing declared keeps whatever zone it has (the
// agent never invents one).
func desiredTimezone() string {
	raw, err := os.ReadFile(assignedTimezonePath)
	if err != nil {
		return ""
	}
	name := strings.TrimSpace(string(raw))
	if !etcidentity.ValidTimezoneName(name) {
		return ""
	}
	return name
}

// renderTimezoneInto renders the declared timezone into a composed union (the pivot
// sysroot), file-only like the hostname: systemd in the union reads /etc/localtime
// at boot. A no-op when none is declared; a refusal (a zone the image lacks) is
// reported as compose:timezone_write and never fails the compose.
func (r *Reconciler) renderTimezoneInto(sysroot string) {
	tz := desiredTimezone()
	if tz == "" {
		return
	}
	if _, err := etcidentity.ApplyTimezone(sysroot, tz); err != nil {
		r.cfg.OnError("compose:timezone_write", err)
	}
}
