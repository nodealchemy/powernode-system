package storage

import (
	"context"
	"fmt"
	"os"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// MountObject covers the cloud object-storage recipes — s3fs, gcsfuse,
// rclone mount. Egress uses the node's native interface, not SDWAN.
// Per-instance auth is the cloud provider's STS / WIF / SAS token.
//
// V1 fetches the credential, writes a transient config file in the
// recipe-specific format, and starts the systemd unit. Subsequent
// rotations happen via a refresh goroutine inside the FUSE driver (s3fs
// rereads on SIGHUP; rclone re-auths every TTL minus 10 min).
//
// Stubbed in v1 — the systemd unit + credentials file would still need
// per-recipe formatting (s3fs's ~/.passwd-s3fs vs rclone's --config).
// Real implementation tracked in the "object storage in node-mount flow"
// follow-up; the dispatcher still routes here so smoke tests against
// NFS aren't blocked.
func MountObject(ctx context.Context, runner mount.Runner, client httpGetter, task *MountTask) error {
	if err := os.MkdirAll(task.MountPath, 0o755); err != nil {
		return fmt.Errorf("mkdir mount path %s: %w", task.MountPath, err)
	}

	if _, _, err := FetchCredential(client, task.Credential.URL); err != nil {
		return fmt.Errorf("fetch object credential: %w", err)
	}

	// TODO(v1.1): write s3fs/.passwd-s3fs or rclone --config snippet
	// per recipe.Type, then start the systemd unit.
	return fmt.Errorf("object storage node-mount not yet implemented for recipe type %s", task.Recipe.Type)
}

// UnmountObject reverses MountObject.
func UnmountObject(ctx context.Context, runner mount.Runner, task *UnmountTask) error {
	return StopAndRemoveMountUnit(ctx, runner, task.UnitName)
}
