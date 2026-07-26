package espwrite

import (
	"context"
	"os"
	"path/filepath"
	"strings"
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

// Risk 1 from the INV-8 review: after an a→b promote, LoaderEntryDefault (an EFI
// variable in the efidisk varstore) was the ONLY record that b is active —
// loader.conf still named a, so losing the varstore silently reverted the node.
func TestSetLoaderDefaultRewritesDefaultLine(t *testing.T) {
	mnt := t.TempDir()
	if err := os.MkdirAll(filepath.Join(mnt, "loader"), 0o755); err != nil {
		t.Fatal(err)
	}
	conf := filepath.Join(mnt, "loader", "loader.conf")
	if err := os.WriteFile(conf, []byte("timeout 3\ndefault powernode-a*\neditor  no\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := setLoaderDefaultDir(mnt, "powernode-b"); err != nil {
		t.Fatalf("setLoaderDefaultDir: %v", err)
	}
	got, err := os.ReadFile(conf)
	if err != nil {
		t.Fatal(err)
	}
	s := string(got)
	if !strings.Contains(s, "default powernode-b.efi") {
		t.Errorf("default not repointed at slot b:\n%s", s)
	}
	if strings.Contains(s, "powernode-a*") {
		t.Errorf("stale slot-a default survived:\n%s", s)
	}
	// Unrelated directives must be preserved.
	for _, want := range []string{"timeout 3", "editor  no"} {
		if !strings.Contains(s, want) {
			t.Errorf("clobbered unrelated directive %q:\n%s", want, s)
		}
	}
	// No staging litter left behind.
	if _, err := os.Stat(conf + ".new"); !os.IsNotExist(err) {
		t.Errorf("loader.conf.new left on the ESP")
	}
}

func TestSetLoaderDefaultToleratesMissingLoaderConf(t *testing.T) {
	// A missing loader.conf must not fail an otherwise-successful promote —
	// systemd-boot falls back to the EFI variable, i.e. today's behaviour.
	if err := setLoaderDefaultDir(t.TempDir(), "powernode-b"); err != nil {
		t.Fatalf("expected nil for missing loader.conf, got %v", err)
	}
}

// Risk 4: a failed slot write leaves <name>.efi.new litter that the counter glob
// never matched. Observed live — an 83MB powernode-b+3.efi.new stranded on the
// ESP after a write that failed at sync.
func TestRemoveSlotCountersAlsoRemovesStagingLitter(t *testing.T) {
	dir := t.TempDir()
	keep := filepath.Join(dir, "powernode-a.efi")
	litter := []string{"powernode-b+3.efi", "powernode-b+3.efi.new", "powernode-b.efi.new"}
	if err := os.WriteFile(keep, []byte("A"), 0o644); err != nil {
		t.Fatal(err)
	}
	for _, f := range litter {
		if err := os.WriteFile(filepath.Join(dir, f), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	removeSlotCounters(dir, "powernode-b")
	for _, f := range litter {
		if _, err := os.Stat(filepath.Join(dir, f)); !os.IsNotExist(err) {
			t.Errorf("%s survived removeSlotCounters", f)
		}
	}
	if _, err := os.Stat(keep); err != nil {
		t.Errorf("the other slot's good file was removed: %v", err)
	}
}

// Risk 5 from the INV-8 review: the rollback-target refusal (Apply bails when
// the ACTIVE slot has no blessed UKI) was exercised only incidentally. This
// covers the predicate that gates it. A slot holding only counter-suffixed
// files is NOT a valid rollback target — systemd-boot may still count it bad,
// so falling back to it is not guaranteed to boot.
func TestSlotGoodExistsDirRequiresTheCounterlessFile(t *testing.T) {
	dir := t.TempDir()

	if slotGoodExistsDir(dir, "powernode-a") {
		t.Error("empty slot reported as a good rollback target")
	}

	// Counter-suffixed only: still NOT good.
	if err := os.WriteFile(filepath.Join(dir, "powernode-a+3.efi"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if slotGoodExistsDir(dir, "powernode-a") {
		t.Error("slot with only a counter-suffixed UKI reported as a good rollback target")
	}

	// Blessed (counterless) file present: good.
	if err := os.WriteFile(filepath.Join(dir, "powernode-a.efi"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if !slotGoodExistsDir(dir, "powernode-a") {
		t.Error("blessed slot not reported as a good rollback target")
	}

	// Must not be fooled by the OTHER slot being blessed.
	if slotGoodExistsDir(dir, "powernode-b") {
		t.Error("slot b reported good on the strength of slot a's file")
	}
}
