package storage

import (
	"context"
	"fmt"
	"os"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/systemd"
)

// mountCIFS writes credentials to /run/sdwan/mount-creds/<id>.cred,
// appends credentials=<path> to the recipe options, writes the systemd
// unit, and starts (or, on Remount, restarts) it.
//
// The bool return (IMP-e48612a32273, rollout-skew review) is CONFIRMED —
// true only when the unit was ACTUALLY (re)started: a genuine restart, or a
// start on a unit that was INACTIVE beforehand. False when start was a
// no-op on an already-active unit — nothing happened, so the caller MUST
// NOT tell the platform this credential is now mounted. This is what
// distinguishes a real remount from an old (pre-remount-aware) agent's
// plain `start`, which is a no-op on an already-active unit yet used to
// report success unconditionally.
func mountCIFS(ctx context.Context, runner mount.Runner, client httpGetter, task *MountTask) (bool, error) {
	if err := os.MkdirAll(task.MountPath, 0o755); err != nil {
		return false, fmt.Errorf("mkdir mount path %s: %w", task.MountPath, err)
	}

	payload, _, err := fetchCredential(client, task.Credential.URL)
	if err != nil {
		return false, fmt.Errorf("fetch CIFS credential: %w", err)
	}
	credPath, err := writeCIFSCredentialFile(task.Credential.ID, payload)
	if err != nil {
		return false, err
	}

	// Append credentials= option; the platform deliberately leaves it
	// out of the recipe to keep secret-handling agent-side.
	task.Options = append(task.Options, "credentials="+credPath)

	if err := writeMountUnit(ctx, runner, task); err != nil {
		return false, err
	}

	// IMP-e48612a32273 — `start` on an already-active unit is a no-op, so
	// a rotation's rewritten unit (new credentials= path above) is never
	// picked up without asking for `restart` explicitly here. See
	// restartMountUnit's own comment for the EBUSY/lazy-unmount tradeoff.
	if task.Remount {
		if err := restartMountUnit(ctx, runner, task.UnitName); err != nil {
			return false, err
		}
		// Only on a SUCCESSFUL restart: each old cred file is removed once
		// the new one is confirmed live, never before and never on
		// failure — a failed restart leaves every file in place so the
		// old mount, if it's still active on its existing session, keeps
		// working. Plural (server review correction): rotate-rotate-
		// confirm can leave more than one stale cred file behind.
		for _, id := range task.PreviousCredentialIDs {
			if id == "" {
				continue
			}
			_ = removeCredentialFile(id)
		}
		// restart always does something real (stop-then-start), regardless
		// of whether the unit was active or inactive beforehand — no
		// is-active check needed here, unlike the plain-start path below.
		return true, nil
	}

	// Checked BEFORE starting: `systemctl start` on an unit that's already
	// active is the exact no-op an old agent can't tell apart from a real
	// mount — capture the PRIOR state here, not after, since start()
	// itself would otherwise always report "active" afterward regardless.
	wasActive, err := systemd.IsActive(ctx, runner, task.UnitName)
	if err != nil {
		return false, fmt.Errorf("check unit active state: %w", err)
	}
	if err := startMountUnit(ctx, runner, task.UnitName); err != nil {
		return false, err
	}
	return !wasActive, nil
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
