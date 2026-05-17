package mount

import (
	"context"
	"fmt"
	"os"
	"strings"
)

// StorageVolumeBinding mirrors the JSON shape the orchestrator stamps
// onto NodeInstance.config["storage_volume"]. See
// System::PlatformDeploymentOrchestrator#attach_storage_volume! in
// the Rails platform tree for the producer side of this contract.
//
// Plan reference: E8.1 (transport-aware mount reconciliation).
type StorageVolumeBinding struct {
	VolumeID    string            `json:"volume_id"`
	VolumeName  string            `json:"volume_name"`
	SizeGB      int               `json:"size_gb"`
	Transport   string            `json:"transport"`   // "block" | "nfs" | "smb" | "iscsi"
	MountType   string            `json:"mount_type"`  // "device" | "nfs" | "smb" | "iscsi"
	DeviceName  string            `json:"device_name"` // populated for block
	MountPoint  string            `json:"mount_point"`
	Role        string            `json:"role"`
	Subpath     string            `json:"subpath,omitempty"` // populated for shared transports
	AttachedAt  string            `json:"attached_at"`

	// Transport-specific connection details. Only one of these is
	// populated per binding; the orchestrator stamps the matching
	// inner object keyed by the transport name.
	NFS  *NFSDetails  `json:"nfs,omitempty"`
	SMB  *SMBDetails  `json:"smb,omitempty"`
	ISCSI *ISCSIDetails `json:"iscsi,omitempty"`
}

type NFSDetails struct {
	Server          string `json:"server"`
	ServerIP        string `json:"server_ip,omitempty"`
	ExportPath      string `json:"export_path"`
	Version         string `json:"version,omitempty"`
	MountOptions    string `json:"mount_options"`
	FullExportPath  string `json:"full_export_path,omitempty"` // <server>:<export>/<subpath>
	Subpath         string `json:"subpath,omitempty"`
}

type SMBDetails struct {
	Server       string `json:"server"`
	Share        string `json:"share"`
	MountOptions string `json:"mount_options,omitempty"`
	Subpath      string `json:"subpath,omitempty"`
}

type ISCSIDetails struct {
	Portal      string `json:"portal"`
	Target      string `json:"target"`
	LUN         int    `json:"lun,omitempty"`
	Subpath     string `json:"subpath,omitempty"`
}

// ReconcileStorageVolume idempotently realizes the binding on the
// node. Safe to call repeatedly; returns nil if the desired state is
// already achieved.
//
//   - Empty binding (no volume bound): nothing to do, returns nil.
//   - transport == "block": ensures the device is mounted at
//     mount_point. For now does NOT mkfs — the platform expects a
//     pre-formatted block device. mkfs would happen during volume
//     creation in the cloud provider.
//   - transport == "nfs": mounts <server>:<export>/<subpath> at
//     mount_point with the supplied options. Creates the mount_point
//     dir + the subpath on the export (best-effort) before mounting.
//   - transport == "smb" / "iscsi": not implemented in v1; returns
//     an explicit error so the operator sees the gap rather than
//     silent failure.
//
// The caller is responsible for ordering: this should run AFTER the
// root filesystem is mounted (so mount_point exists or can be created)
// and BEFORE any consumer (postgres/redis/etc) is started so its data
// directory is already on the durable mount.
func ReconcileStorageVolume(ctx context.Context, runner Runner, binding *StorageVolumeBinding) error {
	if binding == nil || binding.VolumeID == "" {
		return nil // no volume bound; nothing to reconcile
	}
	if binding.MountPoint == "" {
		return fmt.Errorf("storage_volume binding for volume %s has no mount_point", binding.VolumeID)
	}

	if err := ensureDir(binding.MountPoint); err != nil {
		return fmt.Errorf("ensure mount_point %s: %w", binding.MountPoint, err)
	}

	switch strings.ToLower(binding.Transport) {
	case "block":
		return reconcileBlock(ctx, runner, binding)
	case "nfs":
		return reconcileNFS(ctx, runner, binding)
	case "smb":
		return fmt.Errorf("smb transport not yet implemented in the agent (binding=%s)", binding.VolumeID)
	case "iscsi":
		return fmt.Errorf("iscsi transport not yet implemented in the agent (binding=%s)", binding.VolumeID)
	default:
		return fmt.Errorf("unknown transport %q on storage_volume binding %s", binding.Transport, binding.VolumeID)
	}
}

