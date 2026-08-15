package mount

import (
	"path/filepath"
	"strings"
	"testing"
)

// A carrier bind with children two levels deep, a sibling elsewhere in the
// tree, and a path-prefix LOOKALIKE (/run/nextroot/persistent) that string
// matching would swallow but the parent-id walk must not.
const submountFixture = `27 1 8:1 / / rw,relatime shared:1 - ext4 /dev/sda1 rw
40 27 8:2 / /persist rw,relatime shared:2 - ext4 /dev/sda2 rw
90 27 8:2 / /run/nextroot/persist rw,relatime shared:2 - ext4 /dev/sda2 rw
91 27 8:9 / /run/nextroot/persistent rw,relatime shared:8 - ext4 /dev/sda9 rw
95 90 8:16 / /run/nextroot/persist/volumes/pgdata rw,relatime shared:12 - ext4 /dev/sdb1 rw
96 95 8:17 / /run/nextroot/persist/volumes/pgdata/wal rw,relatime shared:13 - ext4 /dev/sdb2 rw
`

func TestSubmountsBeneath_WalksTransitiveChildrenByParentID(t *testing.T) {
	withMountInfo(t, submountFixture)
	got, err := SubmountsBeneath("/run/nextroot/persist")
	if err != nil {
		t.Fatalf("SubmountsBeneath: %v", err)
	}
	want := []string{
		"/run/nextroot/persist/volumes/pgdata",
		"/run/nextroot/persist/volumes/pgdata/wal", // depth 2 — the walk must be transitive
	}
	if len(got) != len(want) {
		t.Fatalf("want %v, got %v", want, got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("want %v, got %v", want, got)
		}
	}
}

// Membership is the kernel's parent-id graph, not a string prefix.
// /run/nextroot/persistent shares the prefix but hangs off / — a walk that
// path-matched would probe a unit that has nothing to do with the rbind.
func TestSubmountsBeneath_IgnoresAPathPrefixLookalike(t *testing.T) {
	withMountInfo(t, submountFixture)
	got, err := SubmountsBeneath("/run/nextroot/persist")
	if err != nil {
		t.Fatalf("SubmountsBeneath: %v", err)
	}
	for _, p := range got {
		if p == "/run/nextroot/persistent" {
			t.Fatalf("prefix lookalike leaked into the walk: %v", got)
		}
	}
}

// Dest mounted, kernel holds nothing beneath it: the ONE case where an
// empty result is a real answer rather than the ([], nil) ambiguity this
// package has been bitten by — absence of the dest itself errors instead
// (TestSubmountsBeneath_ErrorsWhenTheMountPointHasNoEntry).
func TestSubmountsBeneath_ChildlessMountYieldsEmptyAndNoError(t *testing.T) {
	withMountInfo(t, submountFixture)
	got, err := SubmountsBeneath("/persist")
	if err != nil {
		t.Fatalf("SubmountsBeneath: %v", err)
	}
	if len(got) != 0 {
		t.Fatalf("childless /persist must yield no submounts, got %v", got)
	}
}

func TestSubmountsBeneath_ErrorsWhenTheMountPointHasNoEntry(t *testing.T) {
	withMountInfo(t, submountFixture)
	_, err := SubmountsBeneath("/run/nextroot/etcd")
	if err == nil || !strings.Contains(err.Error(), "/run/nextroot/etcd") {
		t.Fatalf("an absent mount point must error naming it — absence is unknowable, not empty; got %v", err)
	}
}

func TestSubmountsBeneath_ErrorsWhenTheTableCannotBeRead(t *testing.T) {
	restore := SetMountInfoPathForTest(filepath.Join(t.TempDir(), "does-not-exist"))
	t.Cleanup(restore)
	if _, err := SubmountsBeneath("/run/nextroot/persist"); err == nil {
		t.Fatal("an unreadable table must error, not report no submounts")
	}
}

// Every malformed-line shape errors. LiveUnionLowerDirs skips these same
// lines by design; here any one of them could BE the submount the caller
// needs to know about, so a skip is a silent pass. (Right-half-ONLY
// defects are the deliberate exception —
// TestSubmountsBeneath_ToleratesARightHalfOnlyDefect.)
func TestSubmountsBeneath_ErrorsOnAnyUnparseableLine(t *testing.T) {
	good := "90 27 8:2 / /run/nextroot/persist rw shared:2 - ext4 /dev/sda2 rw\n"
	cases := map[string]string{
		"no separator":         "27 1 8:1 / / rw,relatime shared:1 ext4 /dev/sda1 rw\n",
		"short left half":      "27 1 8:1 / - ext4 /dev/sda1 rw\n",
		"mount id not numeric": "xx 1 8:1 / / rw shared:1 - ext4 /dev/sda1 rw\n",
		"parent not numeric":   "27 yy 8:1 / / rw shared:1 - ext4 /dev/sda1 rw\n",
		"empty right half":     "27 1 8:1 / / rw shared:1 - \n",
	}
	for name, bad := range cases {
		t.Run(name, func(t *testing.T) {
			withMountInfo(t, good+bad)
			if _, err := SubmountsBeneath("/run/nextroot/persist"); err == nil {
				t.Fatal("a table with an unparseable line proves nothing and must error")
			}
		})
	}
}

