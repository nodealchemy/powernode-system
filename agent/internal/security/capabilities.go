package security

import (
	"context"
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

// validateDropInUnitName is the ONE unit-name guard shared by every
// capability drop-in writer (WriteCapabilityDropIn and its explicit-root
// counterpart WriteCapabilityDropInAt) — restored as a shared helper (review
// round, IMP-caef5c00d63f phase 2) after the two had drifted into duplicate
// copies of the same three checks. caller names the function in the returned
// error, matching each writer's own prior error-message prefix exactly so no
// caller (or test) observing the message text sees a behavior change.
func validateDropInUnitName(caller, unit string) error {
	if unit == "" {
		return fmt.Errorf("%s: empty unit", caller)
	}
	if strings.ContainsAny(unit, "/\\\x00") || strings.Contains(unit, "..") {
		return fmt.Errorf("%s: invalid unit name (path traversal)", caller)
	}
	if strings.HasPrefix(unit, "-") {
		return fmt.Errorf("%s: invalid unit name (leading dash)", caller)
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
	if err := validateDropInUnitName("WriteCapabilityDropIn", unit); err != nil {
		return err
	}

	body, err := renderCapabilityDropInBody(allow)
	if err != nil {
		return fmt.Errorf("WriteCapabilityDropIn: %w", err)
	}

	dropInDir := filepath.Join(systemdDropInRoot, unit+".d")
	if err := os.MkdirAll(dropInDir, 0o755); err != nil {
		return fmt.Errorf("WriteCapabilityDropIn: mkdir %s: %w", dropInDir, err)
	}

	dropInPath := filepath.Join(dropInDir, "capabilities.conf")
	tmp := dropInPath + ".tmp"
	if err := os.WriteFile(tmp, []byte(body), 0o644); err != nil {
		return fmt.Errorf("WriteCapabilityDropIn: write tmp: %w", err)
	}
	if err := os.Rename(tmp, dropInPath); err != nil {
		_ = os.Remove(tmp)
		return fmt.Errorf("WriteCapabilityDropIn: rename: %w", err)
	}
	return nil
}

// renderCapabilityDropInBody is WriteCapabilityDropIn's file body, factored
// out to a pure function so RenderedPolicyHash (policy_stamp.go) and the
// writer share exactly one render — the same reason RenderUnitModeGraph
// feeds both the unit-body writer and RenderedServicesHash (IMP-f5c0afa7183a).
// A stamp computed independently of this function would describe the
// CAPABILITY LIST, not the bytes the writer actually produces, and could go
// stale the moment this rendering logic itself changes without the list
// changing — the same defect class one layer over.
func renderCapabilityDropInBody(allow []string) (string, error) {
	canonical := make([]string, 0, len(allow))
	seen := make(map[string]struct{}, len(allow))
	for _, cap := range allow {
		name, ok := normalizeCapName(cap)
		if !ok {
			return "", fmt.Errorf("unknown capability %q", cap)
		}
		// De-duplicated after normalization (review P4): cap_chown and
		// CAP_CHOWN, or a name listed twice, render one entry, so a no-op
		// manifest edit cannot move RenderedPolicyHash and force a re-attach.
		if _, dup := seen[name]; dup {
			continue
		}
		seen[name] = struct{}{}
		canonical = append(canonical, name)
	}
	sort.Strings(canonical) // stable output -> idempotent file content

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
	return body.String(), nil
}

// WriteCapabilityDropInAt is WriteCapabilityDropIn's pivot-compose
// counterpart: it renders the SAME drop-in body (renderCapabilityDropInBody —
// CapabilityBoundingSet AND AmbientCapabilities both reset then re-asserted to
// the resolved allow list) under an EXPLICIT root instead of the
// systemdDropInRoot package var, because on the direct_kernel / pivot_root
// boot path the module union becomes the OS: the drop-in must land in the
// union at `root` (= sysroot) where systemd-in-the-union reads it after
// switch_root, not the live initramfs /etc/systemd/system.
//
// IMP-caef5c00d63f phase 2 — this REPLACES the former
// WriteAmbientCapabilityDropInAt, which deliberately did NOT reset
// CapabilityBoundingSet ("the bounding-set restriction requires a per-module
// runtime-capability audit before it's safe on the pivot path"). That audit
// was this task's own deliverable 3 (survey of every modules/*/manifest.yaml).
// Its finding: the module manifests already declare the ceiling each service
// actually needs (postgres-primary/redis/vault/hub-backend/hub-worker all
// carry rationale comments establishing this), EXCEPT qemu-guest-agent and
// (found independently, in review) claude-tmux/grok-cli's credential units —
// all three corrected on their own manifests (qemu-guest-agent: the full
// known capability set, non-privileged, since privileged: true is refused by
// an account's privileged_module_ids allowlist it may not be on; claude-tmux/
// grok-cli: the exact CAP_CHOWN/CAP_DAC_OVERRIDE/CAP_FOWNER their credential
// scripts use, established by reading each line by line and confirmed by
// reproduction). See each manifest's own security block for the specifics.
//
// Empty allow list -> bounding + ambient sets both explicitly empty (the
// strictest posture), exactly like WriteCapabilityDropIn — an absent drop-in
// would leave the unit at systemd's full default bounding set, so this is
// ALWAYS written for a non-privileged unit, never skipped for an empty list
// (mirrors reconcile.go's attachModule loop; see that loop's own comment for
// why "empty means skip" is the wrong default here).
func WriteCapabilityDropInAt(root, unit string, allow []string) error {
	if err := validateDropInUnitName("WriteCapabilityDropInAt", unit); err != nil {
		return err
	}

	body, err := renderCapabilityDropInBody(allow)
	if err != nil {
		return fmt.Errorf("WriteCapabilityDropInAt: %w", err)
	}

	dropInDir := filepath.Join(root, "etc", "systemd", "system", unit+".d")
	if err := os.MkdirAll(dropInDir, 0o755); err != nil {
		return fmt.Errorf("WriteCapabilityDropInAt: mkdir %s: %w", dropInDir, err)
	}

	dropInPath := filepath.Join(dropInDir, "capabilities.conf")
	tmp := dropInPath + ".tmp"
	if err := os.WriteFile(tmp, []byte(body), 0o644); err != nil {
		return fmt.Errorf("WriteCapabilityDropInAt: write tmp: %w", err)
	}
	if err := os.Rename(tmp, dropInPath); err != nil {
		_ = os.Remove(tmp)
		return fmt.Errorf("WriteCapabilityDropInAt: rename: %w", err)
	}
	return nil
}
