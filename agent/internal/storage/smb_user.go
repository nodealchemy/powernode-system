package storage

import (
	"context"
	"fmt"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// ApplySambaUser shells out to samba-tool for per-instance user
// management. Runs on the backend peer (Shape 1: storage host;
// Shape 2: gateway). Idempotent: create on an existing user updates
// the password; delete on a missing user is a no-op.
func ApplySambaUser(ctx context.Context, runner mount.Runner, task *SmbUserApplyTask) error {
	switch task.Action {
	case "create":
		return createSambaUser(ctx, runner, task)
	case "delete":
		return deleteSambaUser(ctx, runner, task)
	case "set_password":
		return setSambaPassword(ctx, runner, task)
	default:
		return fmt.Errorf("unknown samba action: %s", task.Action)
	}
}

func createSambaUser(ctx context.Context, runner mount.Runner, task *SmbUserApplyTask) error {
	// samba-tool exits non-zero if the user already exists; we treat
	// that as "make sure password matches" rather than fatal.
	err := runner.Run(ctx, "samba-tool", "user", "create", task.Username, task.Password)
	if err != nil {
		// Fall through to set_password if create failed (existing user).
		return runner.Run(ctx, "samba-tool", "user", "setpassword", task.Username, "--newpassword="+task.Password)
	}
	return nil
}

func deleteSambaUser(ctx context.Context, runner mount.Runner, task *SmbUserApplyTask) error {
	// Best-effort — missing user is fine.
	_ = runner.Run(ctx, "samba-tool", "user", "delete", task.Username)
	return nil
}

func setSambaPassword(ctx context.Context, runner mount.Runner, task *SmbUserApplyTask) error {
	pw := task.NewPassword
	if pw == "" {
		pw = task.Password
	}
	return runner.Run(ctx, "samba-tool", "user", "setpassword", task.Username, "--newpassword="+pw)
}
