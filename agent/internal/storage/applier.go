package storage

import (
	"context"
	"fmt"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// Apply dispatches the right per-mount-type driver based on the recipe, then
// applies encryption. Ordering matters: fscrypt applies a policy to a
// directory on an already-mounted, encryption-capable filesystem, so the
// mount must succeed first. Encryption fails closed (see setupEncryption) —
// if it errors, the whole assignment fails rather than serving plaintext
// under an "encrypted" label.
func Apply(ctx context.Context, runner mount.Runner, client httpGetter, task *MountTask) error {
	// The single validation seam for storage.mount. It runs before the recipe
	// switch so no driver — and no os.MkdirAll on the caller-chosen mount
	// path — happens for a payload the agent will refuse. See validate.go.
	if err := task.Validate(); err != nil {
		return err
	}

	var mountErr error
	switch task.Recipe.Type {
	case "nfs4", "nfs":
		mountErr = mountNFS(ctx, runner, task)
	case "cifs":
		mountErr = mountCIFS(ctx, runner, client, task)
	case "s3fs", "gcsfuse", "rclone":
		mountErr = mountObject(ctx, runner, client, task)
	default:
		return fmt.Errorf("unsupported recipe type: %s", task.Recipe.Type)
	}
	if mountErr != nil {
		return mountErr
	}

	if err := setupEncryption(ctx, runner, client, task); err != nil {
		return fmt.Errorf("encryption setup: %w", err)
	}
	return nil
}

// Unapply unmounts and tears down encryption for the assignment.
// CredentialID is used to clean up the transient credential file for
// CIFS mounts; empty for NFS / object.
func Unapply(ctx context.Context, runner mount.Runner, task *UnmountTask, encryption EncryptionSpec, credentialID string) error {
	// storage.unmount is NOT storage-scoped without this: stopAndRemoveMountUnit
	// stops and deletes whatever unit the payload names. See validate.go.
	if err := task.Validate(); err != nil {
		return err
	}

	// Stop the systemd unit and clean credential files. We don't know
	// the recipe.Type at unmount time (the platform sends an
	// UnmountTask, not a MountTask), so we use a uniform path: stop
	// the unit, then remove the credential file if any.
	if err := stopAndRemoveMountUnit(ctx, runner, task.UnitName); err != nil {
		return err
	}
	if credentialID != "" {
		_ = removeCredentialFile(credentialID)
	}
	return teardownEncryption(ctx, runner, encryption)
}
