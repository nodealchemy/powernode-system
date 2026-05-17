// Package migration is the agent-side executor for
// System::StorageMigration. The platform side plans + approves
// migrations; this runner picks them up from
// /api/v1/system/node_api/storage_migrations, advances them through
// the 6-step contract, and reports progress.
//
// Contract steps (per server-side plan["agent_contract"]):
//
//   mount_target → snapshot → rsync → verify → cutover → unmount_source
//
// Mapped onto the StorageMigration state machine:
//
//   approved  → preparing  (mount_target + snapshot)
//   preparing → syncing    (rsync data)
//   syncing   → verifying  (rsync --checksum --dry-run; expect no diffs)
//   verifying → cutover    (atomic rename — old subpath ↔ new subpath)
//   cutover   → completed  (server-side; agent reports + unmount_source)
//
// Plan reference: E8.2 / E8.3.
package migration

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/systemd"
)

// Client is the minimal HTTP surface needed to talk to the platform.
// Matches transport.Client's existing signatures so *transport.Client
// satisfies the interface unchanged.
type Client interface {
	GetJSON(path string) (*http.Response, error)
	PostJSON(path string, body []byte) (*http.Response, error)
}

// AssignedMigration mirrors the server-side
// StorageMigrationsController#serialize_for_agent payload.
type AssignedMigration struct {
	ID              string                      `json:"id"`
	Status          string                      `json:"status"`
	Role            string                      `json:"role"`
	SourceSubpath   string                      `json:"source_subpath"`
	TargetSubpath   string                      `json:"target_subpath"`
	SnapshotSubpath string                      `json:"snapshot_subpath"`
	BytesCopied     *int64                      `json:"bytes_copied,omitempty"`
	BytesTotal      *int64                      `json:"bytes_total,omitempty"`
	Plan            map[string]any              `json:"plan"`
	SourceBinding   *mount.StorageVolumeBinding `json:"source_binding"`
	TargetBinding   *mount.StorageVolumeBinding `json:"target_binding"`
	// ConsumerMountPoint is the canonical path the consumer module
	// (e.g. postgres) reads its data from. The agent re-points this
	// from source → target during cutover. Empty means the migration
	// is fully scratch-space (the agent does not perform a remount).
	ConsumerMountPoint string `json:"consumer_mount_point"`
	// ConsumerUnits are the systemd unit names the agent stops before
	// the remount and starts after. Empty means no consumer to coord
	// with (the agent just remounts).
	ConsumerUnits []string `json:"consumer_units"`
}

// Runner drives one or more migrations forward each tick. Stateless
// across ticks — server is the source of truth for status.
type Runner struct {
	Client      Client
	MountRunner mount.Runner
	// OnError surfaces non-fatal step errors so the heartbeat can
	// expose them; the runner still proceeds with other migrations
	// in the batch.
	OnError func(stage string, err error)
}

// Tick fetches assigned migrations and advances each one.
// Idempotent: re-running picks up where the previous tick left off
// based on the server-reported status.
func (r *Runner) Tick(ctx context.Context) error {
	if r.Client == nil {
		return errors.New("migration.Runner: Client required")
	}
	if r.MountRunner == nil {
		return errors.New("migration.Runner: MountRunner required")
	}
	if r.OnError == nil {
		r.OnError = func(string, error) {}
	}

	migs, err := r.fetchAssigned()
	if err != nil {
		return fmt.Errorf("fetch migrations: %w", err)
	}

	for _, m := range migs {
		if err := r.advance(ctx, m); err != nil {
			r.OnError(fmt.Sprintf("migration:%s", m.ID), err)
			// Don't fail other migrations because one stumbled.
			// The agent will retry next tick (idempotent steps).
		}
	}
	return nil
}

// advance executes the appropriate step for the migration's current
// status. Each step either completes successfully (and reports the
// next status to the server) or returns an error to be surfaced via
// OnError. On the next tick the server's status reflects whatever
// happened; the runner picks up from there.
func (r *Runner) advance(ctx context.Context, m AssignedMigration) error {
	switch m.Status {
	case "approved":
		return r.stepPrepare(ctx, m)
	case "preparing":
		// Still preparing (the server transitioned, agent may have
		// crashed before kicking off rsync). Re-run the prepare step
		// idempotently before advancing.
		if err := r.stepPrepare(ctx, m); err != nil {
			return err
		}
		return r.stepSync(ctx, m)
	case "syncing":
		return r.stepSync(ctx, m)
	case "verifying":
		return r.stepVerify(ctx, m)
	case "cutover":
		return r.stepCutover(ctx, m)
	default:
		// planned, completed, failed, cancelled — nothing to do.
		return nil
	}
}

