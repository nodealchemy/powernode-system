// Package espwrite installs UKIs into the A/B slots on the EFI System Partition
// for in-place boot-image upgrades (campaign 019f505f increment 3). It locates
// the ESP, mounts it if needed, and writes /EFI/Linux/<slot> entries atomically
// (stage to .new, then rename), so a crash mid-write leaves the previous slot
// contents intact.
//
// It deliberately NEVER touches /EFI/BOOT/<removable> — the firmware's own
// bootloader — nor the opposite slot, which is the rollback target. An earlier
// increment-2 single-slot writer did replace the removable bootloader with the
// payload and claimed that "never bricks the node"; on 2026-07-25 that path
// bricked VM 9002 unrecoverably (48 boots of a dead image, 24 panics, no
// rollback) precisely because systemd-boot, and with it the boot counter and
// the default-entry fallback, had been overwritten. It was removed — see the
// NOTE further down. Rollback can only live below the payload if the payload
// never overwrites the thing implementing rollback.
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

// efiFirmwareDir is the sysfs marker for "this node booted via UEFI". A variable
// so tests can control it — without that, any test asserting "we did NOT touch
// the ESP" silently passes on a BIOS host for the wrong reason (IsUEFI short-
// circuits before the runner is ever used), which makes the assertion worthless
// exactly where it matters most.
var efiFirmwareDir = "/sys/firmware/efi"

// SetEFIDirForTest points the UEFI marker at dir and returns a restore func.
// Test-only; production never calls it.
func SetEFIDirForTest(dir string) (restore func()) {
	prev := efiFirmwareDir
	efiFirmwareDir = dir
	return func() { efiFirmwareDir = prev }
}

// IsUEFI reports whether this node booted via UEFI (an ESP exists to write).
// Non-UEFI nodes (e.g. rpi4's config.txt boot) have no /sys/firmware/efi; the
// boot-image writers refuse rather than scribble a UKI into the wrong partition.
func IsUEFI() bool {
	fi, err := os.Stat(efiFirmwareDir)
	return err == nil && fi.IsDir()
}

// NOTE: the single-slot writer (WriteUKI/installUKI) was REMOVED on 2026-07-25.
// It replaced /EFI/BOOT/<removable> — the firmware's own bootloader — with the
// new UKI, keeping only a <filename>.bak an operator had to restore by hand.
// Its doc claimed that was "no brick"; RCP v2 increment P0-b proved otherwise on
// VM 9002: a broken-but-validly-signed UKI written this way produced an
// unrecoverable panic-reboot loop (48 boots of the bad image, 24 kernel panics,
// zero automatic recovery) because systemd-boot — and with it the boot counter,
// the one-shot, and the default-entry fallback — had itself been overwritten.
// A node with no A/B layout now REFUSES the upgrade (see bootupgrade.Apply)
// instead. Do not reintroduce this without an out-of-band recovery path.

// WriteUKISlot installs the UKI at srcUKIPath as /EFI/Linux/<entryName> on the
// ESP (campaign 019f505f inc 3 A/B slots). entryBase (e.g. "powernode-b") is the
// slot's family: ALL of that slot's existing files (counterless + any stale
// boot-counter variants) are removed first, so a re-attempt can't collide with a
// leftover counter file (which would make systemd-boot skip counting and boot an
// unproven UKI without rollback). It does NOT touch the removable default
// (systemd-boot) or the OTHER slot — the other slot is the rollback target.
func WriteUKISlot(ctx context.Context, r mount.Runner, srcUKIPath, entryBase, entryName string) error {
	if _, statErr := os.Stat(srcUKIPath); statErr != nil {
		return fmt.Errorf("source UKI: %w", statErr)
	}
	return withMountedESP(ctx, r, func(mnt string) error {
		linuxDir := filepath.Join(mnt, "EFI", "Linux")
		if e := os.MkdirAll(linuxDir, 0o755); e != nil {
			return fmt.Errorf("mkdir %s: %w", linuxDir, e)
		}
		removeSlotFiles(linuxDir, entryBase) // clear stale variants of THIS slot
		dst := filepath.Join(linuxDir, entryName)
		tmp := dst + ".new"
		if e := copyFile(srcUKIPath, tmp); e != nil {
			return fmt.Errorf("stage slot UKI: %w", e)
		}
		if e := os.Rename(tmp, dst); e != nil {
			return fmt.Errorf("install slot UKI: %w", e)
		}
		return nil
	})
}

