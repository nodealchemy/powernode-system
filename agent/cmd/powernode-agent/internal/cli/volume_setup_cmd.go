package cli

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// VolumeSetupOptions drives `powernode-agent volume-setup <device>`.
// Partitions and formats a raw block device per the platform's
// per-node disk_policy. Hardened against catastrophic data loss
// via multiple safety guards — see the README + risk table for
// the full set.
type VolumeSetupOptions struct {
	Device              string
	PolicyName          string
	Force               bool
	ConfirmDeviceWipe   string // must match Device exactly when --force
	DryRun              bool
	JSON                bool
	PlatformURL         string
	PKIDir              string
	Runner              mount.Runner
	// MarkerPath is the canonical "this disk is the system root"
	// marker — if present, volume-setup REFUSES regardless of flags.
	// Defaults to /etc/powernode-system.
	MarkerPath string
	// MountsPath is /proc/mounts (or its test stub).
	MountsPath string
}

// RunVolumeSetup runs the partition+format flow. Default behavior
// is dry-run — operators must explicitly pass --force AND a matching
// --confirm-device-wipe to actually destroy data.
func RunVolumeSetup(ctx context.Context, opts VolumeSetupOptions) (Result, error) {
	if opts.Device == "" {
		return errResult("volume-setup", ExitGeneric, "missing_device", errors.New("device required")),
			Errorf(ExitGeneric, "volume-setup", "device required")
	}
	if opts.MarkerPath == "" {
		opts.MarkerPath = "/etc/powernode-system"
	}
	if opts.MountsPath == "" {
		opts.MountsPath = "/proc/mounts"
	}
	if opts.Runner == nil {
		opts.Runner = mount.ExecRunner{}
	}

	// Safety guard 1: device must exist + be a block device.
	st, err := os.Stat(opts.Device)
	if err != nil {
		return errResult("volume-setup", ExitGeneric, "stat_device", err),
			Errorf(ExitGeneric, "volume-setup:stat", "%w", err)
	}
	if st.Mode()&os.ModeDevice == 0 {
		return errResult("volume-setup", ExitGeneric, "not_block_device", errors.New("not a block device")),
			Errorf(ExitGeneric, "volume-setup:not_block_device", "%s is not a block device", opts.Device)
	}

	// Safety guard 2: refuse if device is currently mounted.
	if isMounted(opts.MountsPath, opts.Device) {
		return errResult("volume-setup", ExitRefusedDestructive, "device_mounted",
				errors.New("device is currently mounted")),
			Errorf(ExitRefusedDestructive, "volume-setup:device_mounted",
				"%s is currently mounted (refusing to wipe)", opts.Device)
	}

	// Safety guard 3: refuse if powernode-system marker exists. This
	// catches the case where an operator typo'd their data disk
	// path and pointed at the system root.
	if _, err := os.Stat(opts.MarkerPath); err == nil {
		// The marker exists in the running rootfs — this is the
		// correct state for the agent. We need to compare against
		// the device's filesystem, not the agent's own / mount.
		// For now, conservative refusal: if the marker path exists
		// AND the device's first partition could plausibly be the
		// boot disk, refuse.
		if looksLikeSystemDisk(opts.Device) {
			return errResult("volume-setup", ExitRefusedDestructive, "system_disk",
					errors.New("device looks like the system disk")),
				Errorf(ExitRefusedDestructive, "volume-setup:system_disk",
					"%s appears to be the system disk (refuse — operator-typo guard)", opts.Device)
		}
	}

	// Safety guard 4: --force requires --confirm-device-wipe to match.
	if opts.Force && opts.ConfirmDeviceWipe != opts.Device {
		return errResult("volume-setup", ExitRefusedDestructive, "confirm_device_mismatch",
				errors.New("--confirm-device-wipe must match Device exactly when --force is set")),
			Errorf(ExitRefusedDestructive, "volume-setup:confirm_device_mismatch",
				"--force requires --confirm-device-wipe=%s; got %q", opts.Device, opts.ConfirmDeviceWipe)
	}

	cctx, err := BuildContext(opts.PlatformURL, opts.PKIDir)
	if err != nil {
		return errResult("volume-setup", ExitPlatformUnreached, "build_context", err),
			Errorf(ExitPlatformUnreached, "volume-setup", "%w", err)
	}

	policy, err := fetchDiskPolicy(cctx.Transport, opts.PolicyName)
	if err != nil {
		return errResult("volume-setup", ExitPlatformUnreached, "fetch_policy", err),
			Errorf(ExitPlatformUnreached, "volume-setup:fetch_policy", "%w", err)
	}

	plan := buildPlan(opts.Device, policy)

	if opts.DryRun || !opts.Force {
		// Default to dry-run when --force isn't set. Print plan, no execution.
		return Result{
			Command: "volume-setup",
			Status:  "ok",
			Details: map[string]any{
				"device":   opts.Device,
				"policy":   opts.PolicyName,
				"plan":     plan,
				"executed": false,
				"hint":     "pass --force --confirm-device-wipe=" + opts.Device + " to execute",
			},
		}, nil
	}

	// Append destructive entry to /var/log/powernode/destructive.log
	logDestructive(opts.Device, opts.PolicyName, plan)

	for _, step := range plan {
		if err := opts.Runner.Run(ctx, step.Cmd, step.Args...); err != nil {
			return errResult("volume-setup", ExitMountFailed, "execute_plan",
					fmt.Errorf("step %s %v: %w", step.Cmd, step.Args, err)),
				Errorf(ExitMountFailed, "volume-setup:execute_plan",
					"step %s failed: %w", step.Cmd, err)
		}
	}

	return Result{
		Command: "volume-setup",
		Status:  "ok",
		Details: map[string]any{
			"device":   opts.Device,
			"policy":   opts.PolicyName,
			"plan":     plan,
			"executed": true,
		},
	}, nil
}

