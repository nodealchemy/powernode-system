package bootslots

import (
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
