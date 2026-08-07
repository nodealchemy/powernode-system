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
	return nil
}
