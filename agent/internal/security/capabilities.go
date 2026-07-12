package security

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// KnownCapabilities is the canonical set of Linux capability names the
// agent recognizes. Sourced from man capabilities(7); not exhaustive but
// covers everything modules typically request. Unknown names are rejected
// at Validate time rather than at Apply time so misconfigurations surface
// before the module attempts to start.
var KnownCapabilities = map[string]struct{}{
	"CAP_AUDIT_CONTROL":      {},
	"CAP_AUDIT_READ":         {},
	"CAP_AUDIT_WRITE":        {},
	"CAP_BLOCK_SUSPEND":      {},
	"CAP_BPF":                {},
	"CAP_CHECKPOINT_RESTORE": {},
	"CAP_CHOWN":              {},
	"CAP_DAC_OVERRIDE":       {},
	"CAP_DAC_READ_SEARCH":    {},
	"CAP_FOWNER":             {},
	"CAP_FSETID":             {},
	"CAP_IPC_LOCK":           {},
	"CAP_IPC_OWNER":          {},
	"CAP_KILL":               {},
	"CAP_LEASE":              {},
	"CAP_LINUX_IMMUTABLE":    {},
	"CAP_MAC_ADMIN":          {},
	"CAP_MAC_OVERRIDE":       {},
	"CAP_MKNOD":              {},
	"CAP_NET_ADMIN":          {},
	"CAP_NET_BIND_SERVICE":   {},
	"CAP_NET_BROADCAST":      {},
	"CAP_NET_RAW":            {},
	"CAP_PERFMON":            {},
	"CAP_SETGID":             {},
	"CAP_SETFCAP":            {},
	"CAP_SETPCAP":            {},
	"CAP_SETUID":             {},
	"CAP_SYS_ADMIN":          {},
	"CAP_SYS_BOOT":           {},
	"CAP_SYS_CHROOT":         {},
	"CAP_SYS_MODULE":         {},
	"CAP_SYS_NICE":           {},
	"CAP_SYS_PACCT":          {},
	"CAP_SYS_PTRACE":         {},
	"CAP_SYS_RAWIO":          {},
	"CAP_SYS_RESOURCE":       {},
	"CAP_SYS_TIME":           {},
	"CAP_SYS_TTY_CONFIG":     {},
	"CAP_SYSLOG":             {},
	"CAP_WAKE_ALARM":         {},
}

func isValidCapName(name string) bool {
	_, ok := KnownCapabilities[strings.ToUpper(name)]
	return ok
}

// normalizeCapName returns the canonical CAP_FOO form for a user-supplied
// capability name. Accepts "cap_foo", "CAP_FOO", "foo", "FOO" and emits
// "CAP_FOO" — systemd's CapabilityBoundingSet wants the CAP_ prefix.
// Returns ("", false) when the name isn't in KnownCapabilities.
func normalizeCapName(name string) (string, bool) {
	upper := strings.ToUpper(strings.TrimSpace(name))
	if !strings.HasPrefix(upper, "CAP_") {
		upper = "CAP_" + upper
	}
	if _, ok := KnownCapabilities[upper]; !ok {
		return "", false
	}
	return upper, true
}

// DropCapabilitiesExcept validates the capability allowlist. Previously
// this function shelled out to capsh on /bin/true as a "pre-flight"
// test — but that test was both useless (capsh exited immediately,
// changing no on-disk or in-process state) AND broken on hosts where
// capsh's --drop=all couldn't be exec'd through (e.g. cloud VMs without
// the initramfs PR_CAP_AMBIENT setup the test implicitly assumed).
//
// The ACTUAL enforcement of per-module capabilities happens via systemd
// unit drop-ins: WriteCapabilityDropIn writes
// `CapabilityBoundingSet=` + `AmbientCapabilities=` for the module's
// service units, and systemd applies them at unit-start time. This
// function now only validates the names; the caller is expected to
// follow up with WriteCapabilityDropIn per unit (mirroring the
// WriteSeccompDropIn pattern in mac.go).
//
// `runner` is preserved in the signature for API stability with the
// older capsh-based implementation and for future use if the agent
// adds an in-process libcap-based fallback. Empty allowlist is fine
// — it means "drop everything (bounding set empty)", the safest
// default; systemd handles that case correctly.
func DropCapabilitiesExcept(ctx context.Context, runner mount.Runner, allow []string) error {
	_ = ctx
	_ = runner
	for _, cap := range allow {
		if _, ok := normalizeCapName(cap); !ok {
			return fmt.Errorf("DropCapabilitiesExcept: unknown capability %q", cap)
		}
	}
	return nil
}

