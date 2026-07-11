// Package espwrite installs a UKI onto the EFI System Partition for in-place
// boot-image upgrades (campaign 019f505f increment 2). It locates the ESP,
// mounts it if needed, backs up the current removable bootloader, and atomically
// replaces it — the old bootloader stays intact until the final rename, so a
// crash mid-write never bricks the node (interim single-slot safety before the
// A/B auto-rollback increment).
package espwrite

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// ESPFatLabel is the FAT volume label the disk-image build sets on the ESP
// (build-disk-image-*-uefi.sh: `mformat ... -v BOOT`).
const ESPFatLabel = "BOOT"

// espPartType is the GPT partition type GUID of an EFI System Partition — the
// fallback discovery when the FAT-label lookup misses.
const espPartType = "c12a7328-f81f-11d2-ba4b-00a0c93ec93b"

// RemovableBootName returns the EFI removable-media default bootloader basename
// the firmware loads for the given GOARCH — the file an in-place upgrade
// replaces on the ESP.
func RemovableBootName(goarch string) string {
	switch goarch {
	case "arm64":
		return "BOOTAA64.EFI"
	default:
		return "BOOTX64.EFI"
	}
}

// WriteUKI locates the ESP, backs up EFI/BOOT/<filename> to <filename>.bak, and
// atomically replaces it with the UKI at srcUKIPath. Idempotent: re-running with
// the same UKI simply re-writes the same bytes. Returns an error without
// modifying the live bootloader if any step before the final rename fails.
func WriteUKI(ctx context.Context, r mount.Runner, srcUKIPath, filename string) (err error) {
	if _, statErr := os.Stat(srcUKIPath); statErr != nil {
		return fmt.Errorf("source UKI: %w", statErr)
	}

	dev, e := locateESP(ctx, r)
	if e != nil {
		return fmt.Errorf("locate ESP: %w", e)
	}

	mnt, mountedByUs, e := ensureMounted(ctx, r, dev)
	if e != nil {
		return fmt.Errorf("mount ESP %s: %w", dev, e)
	}
	if mountedByUs {
		defer func() {
			_ = r.Run(ctx, "sync")
			if uerr := r.Run(ctx, "umount", mnt); uerr != nil {
				if err == nil {
					err = fmt.Errorf("umount ESP: %w", uerr)
				}
				return // still mounted — do NOT remove the mountpoint
			}
			_ = os.Remove(mnt)
		}()
	}

	if e := installUKI(mnt, srcUKIPath, filename); e != nil {
		return e
	}
	if e := r.Run(ctx, "sync"); e != nil {
		return fmt.Errorf("sync ESP: %w", e)
	}
	return nil
}

// installUKI writes srcUKIPath into <mnt>/EFI/BOOT/<filename> with a backup and
// an atomic rename. Split out from WriteUKI so the crash-safe file logic can be
// unit-tested against a temp dir without a real mount. The old bootloader
// survives until the final rename, so an interrupted install leaves a bootable
// node.
func installUKI(mnt, srcUKIPath, filename string) error {
	bootDir := filepath.Join(mnt, "EFI", "BOOT")
	if e := os.MkdirAll(bootDir, 0o755); e != nil {
		return fmt.Errorf("mkdir %s: %w", bootDir, e)
	}
	dst := filepath.Join(bootDir, filename)

	// Back up the current bootloader (interim single-slot recovery aid — an
	// operator can restore <filename>.bak if the new UKI fails to boot; the A/B
	// increment replaces this with systemd-boot auto-rollback).
	if _, e := os.Stat(dst); e == nil {
		if e := copyFile(dst, dst+".bak"); e != nil {
			return fmt.Errorf("backup %s: %w", dst, e)
		}
	}

	// Stage to <filename>.new then rename over the target.
	tmp := dst + ".new"
	if e := copyFile(srcUKIPath, tmp); e != nil {
		return fmt.Errorf("stage new UKI: %w", e)
	}
	if e := os.Rename(tmp, dst); e != nil {
		return fmt.Errorf("install UKI: %w", e)
	}
	return nil
}

// locateESP finds the ESP block device: the build's FAT label first, then the
// EFI System Partition GPT type GUID.
func locateESP(ctx context.Context, r mount.Runner) (string, error) {
	if out, err := r.Output(ctx, "blkid", "-L", ESPFatLabel); err == nil {
		if dev := strings.TrimSpace(string(out)); dev != "" {
			return dev, nil
		}
	}
	out, err := r.Output(ctx, "lsblk", "-rno", "NAME,PARTTYPE")
	if err != nil {
		return "", fmt.Errorf("lsblk: %w", err)
	}
	for _, line := range strings.Split(string(out), "\n") {
		f := strings.Fields(line)
		if len(f) == 2 && strings.EqualFold(f[1], espPartType) {
			return "/dev/" + f[0], nil
		}
	}
	return "", errors.New("no ESP found (no FAT label '" + ESPFatLabel + "', no EFI-type partition)")
}

// ensureMounted returns a mountpoint for dev, mounting it read-write if it isn't
// already mounted. The bool reports whether this call performed the mount (and
// therefore owns the unmount).
func ensureMounted(ctx context.Context, r mount.Runner, dev string) (string, bool, error) {
	if mp := existingMount(dev); mp != "" {
		return mp, false, nil
	}
	mnt, err := os.MkdirTemp("", "powernode-esp-")
	if err != nil {
		return "", false, err
	}
	if err := r.Run(ctx, "mount", "-t", "vfat", "-o", "rw", dev, mnt); err != nil {
		_ = os.Remove(mnt)
		return "", false, err
	}
	return mnt, true, nil
}

// existingMount returns dev's current mountpoint (resolving symlinks), or "".
func existingMount(dev string) string {
	data, err := os.ReadFile("/proc/mounts")
	if err != nil {
		return ""
	}
	realDev, _ := filepath.EvalSymlinks(dev)
	for _, line := range strings.Split(string(data), "\n") {
		f := strings.Fields(line)
		if len(f) < 2 {
			continue
		}
		if f[0] == dev {
			return f[1]
		}
		if realDev != "" {
			if md, _ := filepath.EvalSymlinks(f[0]); md == realDev {
				return f[1]
			}
		}
	}
	return ""
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(dst, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	if err := out.Sync(); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}
