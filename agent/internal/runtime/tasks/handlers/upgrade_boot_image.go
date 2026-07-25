package handlers

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/nodealchemy/powernode-system/agent/internal/bootslots"
	"github.com/nodealchemy/powernode-system/agent/internal/bootupgrade"
	"github.com/nodealchemy/powernode-system/agent/internal/identity"
	"github.com/nodealchemy/powernode-system/agent/internal/runtime/tasks"
)

// attemptMarkerPath records the target of the last upgrade we wrote + rebooted
// for. It lives on /persist so it survives the reboot: if the node comes back
// NOT on the target (a failed/rolled-back boot, or a boot whose cmdline lacks
// the sha marker), a crash-recovery re-dispatch sees this and refuses to reboot
// again — bounding what would otherwise be a reboot loop.
const attemptMarkerPath = "/persist/var/lib/powernode/boot-image-upgrade.attempted"

func alreadyAttempted(target string) bool {
	b, err := os.ReadFile(attemptMarkerPath)
	return err == nil && strings.TrimSpace(string(b)) == target
}

func markAttempted(target string) {
	_ = os.MkdirAll(filepath.Dir(attemptMarkerPath), 0o755)
	_ = os.WriteFile(attemptMarkerPath, []byte(target), 0o600)
}

// UpgradeBootImageHandler performs an in-place boot-image (UKI) upgrade
// (campaign 019f505f increment 2): pull + cosign-verify the target UKI, write it
// to the ESP, and reboot. Success is confirmed by the platform post-reboot — the
// first heartbeat's booted_image_git_sha matching the target — because the
// reboot tears the box down and the loop's /complete POST races it.
type UpgradeBootImageHandler struct {
	deps tasks.Dependencies
}

// Execute is idempotent: the loop's crash-recovery may re-dispatch this after
// the reboot, so once the node is already on the target sha it no-ops WITHOUT
// rebooting again (which would loop). The pull/verify/ESP-write steps are each
// individually re-runnable (cached download, atomic ESP replace).
func (h *UpgradeBootImageHandler) Execute(ctx context.Context, task *tasks.Task) (tasks.Result, error) {
	opts := parseUpgradeOptions(task)

	// Post-reboot re-dispatch (or a redundant re-issue): already on target →
	// done, and crucially do NOT reboot again.
	if booted := identity.BootedImageGitSHA(); booted != "" && booted == opts.TargetGitSHA {
		_ = os.Remove(attemptMarkerPath) // upgrade confirmed; clear the loop guard
		return tasks.Result{"status": "already_on_target", "git_sha": booted}, nil
	}

	// Loop guard: we already wrote this UKI + rebooted, yet the node did not come
	// back on the target (failed/rolled-back boot, or a boot missing the cmdline
	// sha marker). Rewriting + rebooting again wouldn't change the outcome, so
	// stop here and let the platform reconciler time the task out.
	if alreadyAttempted(opts.TargetGitSHA) {
		return tasks.Result{"status": "written_awaiting_confirmation", "git_sha": opts.TargetGitSHA}, nil
	}

	client := h.deps.Transport.Get()
	if client == nil {
		return nil, errors.New("upgrade_boot_image: no platform transport")
	}

	slot, err := bootupgrade.Apply(ctx, bootupgrade.Deps{
		Runner: h.deps.MountRunner,
		Client: client,
		Arch:   runtime.GOARCH,
	}, opts)
	if err != nil {
		return nil, fmt.Errorf("upgrade_boot_image: %w", err)
	}

	// Record the pending slot + target (survives the reboot on /persist) so the
	// post-reboot bless (agent's first successful heartbeat) can promote this
	// slot to the persistent default if it boots healthy — or clear it if the
	// node rolled back. If this record can't be persisted we must NOT reboot: a
	// healthy new boot would then find no pending state, never bless/promote the
	// slot, and revert to the old image at the next reboot. (The slot == ""
	// case was the single-slot fallback path, removed 2026-07-25 — Apply now
	// returns an error rather than "" for a node with no A/B layout, so the
	// guard is retained only as belt-and-braces.)
	if slot != "" {
		st := bootslots.Load()
		st.Pending = slot
		st.PendingSHA = opts.TargetGitSHA
		if serr := st.Save(); serr != nil {
			return nil, fmt.Errorf("upgrade_boot_image: persist pending slot: %w", serr)
		}
	}
	markAttempted(opts.TargetGitSHA)
	if err := h.deps.MountRunner.Run(ctx, "systemctl", "reboot"); err != nil {
		return nil, fmt.Errorf("upgrade_boot_image: reboot: %w", err)
	}
	return tasks.Result{"status": "boot_image_written_reboot_initiated", "git_sha": opts.TargetGitSHA}, nil
}

func parseUpgradeOptions(task *tasks.Task) bootupgrade.Options {
	return bootupgrade.Options{
		TargetGitSHA:    optString(task, "target_git_sha"),
		UkiSha256:       optString(task, "uki_sha256"),
		CosignPublicKey: optString(task, "cosign_public_key"),
		CosignBundleB64: optString(task, "cosign_bundle_b64"),
		DownloadPath:    optString(task, "download_path"),
	}
}

func optString(task *tasks.Task, key string) string {
	if v, ok := task.Options[key].(string); ok {
		return v
	}
	return ""
}

// RegisterUpgradeBootImage binds the in-place boot-image upgrade command.
func RegisterUpgradeBootImage(r *tasks.Registry, deps tasks.Dependencies) {
	r.Register("upgrade_boot_image", &UpgradeBootImageHandler{deps: deps})
}
