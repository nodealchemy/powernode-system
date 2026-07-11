package espwrite

import (
	"os"
	"path/filepath"
	"testing"
)

func touch(t *testing.T, dir, name string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), []byte("uki"), 0o644); err != nil {
		t.Fatal(err)
	}
}

func exists(dir, name string) bool {
	_, err := os.Stat(filepath.Join(dir, name))
	return err == nil
}

func TestBlessSlotDir_StripsCounterAndDropsExtras(t *testing.T) {
	dir := t.TempDir()
	// A partially-counted entry plus a stale counter variant.
	touch(t, dir, "powernode-b+2-1.efi")
	touch(t, dir, "powernode-b+0-3.efi") // stale bad from an earlier attempt
	touch(t, dir, "powernode-a.efi")     // the OTHER slot must be left alone

	if err := blessSlotDir(dir, "powernode-b"); err != nil {
		t.Fatalf("blessSlotDir: %v", err)
	}
	if !exists(dir, "powernode-b.efi") {
		t.Error("blessed slot should be renamed to the counterless good name")
	}
	if exists(dir, "powernode-b+2-1.efi") || exists(dir, "powernode-b+0-3.efi") {
		t.Error("all counter variants of the blessed slot must be gone")
	}
	if !exists(dir, "powernode-a.efi") {
		t.Error("the other slot must be untouched")
	}
}

func TestBlessSlotDir_IdempotentWhenAlreadyGood(t *testing.T) {
	dir := t.TempDir()
	touch(t, dir, "powernode-b.efi") // already blessed, no counter
	if err := blessSlotDir(dir, "powernode-b"); err != nil {
		t.Fatalf("bless of an already-good slot must be a no-op, got %v", err)
	}
	if !exists(dir, "powernode-b.efi") {
		t.Error("good file must remain")
	}
}

func TestBlessSlotDir_ErrorsWhenNoFile(t *testing.T) {
	dir := t.TempDir()
	if err := blessSlotDir(dir, "powernode-b"); err == nil {
		t.Fatal("bless must error when the slot has no UKI at all")
	}
}

func TestRemoveSlotFiles_ClearsWholeFamilyOnly(t *testing.T) {
	dir := t.TempDir()
	touch(t, dir, "powernode-b.efi")
	touch(t, dir, "powernode-b+3.efi")
	touch(t, dir, "powernode-b+1-2.efi")
	touch(t, dir, "powernode-a.efi")   // other slot
	touch(t, dir, "powernode-a+3.efi") // other slot

	removeSlotFiles(dir, "powernode-b")

	if exists(dir, "powernode-b.efi") || exists(dir, "powernode-b+3.efi") || exists(dir, "powernode-b+1-2.efi") {
		t.Error("all of slot b's files must be removed before a fresh write")
	}
	if !exists(dir, "powernode-a.efi") || !exists(dir, "powernode-a+3.efi") {
		t.Error("slot a must be untouched")
	}
}

func TestRemoveSlotCounters_KeepsGood(t *testing.T) {
	dir := t.TempDir()
	touch(t, dir, "powernode-b.efi")     // good — must survive
	touch(t, dir, "powernode-b+2-1.efi") // failed attempt — must go

	removeSlotCounters(dir, "powernode-b")

	if !exists(dir, "powernode-b.efi") {
		t.Error("counterless good file must survive a rollback cleanup")
	}
	if exists(dir, "powernode-b+2-1.efi") {
		t.Error("failed attempt's counter file must be removed")
	}
}