// BlessSlot marks a slot permanently good by stripping the systemd-boot
// boot-counter from its UKI filename (<base>+<n>-<m>.efi → <base>.efi) and
// removing any other counter variants. This is what stops systemd-boot counting
// the entry toward rollback — done HERE by the agent (health-gated) rather than
// systemd-bless-boot.service (masked), which can't run anyway (the ESP isn't
// mounted rw at /boot post-pivot and the binary isn't on PATH). Idempotent: a
// no-op if the counterless file already exists. Errors if the slot has no file.
func BlessSlot(ctx context.Context, r mount.Runner, entryBase string) error {
	return withMountedESP(ctx, r, func(mnt string) error {
		return blessSlotDir(filepath.Join(mnt, "EFI", "Linux"), entryBase)
	})
}

// blessSlotDir is the mount-relative bless: strip the boot-counter from a slot's
// UKI (rename <base>+*.efi → <base>.efi) and drop extra counter variants. Split
// out so the file logic is unit-testable against a temp dir (the exported
// BlessSlot requires a real UEFI node + mounted ESP).
func blessSlotDir(linuxDir, entryBase string) error {
	good := filepath.Join(linuxDir, entryBase+".efi")
	counters, _ := filepath.Glob(filepath.Join(linuxDir, entryBase+"+*.efi"))
	if len(counters) == 0 {
		if _, e := os.Stat(good); e == nil {
			return nil // already blessed
		}
		return fmt.Errorf("bless: no UKI for slot %s", entryBase)
	}
	if e := os.Rename(counters[0], good); e != nil {
		return fmt.Errorf("bless rename: %w", e)
	}
	for _, extra := range counters[1:] {
		_ = os.Remove(extra)
	}
	return nil
}

// CleanSlot removes a slot's boot-counter variants (a failed/rolled-back attempt's
// leftovers), leaving any counterless good file intact.
func CleanSlot(ctx context.Context, r mount.Runner, entryBase string) error {
	return withMountedESP(ctx, r, func(mnt string) error {
		removeSlotCounters(filepath.Join(mnt, "EFI", "Linux"), entryBase)
		return nil
	})
}

// SlotGoodExists reports whether the counterless (blessed) file for a slot is on
// the ESP — used to gate `bootctl set-default` so we never promote a name that
// points at nothing.
func SlotGoodExists(ctx context.Context, r mount.Runner, entryBase string) (bool, error) {
	found := false
	err := withMountedESP(ctx, r, func(mnt string) error {
		_, e := os.Stat(filepath.Join(mnt, "EFI", "Linux", entryBase+".efi"))
		found = e == nil
		return nil
	})
	return found, err
}

func removeSlotFiles(linuxDir, entryBase string) {
	_ = os.Remove(filepath.Join(linuxDir, entryBase+".efi"))
	removeSlotCounters(linuxDir, entryBase)
}

func removeSlotCounters(linuxDir, entryBase string) {
	matches, _ := filepath.Glob(filepath.Join(linuxDir, entryBase+"+*.efi"))
	for _, m := range matches {
		_ = os.Remove(m)
	}
}

// withMountedESP requires UEFI, locates + mounts the ESP (fresh rw when it isn't
// already mounted — post-switch_root the ESP is unmounted, so this is the write
// path), runs fn, syncs, and unmounts what it mounted.
func withMountedESP(ctx context.Context, r mount.Runner, fn func(mnt string) error) (err error) {
	if !IsUEFI() {
		return errors.New("not a UEFI node — refusing ESP write")
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
	if e := fn(mnt); e != nil {
		return e
	}
	if e := r.Run(ctx, "sync"); e != nil {
		return fmt.Errorf("sync ESP: %w", e)
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
