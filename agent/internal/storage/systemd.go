package storage

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// SystemdUnitDir is where we write the platform-managed .mount units.
// Distinct prefix powernode-storage-* so we can audit + clean up safely
// without touching unrelated operator units.
//
// A var rather than a const ONLY so the package's own tests can redirect
// the write into t.TempDir() and assert, on real bytes, that a crafted
// unit_name does not escape this directory. Production never reassigns it;
// the same test-seam shape as `var runFind` in chown.go.
var SystemdUnitDir = "/etc/systemd/system"

// writeMountUnit writes a systemd .mount unit for the assignment and
// reloads systemd. The unit chains After=<wg interface>.service so
// the mount only fires after the SDWAN tunnel is healthy.
func writeMountUnit(ctx context.Context, runner mount.Runner, task *MountTask) error {
	unit := renderMountUnit(task)
	path := filepath.Join(SystemdUnitDir, task.UnitName)
	if err := os.WriteFile(path, []byte(unit), 0o644); err != nil {
		return fmt.Errorf("write unit %s: %w", path, err)
	}
	if err := runner.Run(ctx, "systemctl", "daemon-reload"); err != nil {
		return fmt.Errorf("systemctl daemon-reload: %w", err)
	}
	return nil
}

// startMountUnit triggers the unit to actually mount.
func startMountUnit(ctx context.Context, runner mount.Runner, unitName string) error {
	if err := runner.Run(ctx, "systemctl", "start", unitName); err != nil {
		return fmt.Errorf("systemctl start %s: %w", unitName, err)
	}
	return nil
}

// restartMountUnit re-applies a rewritten unit file to an ALREADY-active
// .mount unit (IMP-e48612a32273) — `systemctl start` on an active unit is a
// no-op, so a credential rotation's new credentials= path/password would
// never take effect without this. `restart` is stop-then-start under the
// hood, which is systemd's own supported lifecycle op for a Type=Mount
// unit; it is also safe to call on an INACTIVE unit (stop on an inactive
// unit is a no-op), though the platform only ever asks for it once an
// assignment has been mounted before — see
// AssignmentReconciliationService#dispatch_mount!.
//
// Deliberately NOT `-l`/lazy and NOT forced: if umount(8) fails EBUSY (an
// open fd, cwd, or mmap under the mount), that failure is returned as-is
// and surfaces as a normal task failure — see cifs.go's caller. A lazy
// unmount would "succeed" while leaving in-flight I/O against a DETACHED
// mount, which for CIFS specifically is a correctness risk (silent stale
// access to a filesystem that no longer exists at that path), not merely a
// UX one. Retry-on-next-reconcile is the deliberate tradeoff; see the
// server-side "degraded" handling this failure feeds into.
func restartMountUnit(ctx context.Context, runner mount.Runner, unitName string) error {
	if err := runner.Run(ctx, "systemctl", "restart", unitName); err != nil {
		return fmt.Errorf("systemctl restart %s: %w", unitName, err)
	}
	return nil
}

// stopAndRemoveMountUnit stops the mount and removes the unit file.
func stopAndRemoveMountUnit(ctx context.Context, runner mount.Runner, unitName string) error {
	// Best-effort stop — ignore error if already inactive.
	_ = runner.Run(ctx, "systemctl", "stop", unitName)
	path := filepath.Join(SystemdUnitDir, unitName)
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("remove unit %s: %w", path, err)
	}
	return runner.Run(ctx, "systemctl", "daemon-reload")
}

func renderMountUnit(task *MountTask) string {
	var deps strings.Builder
	if task.RequiresWGInterface && task.WGInterfaceHint != "" {
		fmt.Fprintf(&deps, "Requires=%s.service\nAfter=%s.service\n", task.WGInterfaceHint, task.WGInterfaceHint)
	}

	opts := strings.Join(task.Options, ",")
	if opts == "" {
		opts = "defaults"
	}

	return fmt.Sprintf(`[Unit]
Description=Powernode-managed storage mount %s
%s
[Mount]
What=%s
Where=%s
Type=%s
Options=%s

[Install]
WantedBy=multi-user.target
`, task.AssignmentID, deps.String(), mountWhat(task), task.MountPath, mountType(task), opts)
}

// mountType / mountWhat let FUSE object mounts override the systemd fs-type /
// What without disturbing the recipe's dispatch type / source. NFS/CIFS leave
// the overrides empty and fall back to the recipe values.
func mountType(task *MountTask) string {
	if task.SystemdType != "" {
		return task.SystemdType
	}
	return task.Recipe.Type
}

func mountWhat(task *MountTask) string {
	if task.SystemdWhat != "" {
		return task.SystemdWhat
	}
	return task.Recipe.Source
}
