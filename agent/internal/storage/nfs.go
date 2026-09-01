package storage

import (
	"context"
	"fmt"
	"os"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// mountNFS executes the NFS mount via systemd unit. The unit's
// Requires=wg-sdwan-*.service ensures the SDWAN tunnel is up first.
// Idempotent: if the unit is already active, this is a no-op.
func mountNFS(ctx context.Context, runner mount.Runner, task *MountTask) error {
	if err := os.MkdirAll(task.MountPath, 0o755); err != nil {
		return fmt.Errorf("mkdir mount path %s: %w", task.MountPath, err)
	}
	if err := writeMountUnit(ctx, runner, task); err != nil {
		return err
	}
	return startMountUnit(ctx, runner, task.UnitName)
}

// unmountNFS reverses mountNFS — stops the systemd unit and removes it.
func unmountNFS(ctx context.Context, runner mount.Runner, task *UnmountTask) error {
	if err := task.Validate(); err != nil {
		return err
	}
	return stopAndRemoveMountUnit(ctx, runner, task.UnitName)
}