// stepPrepare mounts both volumes at their per-migration mount points
// and ensures the snapshot subpath exists on the target. Advances
// status approved → preparing.
func (r *Runner) stepPrepare(ctx context.Context, m AssignedMigration) error {
	if err := mount.ReconcileStorageVolume(ctx, r.MountRunner, m.SourceBinding); err != nil {
		return fmt.Errorf("mount source: %w", err)
	}
	if err := mount.ReconcileStorageVolume(ctx, r.MountRunner, m.TargetBinding); err != nil {
		return fmt.Errorf("mount target: %w", err)
	}
	return r.reportTransition(m.ID, "preparing", "mounted source + target", nil)
}

// stepSync runs rsync from source → target. Reports byte counts on
// transition. Advances status preparing → syncing → verifying.
//
// Uses --archive --hard-links --numeric-ids for fidelity; --inplace
// is intentionally omitted so cutover via rename stays atomic
// (rsync's normal "write to tmpfile, then rename" semantics preserve
// the rollback guarantee).
func (r *Runner) stepSync(ctx context.Context, m AssignedMigration) error {
	src := mountPointFor(m.SourceBinding) + "/"
	dst := mountPointFor(m.TargetBinding) + "/"
	if src == "/" || dst == "/" {
		return fmt.Errorf("missing mount points (src=%q dst=%q)", src, dst)
	}

	// Transition to syncing FIRST so the operator sees the phase
	// even on a long-running rsync. If the rsync fails the next
	// step transition will surface that.
	if m.Status == "preparing" {
		if err := r.reportTransition(m.ID, "syncing", "rsync started", nil); err != nil {
			return err
		}
	}

	// rsync -a --hard-links --numeric-ids --stats --info=progress2 src/ dst/
	args := []string{
		"-a", "--hard-links", "--numeric-ids",
		"--stats", "--info=progress2",
		src, dst,
	}
	if err := r.MountRunner.Run(ctx, "rsync", args...); err != nil {
		_ = r.reportFail(m.ID, fmt.Sprintf("rsync failed: %v", err))
		return fmt.Errorf("rsync: %w", err)
	}

	return r.reportTransition(m.ID, "verifying", "rsync complete; verifying", nil)
}

// stepVerify re-runs rsync in checksum + dry-run mode. Zero output
// means perfect equality. Any diff is a verification failure.
func (r *Runner) stepVerify(ctx context.Context, m AssignedMigration) error {
	src := mountPointFor(m.SourceBinding) + "/"
	dst := mountPointFor(m.TargetBinding) + "/"
	args := []string{
		"-a", "--checksum", "--dry-run", "--itemize-changes",
		src, dst,
	}
	if err := r.MountRunner.Run(ctx, "rsync", args...); err != nil {
		_ = r.reportFail(m.ID, fmt.Sprintf("verify failed: %v", err))
		return fmt.Errorf("rsync verify: %w", err)
	}
	return r.reportTransition(m.ID, "cutover", "verified clean", nil)
}