// WriteCapabilityDropIn renders a systemd drop-in that constrains the
// unit's capability bounding set + ambient capabilities to the supplied
// allowlist. Mirrors WriteSeccompDropIn (mac.go) — same drop-in dir
// layout, same path-traversal guards, same atomic write semantics.
//
// File path: /etc/systemd/system/<unit>.d/capabilities.conf
//
// Drop-in shape (per systemd.exec(5)):
//
//	[Service]
//	# Reset bounding set so the manifest values are exhaustive, not additive
//	# w.r.t. systemd's own defaults.
//	CapabilityBoundingSet=
//	CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_CHOWN
//	AmbientCapabilities=
//	AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_CHOWN
//
// Empty allow list -> bounding set explicitly empty (drop everything).
// The service's process and all its descendants run with NO ambient or
// bounding capabilities — strictest possible posture for unknown modules.
//
// Caller must invoke systemctl daemon-reload after writing drop-ins.
func WriteCapabilityDropIn(unit string, allow []string) error {
	if unit == "" {
		return errors.New("WriteCapabilityDropIn: empty unit")
	}
	if strings.ContainsAny(unit, "/\\\x00") || strings.Contains(unit, "..") {
		return errors.New("WriteCapabilityDropIn: invalid unit name (path traversal)")
	}
	if strings.HasPrefix(unit, "-") {
		return errors.New("WriteCapabilityDropIn: invalid unit name (leading dash)")
	}

	canonical := make([]string, 0, len(allow))
	for _, cap := range allow {
		name, ok := normalizeCapName(cap)
		if !ok {
			return fmt.Errorf("WriteCapabilityDropIn: unknown capability %q", cap)
		}
		canonical = append(canonical, name)
	}
	sort.Strings(canonical) // stable output -> idempotent file content

	dropInDir := filepath.Join(systemdDropInRoot, unit+".d")
	if err := os.MkdirAll(dropInDir, 0o755); err != nil {
		return fmt.Errorf("WriteCapabilityDropIn: mkdir %s: %w", dropInDir, err)
	}

	var body strings.Builder
	body.WriteString("# Auto-generated by powernode-agent. Capability bounding + ambient sets\n")
	body.WriteString("# constrained per the module's manifest security policy.\n")
	body.WriteString("# DO NOT EDIT BY HAND — overwritten on every reconcile.\n")
	body.WriteString("\n[Service]\n")
	body.WriteString("CapabilityBoundingSet=\n") // reset, then set explicitly below
	if len(canonical) > 0 {
		body.WriteString("CapabilityBoundingSet=")
		body.WriteString(strings.Join(canonical, " "))
		body.WriteString("\n")
		body.WriteString("AmbientCapabilities=\n")
		body.WriteString("AmbientCapabilities=")
		body.WriteString(strings.Join(canonical, " "))
		body.WriteString("\n")
	} else {
		// Explicitly empty — strictest posture.
		body.WriteString("AmbientCapabilities=\n")
	}

	dropInPath := filepath.Join(dropInDir, "capabilities.conf")
	tmp := dropInPath + ".tmp"
	if err := os.WriteFile(tmp, []byte(body.String()), 0o644); err != nil {
		return fmt.Errorf("WriteCapabilityDropIn: write tmp: %w", err)
	}
	if err := os.Rename(tmp, dropInPath); err != nil {
		_ = os.Remove(tmp)
		return fmt.Errorf("WriteCapabilityDropIn: rename: %w", err)
	}
	return nil
}

