package runtime

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"strings"

	"github.com/nodealchemy/powernode-system/agent/internal/bootslots"
	"github.com/nodealchemy/powernode-system/agent/internal/lifecycle"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// This file is the middle rung of the recompose ladder:
//
//	hot materialize   — hotreconcile/hotprune/hotleaver; per-module service
//	                    impact only; refused for reboot_required modules and
//	                    scratch-budget breaches
//	SOFT-REBOOT       — this file: compose the desired set at /run/nextroot,
//	                    `systemctl soft-reboot` into it; userspace-only
//	                    restart (seconds), same kernel, no bootloader, no
//	                    initramfs, no re-enrollment
//	full reboot       — the A/B boot-image path, unchanged
//
// The soft-reboot tier exists for exactly the changes the hot tier refuses:
// reboot_required layers (base-os) and materializations too large for the
// scratch tmpfs. The union is composed by the SAME ComposeForPivot the cold
// boot path uses — at mount.NextrootLayout's sysroot with its own scratch —
// so what soft-reboot switches into is bit-for-bit what a cold boot would
// have composed.
//
// LKG interplay: a soft-reboot does not change the kernel boot ID, so the
// LKG capturer's stale-breadcrumb check cannot distinguish "prepared and
// executed" from "prepared and abandoned". The prepare path therefore
// captures the breadcrumb via ReconcilerConfig.BreadcrumbSink instead of
// letting ComposeForPivot write it; the CLI commits it to disk only at
// execute time, immediately before invoking soft-reboot. A/B slot state is
// untouched — preflight refuses while an unproven slot upgrade is armed.

// MinSoftRebootSystemd is the first systemd release shipping
// `systemctl soft-reboot` (v254; the noble base image carries 255+).
const MinSoftRebootSystemd = 254

// CriticalSoftRebootMounts are mounts whose disappearance across a
// soft-reboot leaves the node unrecoverable, so the preflight refuses
// unless each is configured to survive.
//
// /persist carries the enrolled mTLS PKI, the boot LKG + pending-compose
// state, the module blob cache, and the durable /var bind. A node that
// soft-reboots without it comes up with no identity and no durable state
// — and on a self-hosted control plane it cannot re-enroll, because the
// platform it would enroll against is the node itself.
//
// WHY THIS IS /persist AND NOT run-nextroot-persist.mount. prepareNextrootMounts
// notes that /persist reaches the new root SOLELY via that bind, which reads like
// an argument for checking the bind instead. It is not, and the reasoning that it
// would be rested on a premise that is FALSE. Measured on a scratch VM (systemd
// 255, 2026-08-11), two soft-reboots with /persist on a loop device and a
// non-recursive bind at /run/nextroot/persist:
//
//	stock persist.mount (DefaultDependencies=yes, Conflicts=umount.target):
//	  "Unmounting persist.mount" -> the ext4 superblock is released -> the CARRIER
//	  goes with it ("run-nextroot-persist.mount: Deactivated successfully", with no
//	  Unmounting line of its own). /persist absent afterwards. The claim that a bind
//	  survives its source being unmounted, so tearing down persist.mount is
//	  harmless, does not hold here.
//	persist.mount + DefaultDependencies=no drop-in:
//	  both /persist and the carrier survive; the marker file is readable afterwards.
//
// So the carrier's fate FOLLOWS persist.mount's in both directions, which makes
// /persist the correct thing to check. Checking the carrier instead would be a
// regression, not a fix: its unit is generated from mountinfo under /run, and it
// reported DefaultDependencies=yes in BOTH runs — including the run where /persist
// demonstrably survived. A guard keyed on it therefore refuses unconditionally and
// disables the soft-reboot tier permanently. Do not "fix" this list to the bind;
// TestCriticalSoftRebootMounts_IsPersistNotTheNextrootCarrier fails if you do.
//
// Bound on the evidence: the scratch VM's /run/nextroot was a bind of /, and no
// switch-root line appeared in the journal, so this measures the umount.target
// survival semantics — the open question — and not a full root swap. Separately,
// mounts under /run on that VM reported an EMPTY Conflicts, which contradicts the
// pivot-node reading that run-powernode-scratch.mount and the module mounts carry
// Conflicts=umount.target; that discrepancy is unresolved and filed separately.
var CriticalSoftRebootMounts = []string{"/persist"}