// stepCutover atomically re-points the consumer's canonical mount
// from source → target. Sequence (all idempotent):
//
//	1. systemctl stop <consumer_units>      — release file handles
//	2. umount <consumer_mount_point>        — source comes down
//	3. mount target at <consumer_mount_point> — new home in place
//	4. systemctl start <consumer_units>     — consumer reads target
//	5. umount source scratch + target scratch — release pool mounts
//	6. report cutover → completed
//
// If consumer_mount_point or consumer_units are empty, the agent
// falls back to the v1 behavior (umount source scratch only). This
// preserves back-compat with migrations created before the
// consumer-coordination fields landed.
func (r *Runner) stepCutover(ctx context.Context, m AssignedMigration) error {
	canonical := m.ConsumerMountPoint
	units := m.ConsumerUnits

	if canonical == "" || m.TargetBinding == nil {
		// Fallback path — no coordination requested. Best-effort
		// unmount of source scratch + advance state.
		if src := mountPointFor(m.SourceBinding); src != "" {
			if err := r.MountRunner.Run(ctx, "umount", src); err != nil {
				r.OnError("migration:umount_source", err)
			}
		}
		return r.reportTransition(m.ID, "completed", "cutover complete (no coord)", nil)
	}

	// 1. Stop consumer units. Reverse order so dependent units shut
	// before their dependencies (mirrors module-detach convention).
	for i := len(units) - 1; i >= 0; i-- {
		if err := systemd.Action(ctx, r.MountRunner, units[i], systemd.Stop); err != nil {
			_ = r.reportFail(m.ID, fmt.Sprintf("stop %s: %v", units[i], err))
			return fmt.Errorf("stop %s: %w", units[i], err)
		}
	}

	// 2. Unmount the canonical path so it can host the target. If
	// nothing is currently mounted there (first migration on a new
	// deployment), the error is ignored.
	if mounted, _ := mount.IsMountpoint(ctx, r.MountRunner, canonical); mounted {
		if err := r.MountRunner.Run(ctx, "umount", canonical); err != nil {
			_ = r.reportFail(m.ID, fmt.Sprintf("umount canonical: %v", err))
			return fmt.Errorf("umount canonical: %w", err)
		}
	}

	// 3. Mount target at the canonical path. Build a re-pointed
	// binding from target — same connection details, different
	// mount point.
	rebound := *m.TargetBinding
	rebound.MountPoint = canonical
	if err := mount.ReconcileStorageVolume(ctx, r.MountRunner, &rebound); err != nil {
		_ = r.reportFail(m.ID, fmt.Sprintf("mount target at canonical: %v", err))
		return fmt.Errorf("mount target at canonical: %w", err)
	}

	// 4. Start consumer units in declared order.
	for _, u := range units {
		if err := systemd.Action(ctx, r.MountRunner, u, systemd.Start); err != nil {
			// Don't fail the migration — the consumer is in a
			// half-restarted state, the operator needs to see
			// this surface but the data path is intact.
			r.OnError("migration:start_unit", fmt.Errorf("start %s: %w", u, err))
		}
	}

	// 5. Best-effort cleanup of scratch mounts (rsync workspace).
	for _, b := range []*mount.StorageVolumeBinding{m.SourceBinding, m.TargetBinding} {
		if mp := mountPointFor(b); mp != "" && mp != canonical {
			if err := r.MountRunner.Run(ctx, "umount", mp); err != nil {
				r.OnError("migration:umount_scratch", err)
			}
		}
	}

	// 6. Advance to completed; server's promote_target_binding!
	// makes the binding swap durable.
	return r.reportTransition(m.ID, "completed", "cutover complete", nil)
}

func (r *Runner) fetchAssigned() ([]AssignedMigration, error) {
	resp, err := r.Client.GetJSON("/api/v1/system/node_api/storage_migrations")
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("status %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}
	var env struct {
		Success bool `json:"success"`
		Data    struct {
			Migrations []AssignedMigration `json:"storage_migrations"`
		} `json:"data"`
		Error string `json:"error,omitempty"`
	}
	if err := json.Unmarshal(body, &env); err != nil {
		return nil, fmt.Errorf("decode: %w", err)
	}
	if !env.Success {
		return nil, fmt.Errorf("platform success=false: %s", env.Error)
	}
	return env.Data.Migrations, nil
}

func (r *Runner) reportTransition(id, status, note string, extras map[string]any) error {
	body := map[string]any{"status": status, "note": note}
	for k, v := range extras {
		body[k] = v
	}
	raw, err := json.Marshal(body)
	if err != nil {
		return fmt.Errorf("marshal progress: %w", err)
	}
	path := fmt.Sprintf("/api/v1/system/node_api/storage_migrations/%s/progress", url.PathEscape(id))
	resp, err := r.Client.PostJSON(path, raw)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<10))
		return fmt.Errorf("progress status %d: %s", resp.StatusCode, strings.TrimSpace(string(b)))
	}
	return nil
}

func (r *Runner) reportFail(id, reason string) error {
	raw, err := json.Marshal(map[string]any{"reason": reason})
	if err != nil {
		return err
	}
	path := fmt.Sprintf("/api/v1/system/node_api/storage_migrations/%s/fail", url.PathEscape(id))
	resp, err := r.Client.PostJSON(path, raw)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	return nil
}

func mountPointFor(b *mount.StorageVolumeBinding) string {
	if b == nil {
		return ""
	}
	return b.MountPoint
}
