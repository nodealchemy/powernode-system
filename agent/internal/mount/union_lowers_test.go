package mount

import (
	"os"
	"path/filepath"
	"testing"
)

// withMountInfo points the parser at a fixture for the duration of a test.
func withMountInfo(t *testing.T, body string) {
	t.Helper()
	p := filepath.Join(t.TempDir(), "mountinfo")
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
	orig := mountInfoPath
	mountInfoPath = p
	t.Cleanup(func() { mountInfoPath = orig })
}

// A real pivot node's line, trimmed: / is an overlay whose lowerdir names
// the module mount paths composed at boot.
const pivotRootMountInfo = `21 27 0:20 / /proc rw,nosuid,relatime shared:5 - proc proc rw
25 27 0:23 / /sys rw,nosuid,relatime shared:7 - sysfs sysfs rw
27 1 0:24 / / rw,relatime shared:1 - overlay overlay rw,lowerdir=/run/powernode/modules/sha256_aaa:/run/powernode/modules/sha256_bbb:/run/powernode/modules/sha256_ccc,upperdir=/run/powernode/scratch/upper,workdir=/run/powernode/scratch/work,redirect_dir=on,metacopy=on
30 27 8:2 /persist /persist rw,noatime shared:2 - ext4 /dev/sda2 rw
`

func TestLiveUnionLowerDirs_ParsesPivotRoot(t *testing.T) {
	withMountInfo(t, pivotRootMountInfo)
	got, err := LiveUnionLowerDirs("/")
	if err != nil {
		t.Fatalf("LiveUnionLowerDirs: %v", err)
	}
	want := []string{
		"/run/powernode/modules/sha256_aaa",
		"/run/powernode/modules/sha256_bbb",
		"/run/powernode/modules/sha256_ccc",
	}
	if len(got) != len(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			// Order matters: it is the union's resolution order.
			t.Errorf("layer %d = %s, want %s", i, got[i], want[i])
		}
	}
}

// A node whose / is NOT an overlay (the cloud_init model) must report no
// layers WITHOUT an error — that is a normal topology, not a failure.
func TestLiveUnionLowerDirs_NonOverlayRootIsNotAnError(t *testing.T) {
	withMountInfo(t, "27 1 8:1 / / rw,relatime shared:1 - ext4 /dev/sda1 rw\n")
	got, err := LiveUnionLowerDirs("/")
	if err != nil {
		t.Fatalf("a non-overlay root must not error: %v", err)
	}
	if len(got) != 0 {
		t.Errorf("got %v, want no layers", got)
	}
}

// An unreadable mount table must ERROR rather than report "no layers" —
// callers key a destructive decision off this and must be able to tell
// "nothing referenced" from "I could not tell".
func TestLiveUnionLowerDirs_UnreadableTableErrors(t *testing.T) {
	orig := mountInfoPath
	mountInfoPath = filepath.Join(t.TempDir(), "definitely-absent")
	t.Cleanup(func() { mountInfoPath = orig })

	if _, err := LiveUnionLowerDirs("/"); err == nil {
		t.Error("a missing mount table must error, not report an empty layer set")
	}
}

func TestPathInLiveUnion(t *testing.T) {
	withMountInfo(t, pivotRootMountInfo)
	for _, c := range []struct {
		dir  string
		want bool
	}{
		{"/run/powernode/modules/sha256_bbb", true},
		{"/run/powernode/modules/sha256_bbb/", true}, // trailing slash still matches
		{"/run/powernode/modules/sha256_zzz", false},
		{"/run/powernode/modules", false}, // a parent is not a layer
	} {
		got, err := PathInLiveUnion("/", c.dir)
		if err != nil {
			t.Fatalf("PathInLiveUnion(%s): %v", c.dir, err)
		}
		if got != c.want {
			t.Errorf("PathInLiveUnion(%q) = %v, want %v", c.dir, got, c.want)
		}
	}
}

// Only the overlay at the REQUESTED mount point counts. A nextroot union
// mounted elsewhere must not be mistaken for the live root's.
func TestLiveUnionLowerDirs_IgnoresOtherOverlays(t *testing.T) {
	withMountInfo(t, pivotRootMountInfo+
		"99 27 0:99 / /run/nextroot rw,relatime - overlay overlay rw,lowerdir=/run/powernode/modules/sha256_zzz,upperdir=/x,workdir=/y\n")

	got, err := LiveUnionLowerDirs("/")
	if err != nil {
		t.Fatalf("LiveUnionLowerDirs: %v", err)
	}
	for _, l := range got {
		if l == "/run/powernode/modules/sha256_zzz" {
			t.Error("picked up a layer from an overlay at a different mount point")
		}
	}
	next, err := LiveUnionLowerDirs("/run/nextroot")
	if err != nil || len(next) != 1 || next[0] != "/run/powernode/modules/sha256_zzz" {
		t.Errorf("nextroot lowers = %v (err %v), want exactly its own layer", next, err)
	}
}

// The kernel escapes characters that would break field splitting; a mount
// point containing a space must still match.
func TestLiveUnionLowerDirs_HandlesEscapedMountPoint(t *testing.T) {
	withMountInfo(t, "27 1 0:24 / /mnt/od\\040d rw,relatime - overlay overlay rw,lowerdir=/a:/b,upperdir=/u,workdir=/w\n")
	got, err := LiveUnionLowerDirs("/mnt/od d")
	if err != nil {
		t.Fatalf("LiveUnionLowerDirs: %v", err)
	}
	if len(got) != 2 || got[0] != "/a" {
		t.Errorf("got %v, want [/a /b]", got)
	}
}