// mountSurvivesSoftReboot reports whether the mount unit backing path is
// configured to stay mounted through the shutdown phase of a soft-reboot.
//
// This is NOT the default. systemd-soft-reboot.service documents that
// "/run/ file system remains mounted", but that other mounts survive only
// if "configured to remain until the very end of the shutdown process" —
// i.e. DefaultDependencies=no and no Conflicts=umount.target. A stock
// fleet node's persist.mount has DefaultDependencies=yes AND
// Conflicts=umount.target (verified on a live pivot node 2026-08-07), so
// it is torn down like any other filesystem.
//
// A unit systemctl does not know (empty output) is reported as NOT
// surviving: unknown means unproven, and the failure mode here is losing
// the node.
func mountSurvivesSoftReboot(ctx context.Context, run mount.Runner, path string) (bool, string) {
	unit := MountUnitName(path)
	out, err := run.Output(ctx, "systemctl", "show", unit,
		"-p", "DefaultDependencies", "-p", "Conflicts", "-p", "LoadState")
	if err != nil {
		return false, fmt.Sprintf("could not query %s: %v", unit, err)
	}
	fields := map[string]string{}
	for _, line := range strings.Split(string(out), "\n") {
		k, v, ok := strings.Cut(strings.TrimSpace(line), "=")
		if ok {
			fields[k] = v
		}
	}
	if len(fields) == 0 || fields["LoadState"] == "not-found" {
		return false, fmt.Sprintf("%s is unknown to systemd — cannot prove it survives", unit)
	}
	var reasons []string
	if !strings.EqualFold(fields["DefaultDependencies"], "no") {
		reasons = append(reasons, "DefaultDependencies is not 'no'")
	}
	if strings.Contains(fields["Conflicts"], "umount.target") {
		reasons = append(reasons, "it Conflicts=umount.target")
	}
	if len(reasons) > 0 {
		return false, fmt.Sprintf("%s: %s", unit, strings.Join(reasons, " and "))
	}
	return true, ""
}

// MountUnitName renders a path as its systemd mount-unit name using
// systemd's own escaping ("/" -> "-", "-" -> "\x2d", other specials
// hex-escaped), so "/persist" -> "persist.mount".
func MountUnitName(path string) string {
	trimmed := strings.Trim(path, "/")
	if trimmed == "" {
		return "-.mount"
	}
	var b strings.Builder
	for i := 0; i < len(trimmed); i++ {
		c := trimmed[i]
		switch {
		case c == '/':
			b.WriteByte('-')
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9', c == '_':
			b.WriteByte(c)
		case c == '.' && i > 0:
			b.WriteByte(c)
		default:
			fmt.Fprintf(&b, `\x%02x`, c)
		}
	}
	return b.String() + ".mount"
}

// pendingBootSlot indirects bootslots.Load for tests.
var pendingBootSlot = func() string { return bootslots.Load().Pending }

// SystemdVersion parses `systemctl --version` ("systemd 255 (255.4-…)").
func SystemdVersion(ctx context.Context, run mount.Runner) (int, error) {
	out, err := run.Output(ctx, "systemctl", "--version")
	if err != nil {
		return 0, fmt.Errorf("systemctl --version: %w", err)
	}
	first := strings.SplitN(strings.TrimSpace(string(out)), "\n", 2)[0]
	fields := strings.Fields(first)
	if len(fields) < 2 || fields[0] != "systemd" {
		return 0, fmt.Errorf("unrecognized systemctl --version output %q", first)
	}
	v, aerr := strconv.Atoi(fields[1])
	if aerr != nil {
		return 0, fmt.Errorf("unrecognized systemd version %q: %w", fields[1], aerr)
	}
	return v, nil
}

// SoftRecomposePreflight verifies this node can soft-recompose at all.
// Refusals are errors so the CLI stops before composing anything.
func SoftRecomposePreflight(ctx context.Context, run mount.Runner) error {
	if pivotAwareRootMode() != lifecycle.RootModeNative {
		return errors.New("soft-recompose only applies to pivot-booted nodes — on this boot model the union is remounted live on every stack change, so there is nothing a soft-reboot would fix")
	}
	v, err := SystemdVersion(ctx, run)
	if err != nil {
		return fmt.Errorf("probe systemd version: %w", err)
	}
	if v < MinSoftRebootSystemd {
		return fmt.Errorf("systemd %d has no soft-reboot support (need >= %d)", v, MinSoftRebootSystemd)
	}
	if p := pendingBootSlot(); p != "" {
		return fmt.Errorf("an A/B boot-image upgrade is armed (pending slot %q, unproven) — a soft-reboot skips the bootloader, so it would neither boot the pending slot nor exercise the bless-or-rollback flow; let the upgrade resolve first", p)
	}
	for _, path := range CriticalSoftRebootMounts {
		if ok, why := mountSurvivesSoftReboot(ctx, run, path); !ok {
			return fmt.Errorf("%s is not configured to survive a soft-reboot (%s). "+
				"systemd tears down every mount except /run unless its unit sets DefaultDependencies=no and does not Conflicts=umount.target, "+
				"so soft-rebooting now would land in the new root with %s GONE — no enrolled PKI, no LKG, no durable /var. "+
				"Ship a mount drop-in that keeps it to the end of shutdown before using --execute; a full reboot applies the composition safely in the meantime",
				path, why, path)
		}
	}
	return nil
}
