package storage

import (
	"context"
	"fmt"
	"os"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// mountCIFS writes credentials to /run/sdwan/mount-creds/<id>.cred,
// appends credentials=<path> to the recipe options, writes the systemd
// unit, and starts it.
func mountCIFS(ctx context.Context, runner mount.Runner, client httpGetter, task *MountTask) error {
	if err := os.MkdirAll(task.MountPath, 0o755); err != nil {
		return fmt.Errorf("mkdir mount path %s: %w", task.MountPath, err)
	}

	payload, _, err := fetchCredential(client, task.Credential.URL)
	if err != nil {
		return fmt.Errorf("fetch CIFS credential: %w", err)
	}
	credPath, err := writeCIFSCredentialFile(task.Credential.ID, payload)
	if err != nil {
		return err
	}

	// Append credentials= option; the platform deliberately leaves it
	// out of the recipe to keep secret-handling agent-side.
	task.Options = append(task.Options, "credentials="+credPath)

	if err := writeMountUnit(ctx, runner, task); err != nil {
		return err
	}
	return startMountUnit(ctx, runner, task.UnitName)
}

// unmountCIFS stops the unit and cleans up the credential file.
func unmountCIFS(ctx context.Context, runner mount.Runner, task *UnmountTask, credID string) error {
	if err := task.Validate(); err != nil {
		return err
	}
	if err := stopAndRemoveMountUnit(ctx, runner, task.UnitName); err != nil {
		return err
	}
	return removeCredentialFile(credID)
}