// reconcileBlock — ensure DeviceName is mounted at MountPoint.
// Idempotent: returns nil if already mounted.
func reconcileBlock(ctx context.Context, runner Runner, b *StorageVolumeBinding) error {
	if b.DeviceName == "" {
		return fmt.Errorf("block transport binding %s has no device_name", b.VolumeID)
	}
	already, err := IsMountpoint(ctx, runner, b.MountPoint)
	if err != nil {
		return err
	}
	if already {
		return nil
	}
	// No fs detection / mkfs in v1 — the cloud provider hands us a
	// formatted volume. If you mount an unformatted block device, the
	// kernel returns "wrong fs type, bad option, bad superblock" which
	// surfaces in the agent log; operator runs mkfs.ext4 once via SSH
	// and re-triggers reconcile.
	return runner.Run(ctx, "mount", b.DeviceName, b.MountPoint)
}

// reconcileNFS — mount <server>:<export>/<subpath> at MountPoint with
// MountOptions. Creates the subpath dir on the export beforehand by
// briefly mounting the export root and mkdir-ing — this is the
// canonical "first time we touch this subpath" path.
func reconcileNFS(ctx context.Context, runner Runner, b *StorageVolumeBinding) error {
	if b.NFS == nil {
		return fmt.Errorf("nfs transport binding %s missing nfs details", b.VolumeID)
	}
	if b.NFS.Server == "" || b.NFS.ExportPath == "" {
		return fmt.Errorf("nfs binding %s: server and export_path are required", b.VolumeID)
	}

	already, err := IsMountpoint(ctx, runner, b.MountPoint)
	if err != nil {
		return err
	}
	if already {
		return nil
	}

	// Compose the source. Prefer the orchestrator-stamped full path,
	// otherwise build it from server + export_path + subpath.
	source := b.NFS.FullExportPath
	if source == "" {
		export := strings.TrimRight(b.NFS.ExportPath, "/")
		if b.NFS.Subpath != "" {
			export = export + "/" + strings.TrimLeft(b.NFS.Subpath, "/")
		} else if b.Subpath != "" {
			export = export + "/" + strings.TrimLeft(b.Subpath, "/")
		}
		source = b.NFS.Server + ":" + export
	}

	// Ensure the subpath exists on the export. Best-effort:
	// briefly mount the export root, mkdir -p the subpath, unmount.
	// Failures here are non-fatal — the main mount below will surface
	// any real reachability issue.
	if b.NFS.Subpath != "" || b.Subpath != "" {
		if err := ensureNFSSubpath(ctx, runner, b); err != nil {
			// Log via the agent's standard error surface — we'll let
			// the actual mount try anyway so the operator gets the
			// real error if subpath isn't the cause.
			_ = err
		}
	}

	opts := b.NFS.MountOptions
	if opts == "" {
		opts = "nfsvers=4.1,hard,rsize=1048576,wsize=1048576,proto=tcp"
	}
	return runner.Run(ctx, "mount", "-t", "nfs", "-o", opts, source, b.MountPoint)
}

// ensureNFSSubpath transiently mounts the export root and creates the
// subpath directory if missing. Best-effort — used to make first-boot
// idempotent. Unmounts at the end regardless of mkdir outcome.
func ensureNFSSubpath(ctx context.Context, runner Runner, b *StorageVolumeBinding) error {
	tmp, err := os.MkdirTemp("", "powernode-nfs-init-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tmp)

	rootSource := b.NFS.Server + ":" + strings.TrimRight(b.NFS.ExportPath, "/")
	if err := runner.Run(ctx, "mount", "-t", "nfs", rootSource, tmp); err != nil {
		return fmt.Errorf("init-mount %s: %w", rootSource, err)
	}
	defer func() { _ = runner.Run(ctx, "umount", tmp) }()

	subpath := b.NFS.Subpath
	if subpath == "" {
		subpath = b.Subpath
	}
	subpath = strings.TrimLeft(subpath, "/")
	if subpath == "" {
		return nil
	}

	target := tmp + "/" + subpath
	return os.MkdirAll(target, 0o755)
}

func ensureDir(path string) error {
	return os.MkdirAll(path, 0o755)
}
