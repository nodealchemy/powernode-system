package mount

import (
	"context"
	"strings"
	"testing"
)

// Plan reference: E8.1 — agent-side storage volume reconciler tests.
//
// We use RecorderRunner to assert which shell-outs the reconciler
// makes without actually touching the filesystem or invoking mount(8).

func TestReconcileStorageVolume_NilBinding(t *testing.T) {
	r := &RecorderRunner{}
	if err := ReconcileStorageVolume(context.Background(), r, nil); err != nil {
		t.Fatalf("expected nil for nil binding, got %v", err)
	}
	if len(r.Invocations) != 0 {
		t.Fatalf("expected zero invocations, got %d", len(r.Invocations))
	}
}

func TestReconcileStorageVolume_NFS_FreshMount(t *testing.T) {
	r := &RecorderRunner{
		StubOutput: map[string][]byte{
			// IsMountpoint shells out via findmnt. Return non-success
			// (empty stdout + no error → "not a mount point").
		},
	}

	b := &StorageVolumeBinding{
		VolumeID:   "vol-1",
		VolumeName: "dsm-powernode",
		Transport:  "nfs",
		MountType:  "nfs",
		MountPoint: "/tmp/powernode-test-mount-nfs",
		Role:       "postgres",
		Subpath:    "deployments/sim/postgres",
		NFS: &NFSDetails{
			Server:         "dsm.local",
			ExportPath:     "/volume1/Powernode",
			Version:        "4.1",
			MountOptions:   "nfsvers=4.1,hard",
			FullExportPath: "/volume1/Powernode/deployments/sim/postgres",
			Subpath:        "deployments/sim/postgres",
		},
	}

	// Pre-cleanup if test mount point persists across runs
	_ = removeDirIfExists(b.MountPoint)
	defer func() { _ = removeDirIfExists(b.MountPoint) }()

	if err := ReconcileStorageVolume(context.Background(), r, b); err != nil {
		t.Fatalf("reconcile failed: %v", err)
	}

	// Verify the agent attempted a `mount -t nfs ...` call.
	var sawNFSMount bool
	for _, inv := range r.Invocations {
		if inv.Op == "Run" && inv.Name == "mount" {
			joined := strings.Join(inv.Args, " ")
			if strings.Contains(joined, "-t nfs") && strings.Contains(joined, b.MountPoint) {
				sawNFSMount = true
			}
		}
	}
	if !sawNFSMount {
		t.Fatalf("expected mount -t nfs invocation; got %+v", r.Invocations)
	}
}

func TestReconcileStorageVolume_Block_FreshMount(t *testing.T) {
	r := &RecorderRunner{}
	b := &StorageVolumeBinding{
		VolumeID:   "vol-block-1",
		VolumeName: "ssd-data",
		Transport:  "block",
		MountType:  "device",
		DeviceName: "/dev/vdb",
		MountPoint: "/tmp/powernode-test-mount-block",
		Role:       "postgres",
	}
	_ = removeDirIfExists(b.MountPoint)
	defer func() { _ = removeDirIfExists(b.MountPoint) }()

	if err := ReconcileStorageVolume(context.Background(), r, b); err != nil {
		t.Fatalf("reconcile failed: %v", err)
	}

	// Should invoke `mount /dev/vdb /tmp/...` (no -t flag for autodetect)
	var saw bool
	for _, inv := range r.Invocations {
		if inv.Op == "Run" && inv.Name == "mount" {
			if len(inv.Args) == 2 && inv.Args[0] == b.DeviceName && inv.Args[1] == b.MountPoint {
				saw = true
			}
		}
	}
	if !saw {
		t.Fatalf("expected block mount invocation; got %+v", r.Invocations)
	}
}

func TestReconcileStorageVolume_UnknownTransport(t *testing.T) {
	r := &RecorderRunner{}
	b := &StorageVolumeBinding{
		VolumeID:   "vol-x",
		Transport:  "alien",
		MountPoint: "/tmp/powernode-test-unknown",
	}
	_ = removeDirIfExists(b.MountPoint)
	defer func() { _ = removeDirIfExists(b.MountPoint) }()

	err := ReconcileStorageVolume(context.Background(), r, b)
	if err == nil {
		t.Fatal("expected error on unknown transport, got nil")
	}
	if !strings.Contains(err.Error(), "unknown transport") {
		t.Fatalf("error did not mention transport: %v", err)
	}
}

func TestReconcileStorageVolume_NoMountPoint(t *testing.T) {
	r := &RecorderRunner{}
	b := &StorageVolumeBinding{
		VolumeID:  "vol-y",
		Transport: "nfs",
		// MountPoint deliberately omitted
		NFS: &NFSDetails{Server: "x", ExportPath: "/x"},
	}
	err := ReconcileStorageVolume(context.Background(), r, b)
	if err == nil {
		t.Fatal("expected error on missing mount_point, got nil")
	}
	if !strings.Contains(err.Error(), "mount_point") {
		t.Fatalf("error did not mention mount_point: %v", err)
	}
}

func removeDirIfExists(path string) error {
	if path == "" {
		return nil
	}
	// Best-effort; ignore errors
	return nil
}
