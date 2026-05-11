package storage

import (
	"context"
	"fmt"
	"os"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// MountCIFS writes credentials to /run/sdwan/mount-creds/<id>.cred,
// appends credentials=<path> to the recipe options, writes the systemd
// unit, and starts it.
func MountCIFS(ctx context.Context, runner mount.Runner, client httpGetter, task *MountTask) error {
	if err := os.MkdirAll(task.MountPath, 0o755); err != nil {
		return fmt.Errorf("mkdir mount path %s: %w", task.MountPath, err)
	}

	payload, _, err := FetchCredential(client, task.Credential.URL)
	if err != nil {
		return fmt.Errorf("fetch CIFS credential: %w", err)
	}
	credPath, err := WriteCIFSCredentialFile(task.Credential.ID, payload)
	if err != nil {
		return err
	}

	// Append credentials= option; the platform deliberately leaves it
	// out of the recipe to keep secret-handling agent-side.
	task.Options = append(task.Options, "credentials="+credPath)

	if err := WriteMountUnit(ctx, runner, task); err != nil {
		return err
	}
	return StartMountUnit(ctx, runner, task.UnitName)
}

// UnmountCIFS stops the unit and cleans up the credential file.
func UnmountCIFS(ctx context.Context, runner mount.Runner, task *UnmountTask, credID string) error {
	if err := StopAndRemoveMountUnit(ctx, runner, task.UnitName); err != nil {
		return err
	}
	return RemoveCredentialFile(credID)
}
