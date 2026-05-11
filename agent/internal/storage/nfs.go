package storage

import (
	"context"
	"fmt"
	"os"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// MountNFS executes the NFS mount via systemd unit. The unit's
// Requires=wg-sdwan-*.service ensures the SDWAN tunnel is up first.
// Idempotent: if the unit is already active, this is a no-op.
func MountNFS(ctx context.Context, runner mount.Runner, task *MountTask) error {
	if err := os.MkdirAll(task.MountPath, 0o755); err != nil {
		return fmt.Errorf("mkdir mount path %s: %w", task.MountPath, err)
	}
	if err := WriteMountUnit(ctx, runner, task); err != nil {
		return err
	}
	return StartMountUnit(ctx, runner, task.UnitName)
}

// UnmountNFS reverses MountNFS — stops the systemd unit and removes it.
func UnmountNFS(ctx context.Context, runner mount.Runner, task *UnmountTask) error {
	return StopAndRemoveMountUnit(ctx, runner, task.UnitName)
}
