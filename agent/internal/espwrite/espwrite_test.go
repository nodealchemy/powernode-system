package espwrite

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

func TestRemovableBootName(t *testing.T) {
	cases := map[string]string{"amd64": "BOOTX64.EFI", "arm64": "BOOTAA64.EFI", "riscv64": "BOOTX64.EFI"}
	for arch, want := range cases {
		if got := RemovableBootName(arch); got != want {
			t.Errorf("RemovableBootName(%q) = %q, want %q", arch, got, want)
		}
	}
}

func TestInstallUKI_FreshWrite(t *testing.T) {
	mnt := t.TempDir()
	src := filepath.Join(t.TempDir(), "new.uki")
	if err := os.WriteFile(src, []byte("NEW-UKI-BYTES"), 0o644); err != nil {
		t.Fatal(err)
	}

	if err := installUKI(mnt, src, "BOOTX64.EFI"); err != nil {
		t.Fatalf("installUKI: %v", err)
	}

	dst := filepath.Join(mnt, "EFI", "BOOT", "BOOTX64.EFI")
	got, err := os.ReadFile(dst)
	if err != nil {
		t.Fatalf("read installed: %v", err)
	}
	if string(got) != "NEW-UKI-BYTES" {
		t.Errorf("installed bytes = %q", got)
	}
	// No prior bootloader → no backup, and the temp .new is gone.
	if _, err := os.Stat(dst + ".bak"); !os.IsNotExist(err) {
		t.Errorf(".bak should not exist on a fresh write")
	}
	if _, err := os.Stat(dst + ".new"); !os.IsNotExist(err) {
		t.Errorf(".new should have been renamed away")
	}
}

func TestInstallUKI_BacksUpExisting(t *testing.T) {
	mnt := t.TempDir()
	bootDir := filepath.Join(mnt, "EFI", "BOOT")
	if err := os.MkdirAll(bootDir, 0o755); err != nil {
		t.Fatal(err)
	}
	dst := filepath.Join(bootDir, "BOOTX64.EFI")
	if err := os.WriteFile(dst, []byte("OLD-UKI"), 0o644); err != nil {
		t.Fatal(err)
	}
	src := filepath.Join(t.TempDir(), "new.uki")
	if err := os.WriteFile(src, []byte("NEW-UKI"), 0o644); err != nil {
		t.Fatal(err)
	}

	if err := installUKI(mnt, src, "BOOTX64.EFI"); err != nil {
		t.Fatalf("installUKI: %v", err)
	}

	if got, _ := os.ReadFile(dst); string(got) != "NEW-UKI" {
		t.Errorf("live bootloader = %q, want NEW-UKI", got)
	}
	if bak, err := os.ReadFile(dst + ".bak"); err != nil || string(bak) != "OLD-UKI" {
		t.Errorf(".bak = %q (err %v), want OLD-UKI — the prior bootloader must be recoverable", bak, err)
	}
}

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
