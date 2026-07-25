package espwrite

import (
	"context"
	"os"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// The single-slot installUKI tests were removed with installUKI itself on
// 2026-07-25 (RCP v2 P0-b): writing the UKI over /EFI/BOOT/<removable> replaced
// systemd-boot with the payload and bricked VM 9002 unrecoverably. A node with
// no A/B layout now refuses the upgrade — see bootupgrade.Apply and
// bootslots.TestBootedViaSystemdBootDetectsRealLoaderInfo.

func TestLocateESP_ByFatLabel(t *testing.T) {
	r := &mount.RecorderRunner{StubOutput: map[string][]byte{
		"blkid -L BOOT": []byte("/dev/sda1\n"),
	}}
	dev, err := locateESP(context.Background(), r)
	if err != nil {
		t.Fatalf("locateESP: %v", err)
	}
	if dev != "/dev/sda1" {
		t.Errorf("dev = %q, want /dev/sda1", dev)
	}
}

func TestLocateESP_FallbackToPartType(t *testing.T) {
	r := &mount.RecorderRunner{
		StubErr: map[string]error{"blkid -L BOOT": os.ErrNotExist},
		StubOutput: map[string][]byte{
			"lsblk -rno NAME,PARTTYPE": []byte(
				"sda \nsda1 c12a7328-f81f-11d2-ba4b-00a0c93ec93b\nsda2 0fc63daf-8483-4772-8e79-3d69d8477de4\n"),
		},
	}
	dev, err := locateESP(context.Background(), r)
	if err != nil {
		t.Fatalf("locateESP: %v", err)
	}
	if dev != "/dev/sda1" {
		t.Errorf("dev = %q, want /dev/sda1 (matched by EFI partition type)", dev)
	}
}

func TestLocateESP_NotFound(t *testing.T) {
	r := &mount.RecorderRunner{
		StubErr:    map[string]error{"blkid -L BOOT": os.ErrNotExist},
		StubOutput: map[string][]byte{"lsblk -rno NAME,PARTTYPE": []byte("sda \nsda1 0fc63daf-8483-4772-8e79-3d69d8477de4\n")},
	}
	if _, err := locateESP(context.Background(), r); err == nil {
		t.Fatal("expected error when no ESP is present")
	}
}
