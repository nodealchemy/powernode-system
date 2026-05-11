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
const SystemdUnitDir = "/etc/systemd/system"

// WriteMountUnit writes a systemd .mount unit for the assignment and
// reloads systemd. The unit chains After=<wg interface>.service so
// the mount only fires after the SDWAN tunnel is healthy.
func WriteMountUnit(ctx context.Context, runner mount.Runner, task *MountTask) error {
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

// StartMountUnit triggers the unit to actually mount.
func StartMountUnit(ctx context.Context, runner mount.Runner, unitName string) error {
	if err := runner.Run(ctx, "systemctl", "start", unitName); err != nil {
		return fmt.Errorf("systemctl start %s: %w", unitName, err)
	}
	return nil
}

// StopAndRemoveMountUnit stops the mount and removes the unit file.
func StopAndRemoveMountUnit(ctx context.Context, runner mount.Runner, unitName string) error {
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
`, task.AssignmentID, deps.String(), task.Recipe.Source, task.MountPath, task.Recipe.Type, opts)
}
