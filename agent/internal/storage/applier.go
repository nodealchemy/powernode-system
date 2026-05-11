package storage

import (
	"context"
	"fmt"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// Apply dispatches the right per-mount-type driver based on the recipe.
// Encryption setup runs first (when applicable) so the mount writes to
// an already-encrypted target.
func Apply(ctx context.Context, runner mount.Runner, client httpGetter, task *MountTask) error {
	if err := SetupEncryption(ctx, runner, client, task); err != nil {
		return fmt.Errorf("encryption setup: %w", err)
	}

	switch task.Recipe.Type {
	case "nfs4", "nfs":
		return MountNFS(ctx, runner, task)
	case "cifs":
		return MountCIFS(ctx, runner, client, task)
	case "s3fs", "gcsfuse", "rclone":
		return MountObject(ctx, runner, client, task)
	default:
		return fmt.Errorf("unsupported recipe type: %s", task.Recipe.Type)
	}
}

// Unapply unmounts and tears down encryption for the assignment.
// CredentialID is used to clean up the transient credential file for
// CIFS mounts; empty for NFS / object.
func Unapply(ctx context.Context, runner mount.Runner, task *UnmountTask, encryption EncryptionSpec, credentialID string) error {
	// Stop the systemd unit and clean credential files. We don't know
	// the recipe.Type at unmount time (the platform sends an
	// UnmountTask, not a MountTask), so we use a uniform path: stop
	// the unit, then remove the credential file if any.
	if err := StopAndRemoveMountUnit(ctx, runner, task.UnitName); err != nil {
		return err
	}
	if credentialID != "" {
		_ = RemoveCredentialFile(credentialID)
	}
	return TeardownEncryption(ctx, runner, encryption)
}