// WriteAmbientCapabilityDropInAt writes an ADDITIVE capability drop-in under an
// explicit systemd root — root/etc/systemd/system/<unit>.d/ambient-capabilities.conf
// — that raises the module's declared capabilities into the unit's AMBIENT set
// WITHOUT resetting CapabilityBoundingSet. It is the pivot-compose counterpart
// to WriteCapabilityDropIn, and differs deliberately on two axes:
//
//  1. Explicit root. On the direct_kernel / pivot_root boot path the module
//     union becomes the OS, so the drop-in must land in the union at `root`
//     (= sysroot) where systemd-in-the-union reads it after switch_root — NOT
//     the live initramfs /etc/systemd/system (the systemdDropInRoot package
//     var WriteCapabilityDropIn targets on the cloud_init path).
//  2. Grant-only, never restrict. A non-root User= service (e.g. traefik) needs
//     the capability in its AMBIENT set to actually exercise it —
//     CapabilityBoundingSet only *permits*, it does not grant, so an empty
//     ambient set is why traefik hit "listen tcp :80: bind: permission denied"
//     post-pivot. We intentionally do NOT reset CapabilityBoundingSet here (as
//     WriteCapabilityDropIn does): the bounding-set restriction requires a
//     per-module runtime-capability audit before it's safe on the pivot path —
//     root-running services (rails/sidekiq first-boot chown, qemu-guest-agent
//     exec-as-user) rely on caps they don't declare, and stripping the bounding
//     set would break them. Restriction is a follow-on hardening; the ambient
//     grant is the functional fix.
//
// Empty allow list is a no-op (ambient is empty by default) — the drop-in is
// skipped so the unit keeps systemd's defaults. Mirrors WriteCapabilityDropIn's
// name validation + normalization + atomic-write semantics.
func WriteAmbientCapabilityDropInAt(root, unit string, allow []string) error {
	if unit == "" {
		return errors.New("WriteAmbientCapabilityDropInAt: empty unit")
	}
	if strings.ContainsAny(unit, "/\\\x00") || strings.Contains(unit, "..") {
		return errors.New("WriteAmbientCapabilityDropInAt: invalid unit name (path traversal)")
	}
	if strings.HasPrefix(unit, "-") {
		return errors.New("WriteAmbientCapabilityDropInAt: invalid unit name (leading dash)")
	}

	canonical := make([]string, 0, len(allow))
	for _, cap := range allow {
		name, ok := normalizeCapName(cap)
		if !ok {
			return fmt.Errorf("WriteAmbientCapabilityDropInAt: unknown capability %q", cap)
		}
		canonical = append(canonical, name)
	}
	if len(canonical) == 0 {
		return nil // nothing to grant — leave systemd defaults
	}
	sort.Strings(canonical) // stable output -> idempotent file content

	dropInDir := filepath.Join(root, "etc", "systemd", "system", unit+".d")
	if err := os.MkdirAll(dropInDir, 0o755); err != nil {
		return fmt.Errorf("WriteAmbientCapabilityDropInAt: mkdir %s: %w", dropInDir, err)
	}

	var body strings.Builder
	body.WriteString("# Auto-generated by powernode-agent (pivot compose). Raises the module's\n")
	body.WriteString("# manifest-declared capabilities into the AMBIENT set so non-root User=\n")
	body.WriteString("# services can exercise them (e.g. traefik binding :80). Additive only —\n")
	body.WriteString("# does NOT reset CapabilityBoundingSet. DO NOT EDIT BY HAND.\n")
	body.WriteString("\n[Service]\n")
	body.WriteString("AmbientCapabilities=\n") // reset, then set explicitly below
	body.WriteString("AmbientCapabilities=")
	body.WriteString(strings.Join(canonical, " "))
	body.WriteString("\n")

	dropInPath := filepath.Join(dropInDir, "ambient-capabilities.conf")
	tmp := dropInPath + ".tmp"
	if err := os.WriteFile(tmp, []byte(body.String()), 0o644); err != nil {
		return fmt.Errorf("WriteAmbientCapabilityDropInAt: write tmp: %w", err)
	}
	if err := os.Rename(tmp, dropInPath); err != nil {
		_ = os.Remove(tmp)
		return fmt.Errorf("WriteAmbientCapabilityDropInAt: rename: %w", err)
	}
	return nil
}
