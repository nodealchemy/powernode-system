package storage

import (
	"context"
	"fmt"
	"os/exec"
	"strconv"
)

// ChownTask is the payload for command `storage.chown`. Dispatched to
// the provider node (NFS/SMB server, or the consuming node for local
// block volumes) when the operator changes the owner of a
// StorageAssignment via the system_assign_storage_owner MCP tool.
//
// The agent walks the mount and rewrites file ownership from
// OldUID/OldGID to NewUID/NewGID. UID and GID are handled independently
// so a chown that only changes one doesn't unnecessarily rewrite the
// other (which would be both wasteful on huge volumes and surprising
// when an operator only wanted a group change).
//
// On success the agent POSTs to CallbackPath with status=complete; on
// failure with status=failed + error_message. The platform-side
// callback at /api/v1/system/worker_api/storage/chown_complete
// transitions the assignment's chown_state and re-renders NFS exports.
//
// Mirrors the Ruby-side payload built by
// System::Storage::ChownDispatchService#payload — keep the field
// names in sync if either side changes.
type ChownTask struct {
	StorageAssignmentID string `json:"storage_assignment_id"`
	MountPath           string `json:"mount_path"`
	OldUID              int    `json:"old_uid"`
	OldGID              int    `json:"old_gid"`
	NewUID              int    `json:"new_uid"`
	NewGID              int    `json:"new_gid"`
	CallbackPath        string `json:"callback_path"`
	PreserveSymlinks    bool   `json:"preserve_symlinks"`
}

// ApplyChown rewrites ownership of files matching the old UID/GID
// under MountPath. UID and GID are chowned independently (separate
// find passes) so a no-op change on one axis doesn't touch the other.
//
// Returns nil on success, an error describing the failed exec.Command
// on failure. Per-file errors abort the whole pass — the operator can
// retry via system_storage_chown_retry once the underlying problem is
// fixed (e.g., a file with the immutable attribute).
//
// Safety: refuses to chown when MountPath is empty or "/" to prevent
// catastrophic mistakes. Refuses no-op tasks where OldUID == NewUID
// AND OldGID == NewGID (caller should have skipped the dispatch).
func ApplyChown(ctx context.Context, task *ChownTask) error {
	if task == nil {
		return fmt.Errorf("storage.chown: nil task")
	}
	if task.MountPath == "" || task.MountPath == "/" {
		return fmt.Errorf("storage.chown: refusing dangerous mount_path %q", task.MountPath)
	}
	if task.OldUID == task.NewUID && task.OldGID == task.NewGID {
		return nil // no-op
	}

	// UID pass: only if UID actually changed. -h preserves symlink
	// targets when PreserveSymlinks is true (avoid following dangling
	// links). The `--no-dereference` flag on chown achieves the same.
	if task.OldUID != task.NewUID {
		args := []string{task.MountPath, "-xdev", "-uid", strconv.Itoa(task.OldUID),
			"-exec", "chown"}
		if task.PreserveSymlinks {
			args = append(args, "--no-dereference")
		}
		args = append(args, strconv.Itoa(task.NewUID), "{}", "+")
		if err := runFind(ctx, args); err != nil {
			return fmt.Errorf("storage.chown UID %d->%d on %s: %w",
				task.OldUID, task.NewUID, task.MountPath, err)
		}
	}

	// GID pass: only if GID actually changed.
	if task.OldGID != task.NewGID {
		args := []string{task.MountPath, "-xdev", "-gid", strconv.Itoa(task.OldGID),
			"-exec", "chgrp"}
		if task.PreserveSymlinks {
			args = append(args, "--no-dereference")
		}
		args = append(args, strconv.Itoa(task.NewGID), "{}", "+")
		if err := runFind(ctx, args); err != nil {
			return fmt.Errorf("storage.chown GID %d->%d on %s: %w",
				task.OldGID, task.NewGID, task.MountPath, err)
		}
	}

	return nil
}

// runFind is broken out so tests can stub the actual exec call by
// passing a fake runner. In production it's just exec.CommandContext.
var runFind = func(ctx context.Context, args []string) error {
	cmd := exec.CommandContext(ctx, "find", args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s: %w", string(out), err)
	}
	return nil
}
