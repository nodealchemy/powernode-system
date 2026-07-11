package handlers

import (
	"context"
	"errors"
	"fmt"
	"runtime"

	"github.com/nodealchemy/powernode-system/agent/internal/bootupgrade"
	"github.com/nodealchemy/powernode-system/agent/internal/identity"
	"github.com/nodealchemy/powernode-system/agent/internal/runtime/tasks"
)

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
		return tasks.Result{"status": "already_on_target", "git_sha": booted}, nil
	}

	client := h.deps.Transport.Get()
	if client == nil {
		return nil, errors.New("upgrade_boot_image: no platform transport")
	}

	if err := bootupgrade.Apply(ctx, bootupgrade.Deps{
		Runner: h.deps.MountRunner,
		Client: client,
		Arch:   runtime.GOARCH,
	}, opts); err != nil {
		return nil, fmt.Errorf("upgrade_boot_image: %w", err)
	}

	// ESP written + verified — reboot into the new UKI. /persist (and the PKI
	// under it) survives, so the node re-attaches with its existing cert.
	if err := h.deps.MountRunner.Run(ctx, "systemctl", "reboot"); err != nil {
		return nil, fmt.Errorf("upgrade_boot_image: reboot: %w", err)
	}
	return tasks.Result{"status": "boot_image_written_reboot_initiated", "git_sha": opts.TargetGitSHA}, nil
}

func parseUpgradeOptions(task *tasks.Task) bootupgrade.Options {
	return bootupgrade.Options{
		TargetGitSHA:         optString(task, "target_git_sha"),
		UkiSha256:            optString(task, "uki_sha256"),
		CosignIdentityRegexp: optString(task, "cosign_identity_regexp"),
		CosignIssuerRegexp:   optString(task, "cosign_issuer_regexp"),
		CosignBundleB64:      optString(task, "cosign_bundle_b64"),
		DownloadPath:         optString(task, "download_path"),
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