// A defect confined to the RIGHT half of a line (fstype/source/superopts)
// must NOT fail the walk: the parent-id walk reads only the left half, and
// real kernels emit such lines — `mount -t tmpfs "" /x` (empty source,
// accepted by mount(2)) renders a double space that strings.Fields
// collapses to two right-half fields. Hard-erroring on it would let one
// unrelated exotic mount anywhere on the node permanently refuse the
// entire soft-reboot tier.
func TestSubmountsBeneath_ToleratesARightHalfOnlyDefect(t *testing.T) {
	withMountInfo(t,
		"27 1 8:1 / / rw,relatime shared:1 - ext4 /dev/sda1 rw\n"+
			"50 27 0:44 / /x rw shared:3 - tmpfs  rw\n"+ // empty source: two right-half fields
			"90 27 8:2 / /run/nextroot/persist rw shared:2 - ext4 /dev/sda2 rw\n")
	got, err := SubmountsBeneath("/run/nextroot/persist")
	if err != nil {
		t.Fatalf("a right-half-only defect on an unrelated line must not fail the walk, got %v", err)
	}
	if len(got) != 0 {
		t.Fatalf("no submounts beneath the carrier, got %v", got)
	}
}

// A line the scanner itself cannot deliver (over the 1MiB token cap) must
// surface as an error even when the dest was already found in an earlier
// line — a truncated read is not a complete table.
func TestSubmountsBeneath_ErrorsWhenTheScannerTruncates(t *testing.T) {
	giant := "27 1 8:1 / / rw " + strings.Repeat("x", 2<<20) + " - ext4 /dev/sda1 rw\n"
	withMountInfo(t, "90 27 8:2 / /run/nextroot/persist rw shared:2 - ext4 /dev/sda2 rw\n"+giant)
	if _, err := SubmountsBeneath("/run/nextroot/persist"); err == nil {
		t.Fatal("a table the scanner could not fully read must error")
	}
}

// An overmount AT the destination is traversed — its children are
// genuinely beneath — but the overmount itself is not reported: it is the
// same path the caller already probes.
func TestSubmountsBeneath_TraversesAnOvermountWithoutReportingIt(t *testing.T) {
	withMountInfo(t,
		"27 1 8:1 / / rw,relatime shared:1 - ext4 /dev/sda1 rw\n"+
			"90 27 8:2 / /run/nextroot/persist rw shared:2 - ext4 /dev/sda2 rw\n"+
			"93 90 8:5 / /run/nextroot/persist rw shared:4 - ext4 /dev/sda5 rw\n"+ // overmount, child of 90
			"95 93 8:16 / /run/nextroot/persist/volumes/pgdata rw shared:12 - ext4 /dev/sdb1 rw\n")
	got, err := SubmountsBeneath("/run/nextroot/persist")
	if err != nil {
		t.Fatalf("SubmountsBeneath: %v", err)
	}
	if len(got) != 1 || got[0] != "/run/nextroot/persist/volumes/pgdata" {
		t.Fatalf("want exactly the overmount's child, got %v", got)
	}
}

// A parent-id cycle (corrupt table) must terminate, not spin — the seen
// guard is load-bearing.
func TestSubmountsBeneath_TerminatesOnAParentIDCycle(t *testing.T) {
	withMountInfo(t,
		"90 95 8:2 / /run/nextroot/persist rw shared:2 - ext4 /dev/sda2 rw\n"+
			"95 90 8:16 / /run/nextroot/persist/volumes/pgdata rw shared:12 - ext4 /dev/sdb1 rw\n")
	got, err := SubmountsBeneath("/run/nextroot/persist")
	if err != nil {
		t.Fatalf("SubmountsBeneath: %v", err)
	}
	if len(got) != 1 || got[0] != "/run/nextroot/persist/volumes/pgdata" {
		t.Fatalf("want the one real child despite the cycle, got %v", got)
	}
}

// Kernel octal escapes in a submount's path are decoded, so the caller
// derives the systemd unit name from the real path.
func TestSubmountsBeneath_UnescapesSubmountPaths(t *testing.T) {
	withMountInfo(t,
		"90 27 8:2 / /run/nextroot/persist rw shared:2 - ext4 /dev/sda2 rw\n"+
			`95 90 8:16 / /run/nextroot/persist/my\040vol rw shared:12 - ext4 /dev/sdb1 rw`+"\n")
	got, err := SubmountsBeneath("/run/nextroot/persist")
	if err != nil {
		t.Fatalf("SubmountsBeneath: %v", err)
	}
	if len(got) != 1 || got[0] != "/run/nextroot/persist/my vol" {
		t.Fatalf("want the unescaped path, got %v", got)
	}
}