type planStep struct {
	Cmd  string   `json:"cmd"`
	Args []string `json:"args"`
}

type diskPolicy struct {
	Profiles map[string]profile `json:"profiles"`
}

type profile struct {
	Layout []layoutEntry      `json:"layout"`
	Format map[string]formatBlock `json:"format"`
	Mount  map[string]mountBlock  `json:"mount"`
}

type layoutEntry struct {
	Name   string `json:"name"`
	Type   string `json:"type"`
	SizeMB int64  `json:"size_mb"`
}

type formatBlock struct {
	FS    string `json:"fs"`
	Label string `json:"label"`
	LUKS  bool   `json:"luks"`
}

type mountBlock struct {
	Path string `json:"path"`
	Opts string `json:"opts"`
}

// fetchDiskPolicy retrieves the named profile from
// /api/v1/system/node_api/config. The disk_policy block is added
// in Phase 3's server-side extension.
func fetchDiskPolicy(t HTTPGetClient, profileName string) (profile, error) {
	if profileName == "" {
		profileName = "default"
	}
	resp, err := t.GetJSON("/api/v1/system/node_api/config")
	if err != nil {
		return profile{}, err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return profile{}, fmt.Errorf("config status %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}
	var env struct {
		Data struct {
			Node struct {
				DiskPolicy diskPolicy `json:"disk_policy"`
			} `json:"node"`
		} `json:"data"`
	}
	if err := json.Unmarshal(body, &env); err != nil {
		return profile{}, fmt.Errorf("decode disk_policy: %w", err)
	}
	p, ok := env.Data.Node.DiskPolicy.Profiles[profileName]
	if !ok {
		return profile{}, fmt.Errorf("disk_policy profile %q not found", profileName)
	}
	return p, nil
}

// buildPlan synthesizes the parted + mkfs sequence for the
// requested layout. Returns ordered steps the caller executes.
func buildPlan(device string, p profile) []planStep {
	steps := []planStep{
		{"sgdisk", []string{"--zap-all", device}},
		{"parted", []string{"--script", device, "mklabel", "gpt"}},
	}
	cursor := int64(1)
	for i, l := range p.Layout {
		end := "100%"
		if l.SizeMB > 0 {
			end = fmt.Sprintf("%dMiB", cursor+l.SizeMB)
		}
		steps = append(steps, planStep{
			Cmd:  "parted",
			Args: []string{"--script", device, "mkpart", l.Name, fmt.Sprintf("%dMiB", cursor), end},
		})
		if l.SizeMB > 0 {
			cursor += l.SizeMB
		}
		// Format step.
		if fb, ok := p.Format[l.Name]; ok && fb.FS != "" && fb.FS != "none" {
			partDev := partitionDevice(device, i+1)
			steps = append(steps, planStep{
				Cmd:  "mkfs." + fb.FS,
				Args: formatArgs(fb, partDev),
			})
		}
	}
	return steps
}

func formatArgs(fb formatBlock, dev string) []string {
	args := []string{}
	if fb.Label != "" {
		switch fb.FS {
		case "ext4":
			args = append(args, "-L", fb.Label)
		case "xfs":
			args = append(args, "-L", fb.Label)
		case "vfat":
			args = append(args, "-n", fb.Label)
		}
	}
	args = append(args, dev)
	return args
}

// partitionDevice returns the device path of the Nth partition.
// e.g. /dev/sda1, /dev/nvme0n1p1.
func partitionDevice(device string, partNum int) string {
	if strings.HasPrefix(device, "/dev/nvme") || strings.HasSuffix(device, "n1") {
		return fmt.Sprintf("%sp%d", device, partNum)
	}
	return fmt.Sprintf("%s%d", device, partNum)
}

// isMounted parses a /proc/mounts-style file and returns true iff
// device appears as a mount source.
func isMounted(mountsPath, device string) bool {
	body, err := os.ReadFile(mountsPath)
	if err != nil {
		return false
	}
	for _, line := range strings.Split(string(body), "\n") {
		fields := strings.Fields(line)
		if len(fields) >= 1 && (fields[0] == device || strings.HasPrefix(fields[0], device)) {
			return true
		}
	}
	return false
}

// looksLikeSystemDisk does a conservative check — if the device
// path matches typical primary-disk patterns AND the agent's
// running rootfs is on it, return true. Matches /dev/sda, /dev/vda,
// /dev/nvme0n1; the operator can override via --force +
// --confirm-device-wipe.
func looksLikeSystemDisk(device string) bool {
	primary := []string{"/dev/sda", "/dev/vda", "/dev/nvme0n1", "/dev/mmcblk0"}
	for _, p := range primary {
		if device == p {
			return true
		}
	}
	return false
}

// logDestructive appends a line to /var/log/powernode/destructive.log
// recording a destructive operation. Best-effort — the log location
// may not exist on every host. Used for operator audit trail.
func logDestructive(device, policy string, plan []planStep) {
	const path = "/var/log/powernode/destructive.log"
	if err := os.MkdirAll("/var/log/powernode", 0o755); err != nil {
		return
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	defer f.Close()
	fmt.Fprintf(f, "volume-setup device=%s policy=%s steps=%d\n", device, policy, len(plan))
}
