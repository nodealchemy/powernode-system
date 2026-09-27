package security

import (
	"context"
	"fmt"
	"path/filepath"
	"sort"
	"strconv"
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

// IsFullCapabilitySet reports whether allow, once normalized and
// deduplicated, is EXACTLY security.KnownCapabilities — the full set the
// agent recognizes, not merely "a large subset" or "the default given no
// ceiling". Used by the pivot-compose fail-closed guard (IMP-caef5c00d63f
// phase 3, review MEDIUM-1): a capabilities.conf write failure for a unit
// whose resolved ceiling is already the full set changes nothing
// security-wise — systemd's own un-dropped default bounding set for a
// root-run unit is the practical equivalent — so refusing to enable it (e.g.
// qemu-guest-agent, this self-hosted control plane's host-root recovery
// channel) would cost a real capability for no confinement benefit, while a
// node-wide write failure (ENOSPC/EROFS) very likely also affects a
// genuinely-confined sibling unit in the same tick.
//
// Deliberately exact, not "close enough": len(allow) must equal
// len(KnownCapabilities) AND every entry normalize to a distinct known name,
// so neither an unknown name nor a duplicate (which would otherwise let a
// shorter, wrong list satisfy a naive length check) can pass. A caller must
// not read this as "any sufficiently large ceiling is exempt" — a module
// whose manifest declares 38 of the 41 known capabilities is NOT exempt, and
// must not be treated as if it were.
func IsFullCapabilitySet(allow []string) bool {
	if len(allow) != len(KnownCapabilities) {
		return false
	}
	seen := make(map[string]struct{}, len(allow))
	for _, c := range allow {
		name, ok := normalizeCapName(c)
		if !ok {
			return false
		}
		seen[name] = struct{}{}
	}
	return len(seen) == len(KnownCapabilities)
}

// capabilityBits maps each KnownCapabilities name to its fixed kernel bit
// index (linux/capability.h — a stable ABI, never renumbered). Round Y
// (IMP-caef5c00d63f): CapabilityMask/ParseProcCapMask use this to compare a
// module's DECLARED capability set against a running process's actual
// CapBnd/CapAmb bitmask read from /proc/<pid>/status — the acceptance-level
// staleness signal the design chose over any clock/mtime/reload-ordering
// proxy (all of which the design doc's own section 1 rejects: mtime isn't
// refreshed on an identical rewrite but boot compose can predate NTP in the
// initramfs, ActiveEnterTimestamp has the same clock problem and an
// ordering false negative, and CapabilityBoundingSet= via `systemctl show`
// reports the manager's loaded config, not what the process actually
// holds). A test pins this map's keys identical to KnownCapabilities' own,
// so the two can never silently drift apart.
var capabilityBits = map[string]uint{
	"CAP_CHOWN":              0,
	"CAP_DAC_OVERRIDE":       1,
	"CAP_DAC_READ_SEARCH":    2,
	"CAP_FOWNER":             3,
	"CAP_FSETID":             4,
	"CAP_KILL":               5,
	"CAP_SETGID":             6,
	"CAP_SETUID":             7,
	"CAP_SETPCAP":            8,
	"CAP_LINUX_IMMUTABLE":    9,
	"CAP_NET_BIND_SERVICE":   10,
	"CAP_NET_BROADCAST":      11,
	"CAP_NET_ADMIN":          12,
	"CAP_NET_RAW":            13,
	"CAP_IPC_LOCK":           14,
	"CAP_IPC_OWNER":          15,
	"CAP_SYS_MODULE":         16,
	"CAP_SYS_RAWIO":          17,
	"CAP_SYS_CHROOT":         18,
	"CAP_SYS_PTRACE":         19,
	"CAP_SYS_PACCT":          20,
	"CAP_SYS_ADMIN":          21,
	"CAP_SYS_BOOT":           22,
	"CAP_SYS_NICE":           23,
	"CAP_SYS_RESOURCE":       24,
	"CAP_SYS_TIME":           25,
	"CAP_SYS_TTY_CONFIG":     26,
	"CAP_MKNOD":              27,
	"CAP_LEASE":              28,
	"CAP_AUDIT_WRITE":        29,
	"CAP_AUDIT_CONTROL":      30,
	"CAP_SETFCAP":            31,
	"CAP_MAC_OVERRIDE":       32,
	"CAP_MAC_ADMIN":          33,
	"CAP_SYSLOG":             34,
	"CAP_WAKE_ALARM":         35,
	"CAP_BLOCK_SUSPEND":      36,
	"CAP_AUDIT_READ":         37,
	"CAP_PERFMON":            38,
	"CAP_BPF":                39,
	"CAP_CHECKPOINT_RESTORE": 40,
}

// CapabilityMask ORs together the kernel bit for each name in allow (round
// Y), normalizing the same way every drop-in writer does (normalizeCapName)
// so the mask describes EXACTLY the resolved list a writer would render —
// never a superset or subset of it. Errors on any name normalizeCapName
// rejects, mirroring RenderCapabilityDropInBody's own validation.
func CapabilityMask(allow []string) (uint64, error) {
	var mask uint64
	for _, c := range allow {
		name, ok := normalizeCapName(c)
		if !ok {
			return 0, fmt.Errorf("CapabilityMask: unknown capability %q", c)
		}
		bit, ok := capabilityBits[name]
		if !ok {
			// Unreachable given normalizeCapName only ever returns a name
			// present in KnownCapabilities, and TestCapabilityBitsMatchesKnownCapabilities
			// pins capabilityBits' own keys identical to that set — kept as
			// a defensive check, not a real path.
			return 0, fmt.Errorf("CapabilityMask: %s has no bit mapping", name)
		}
		mask |= 1 << bit
	}
	return mask, nil
}

// ParseProcCapMask parses one of /proc/<pid>/status' Cap* fields (CapInh,
// CapPrm, CapEff, CapBnd, CapAmb) — a fixed-width hex string with no "0x"
// prefix, e.g. "0000000000000000" or "000001ffffffffff" (round Y).
func ParseProcCapMask(field string) (uint64, error) {
	return strconv.ParseUint(strings.TrimSpace(field), 16, 64)
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
// legacyAmbientCapabilitiesDropInFile (W3, IMP-caef5c00d63f round W) is the
// file the RETIRED WriteAmbientCapabilityDropInAt wrote (see
// WriteCapabilityDropInAt's own doc for the history): an older compose could
// have left this behind, in the SAME <unit>.d directory the current writer
// targets, declaring its own AmbientCapabilities= directive independently of
// the one capabilities.conf itself already sets. "ambient-capabilities.conf"
// sorts alphabetically BEFORE "capabilities.conf", so systemd loads and
// applies capabilities.conf's own directive SECOND — a coexisting legacy
// file is not a live security hole for a unit that has a current
// capabilities.conf too, but it is stale cruft: it lingers forever once
// written (nothing else ever re-writes or removes it), reads as a second,
// independently-maintained source of truth for the SAME directive, and
// would matter for real the moment either file's own load order or content
// assumptions ever change. Cleaned up here, not left to a separate one-time
// migration, for the same reason RemoveCapabilityDropIn's own R7 hygiene
// exists: nothing else in this codebase ever revisits an already-attached
// unit's drop-in directory on its own.
const legacyAmbientCapabilitiesDropInFile = "ambient-capabilities.conf"

// removeLegacyAmbientDropIn deletes legacyAmbientCapabilitiesDropInFile from
// dropInDir if present. Absence is success, same as removeDropInFile's own
// doc.
//
// X6 (IMP-caef5c00d63f round X, HIGH, B1 — delta on W3): NO LONGER called
// from inside WriteCapabilityDropIn(At)/RemoveCapabilityDropIn(At)
// themselves. It used to be, merging its own error into that of the
// PRIMARY capabilities.conf write/remove — which meant a failure removing
// this purely-cosmetic legacy file (e.g. it exists as a non-empty
// directory, not a regular file) discarded a SUCCESSFUL primary write's own
// changed=true and reported the whole call as failed. The caller
// (applyModuleSecurityDropIns, security_dropins.go) treats any such error as
// fail-closed: the module is refused (re)attach/start entirely — including
// the restart that would have applied the primary write's own already-
// on-disk, already-narrower capabilities.conf to the running process. Net
// effect: the unit keeps running under its OLD, WIDER capabilities
// indefinitely, specifically BECAUSE the narrowing write's own success was
// thrown away by an unrelated cleanup failure. RemoveLegacyAmbientCapabilityDropIn(At)
// below are the exported wrappers applyModuleSecurityDropIns now calls as
// their OWN independent, non-fatal step — same treatment the privileged
// branch's removeSeccomp/removeCapability calls already get there.
func removeLegacyAmbientDropIn(dropInDir string) (changed bool, err error) {
	return removeDropInFile(dropInDir, legacyAmbientCapabilitiesDropInFile)
}

// RemoveLegacyAmbientCapabilityDropIn is removeLegacyAmbientDropIn's
// exported, live-reconcile-rooted entry point (X6) — the counterpart to
// WriteCapabilityDropIn's own systemdDropInRoot resolution, so
// applyModuleSecurityDropIns can run this cleanup as an independent step
// instead of it being merged into the primary write/remove call's own
// error.
func RemoveLegacyAmbientCapabilityDropIn(unit string) (changed bool, err error) {
	if err := validateDropInUnitName("RemoveLegacyAmbientCapabilityDropIn", unit); err != nil {
		return false, err
	}
	return removeLegacyAmbientDropIn(filepath.Join(systemdDropInRoot, unit+".d"))
}

// RemoveLegacyAmbientCapabilityDropInAt is RemoveLegacyAmbientCapabilityDropIn's
// pivot-compose (explicit-root) counterpart (X6).
func RemoveLegacyAmbientCapabilityDropInAt(root, unit string) (changed bool, err error) {
	if err := validateDropInUnitName("RemoveLegacyAmbientCapabilityDropInAt", unit); err != nil {
		return false, err
	}
	return removeLegacyAmbientDropIn(filepath.Join(root, "etc", "systemd", "system", unit+".d"))
}

// Empty allow list -> bounding set explicitly empty (drop everything).
// The service's process and all its descendants run with NO ambient or
// bounding capabilities — strictest possible posture for unknown modules.
//
// Caller must invoke systemctl daemon-reload after writing drop-ins.
//
// changed (W1, IMP-caef5c00d63f round W) reports whether the on-disk bytes
// actually differed — see writeDropInFile's own doc for why this matters: a
// capability-only change moves NO unit body at all, so a caller deciding
// whether a RUNNING unit needs restarting has nothing else to go on. THIS
// function's own changed/err describe ONLY the primary capabilities.conf
// write — X6 (round X) moved the legacy ambient-capabilities.conf cleanup
// out to RemoveLegacyAmbientCapabilityDropIn, called as its own independent,
// non-fatal step by applyModuleSecurityDropIns, precisely so a failure
// removing that unrelated legacy file can never discard THIS write's own
// success (see removeLegacyAmbientDropIn's own doc for the outage that
// merging them caused).
func WriteCapabilityDropIn(unit string, allow []string) (changed bool, err error) {
	if err := validateDropInUnitName("WriteCapabilityDropIn", unit); err != nil {
		return false, err
	}

	body, err := RenderCapabilityDropInBody(allow)
	if err != nil {
		return false, fmt.Errorf("WriteCapabilityDropIn: %w", err)
	}

	dropInDir := filepath.Join(systemdDropInRoot, unit+".d")
	changed, err = writeDropInFile(dropInDir, "capabilities.conf", body)
	if err != nil {
		return false, fmt.Errorf("WriteCapabilityDropIn: %w", err)
	}
	return changed, nil
}

// RemoveCapabilityDropIn removes THIS unit's capabilities.conf, if any (R7,
// review round 14, hygiene): a unit becoming privileged opts out of the
// capability WRITE entirely (applyModuleSecurityDropIns' own `continue`) —
// without this, a STALE capabilities.conf from a PRIOR non-privileged state
// keeps narrowing the unit below what "privileged" is supposed to mean,
// forever, since nothing ever re-writes OR removes it once that branch is
// taken. Absence is success — see removeDropInFile's own doc. X6 (round X):
// the legacy ambient-capabilities.conf cleanup lives in
// RemoveLegacyAmbientCapabilityDropIn, its own independent step, not merged
// into this function's own return.
func RemoveCapabilityDropIn(unit string) (changed bool, err error) {
	if err := validateDropInUnitName("RemoveCapabilityDropIn", unit); err != nil {
		return false, err
	}
	dropInDir := filepath.Join(systemdDropInRoot, unit+".d")
	changed, err = removeDropInFile(dropInDir, "capabilities.conf")
	if err != nil {
		return false, err
	}
	return changed, nil
}

// RemoveCapabilityDropInAt is RemoveCapabilityDropIn's pivot-compose
// counterpart, mirroring WriteCapabilityDropInAt's own explicit-root
// targeting. X6 (round X): same as RemoveCapabilityDropIn — legacy cleanup
// is RemoveLegacyAmbientCapabilityDropInAt's own independent step.
func RemoveCapabilityDropInAt(root, unit string) (changed bool, err error) {
	if err := validateDropInUnitName("RemoveCapabilityDropInAt", unit); err != nil {
		return false, err
	}
	dropInDir := filepath.Join(root, "etc", "systemd", "system", unit+".d")
	changed, err = removeDropInFile(dropInDir, "capabilities.conf")
	if err != nil {
		return false, err
	}
	return changed, nil
}

// RenderCapabilityDropInBody is WriteCapabilityDropIn's file body, factored
// out to a pure function so RenderedPolicyHash (policy_stamp.go) and the
// writer share exactly one render — the same reason RenderUnitModeGraph
// feeds both the unit-body writer and RenderedServicesHash (IMP-f5c0afa7183a).
// A stamp computed independently of this function would describe the
// CAPABILITY LIST, not the bytes the writer actually produces, and could go
// stale the moment this rendering logic itself changes without the list
// changing — the same defect class one layer over.
func RenderCapabilityDropInBody(allow []string) (string, error) {
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
// counterpart: it renders the SAME drop-in body (RenderCapabilityDropInBody —
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
func WriteCapabilityDropInAt(root, unit string, allow []string) (changed bool, err error) {
	if err := validateDropInUnitName("WriteCapabilityDropInAt", unit); err != nil {
		return false, err
	}

	body, err := RenderCapabilityDropInBody(allow)
	if err != nil {
		return false, fmt.Errorf("WriteCapabilityDropInAt: %w", err)
	}

	dropInDir := filepath.Join(root, "etc", "systemd", "system", unit+".d")
	changed, err = writeDropInFile(dropInDir, "capabilities.conf", body)
	if err != nil {
		return false, fmt.Errorf("WriteCapabilityDropInAt: %w", err)
	}
	return changed, nil
}
