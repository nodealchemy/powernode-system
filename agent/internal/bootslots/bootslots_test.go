package bootslots

import (
	"os"
	"path/filepath"
	"testing"
)

func TestOther(t *testing.T) {
	if Other(SlotA) != SlotB || Other(SlotB) != SlotA {
		t.Fatal("Other must flip a<->b")
	}
	// Unknown defaults to B (so the first upgrade off an unrecognized state
	// still targets a distinct slot).
	if Other("x") != SlotB {
		t.Fatalf("Other(unknown) = %q, want b", Other("x"))
	}
}

func TestEntryName(t *testing.T) {
	cases := []struct {
		slot  string
		tries int
		want  string
	}{
		{SlotA, 3, "powernode-a+3.efi"},
		{SlotB, 3, "powernode-b+3.efi"},
		{SlotA, 0, "powernode-a.efi"},  // permanent-good (no counter)
		{SlotB, -1, "powernode-b.efi"}, // tries<=0 → no counter
	}
	for _, c := range cases {
		if got := EntryName(c.slot, c.tries); got != c.want {
			t.Errorf("EntryName(%q,%d) = %q, want %q", c.slot, c.tries, got, c.want)
		}
	}
}

func TestLoadDefaultAndRoundTrip(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "sub", "boot-slot.json") // sub dir must be created by Save

	// Absent → default active A, no pending.
	if s := LoadFrom(path); s.Active != SlotA || s.Pending != "" {
		t.Fatalf("default load = %+v, want {Active:a}", s)
	}

	// Round-trip a pending upgrade.
	in := State{Active: SlotA, Pending: SlotB, PendingSHA: "deadbeef"}
	if err := in.SaveTo(path); err != nil {
		t.Fatalf("save: %v", err)
	}
	got := LoadFrom(path)
	if got != in {
		t.Fatalf("round-trip = %+v, want %+v", got, in)
	}

	// Corrupt/invalid active → falls back to default rather than a bad slot.
	if err := (State{Active: "garbage"}).SaveTo(path); err != nil {
		t.Fatal(err)
	}
	if s := LoadFrom(path); s.Active != SlotA {
		t.Fatalf("invalid active should default to a, got %q", s.Active)
	}
}

// specLoaderGUID is the systemd-boot vendor GUID transcribed independently from
// the systemd Boot Loader Interface specification (and confirmed against a live
// node's /sys/firmware/efi/efivars). It is deliberately duplicated here rather
// than referencing loaderGUID, so that a typo in the production constant fails
// this test instead of silently agreeing with itself.
const specLoaderGUID = "4a67b082-0a4c-41cf-b6c7-440b29bb8c4f"

func TestLoaderGUIDMatchesSpec(t *testing.T) {
	if loaderGUID != specLoaderGUID {
		t.Fatalf("loaderGUID = %q, want %q.\n"+
			"A wrong GUID makes BootedViaSystemdBoot() false on EVERY node, which "+
			"silently disables A/B boot-counter rollback and routes upgrades into "+
			"the single-slot bootloader-overwrite path (bricked VM 9002, 2026-07-25).",
			loaderGUID, specLoaderGUID)
	}
}

// TestBootedViaSystemdBootDetectsRealLoaderInfo is the regression guard that
// would have caught the 2026-07-25 brick: it creates the efivar under the name
// systemd-boot really uses and asserts detection succeeds. Asserting the
// constant alone is not enough — the filename construction must match too.
func TestBootedViaSystemdBootDetectsRealLoaderInfo(t *testing.T) {
	dir := t.TempDir()
	orig := efivarsDir
	efivarsDir = dir
	t.Cleanup(func() { efivarsDir = orig })

	if BootedViaSystemdBoot() {
		t.Fatal("BootedViaSystemdBoot() = true with an empty efivars dir, want false")
	}

	// Exactly how systemd-boot names it: LoaderInfo-<vendor GUID>.
	name := filepath.Join(dir, "LoaderInfo-"+specLoaderGUID)
	if err := os.WriteFile(name, []byte("systemd-boot 255.4"), 0o644); err != nil {
		t.Fatalf("write %s: %v", name, err)
	}

	if !BootedViaSystemdBoot() {
		t.Fatalf("BootedViaSystemdBoot() = false although %s exists — "+
			"detection does not match the real systemd-boot variable name", name)
	}
}
