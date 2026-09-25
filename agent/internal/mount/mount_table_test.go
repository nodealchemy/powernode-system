package mount

import (
	"errors"
	"reflect"
	"strings"
	"testing"
)

// A union assembled through the fsconfig API can list one `lowerdir+=` per
// layer instead of one colon-joined `lowerdir=`. Reading only the classic
// spelling returned an EMPTY layer set for it — "no layers", which the detach
// guard and the state rebase both read as "not in use".
const pivotRootLowerdirPlus = `27 1 0:24 / / rw,relatime shared:1 - overlay overlay rw,lowerdir+=/run/powernode/modules/sha256_aaa,lowerdir+=/run/powernode/modules/sha256_bbb,upperdir=/run/powernode/scratch/upper,workdir=/run/powernode/scratch/work
30 27 8:2 /persist /persist rw,noatime shared:2 - ext4 /dev/sda2 rw
`

func TestLiveUnionLowerDirs_ParsesLowerdirPlusSpelling(t *testing.T) {
	withMountInfo(t, pivotRootLowerdirPlus)
	got, err := LiveUnionLowerDirs("/")
	if err != nil {
		t.Fatalf("LiveUnionLowerDirs: %v", err)
	}
	want := []string{"/run/powernode/modules/sha256_aaa", "/run/powernode/modules/sha256_bbb"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("lowerdir+= union: got %v, want %v", got, want)
	}
	in, err := PathInLiveUnion("/", "/run/powernode/modules/sha256_bbb")
	if err != nil || !in {
		t.Fatalf("PathInLiveUnion over a lowerdir+= union = %v, %v; want true, nil", in, err)
	}
}

func TestMountTable_IsMountedAndLowers(t *testing.T) {
	withMountInfo(t, pivotRootMountInfo)
	tab, err := ReadMountTableStrict()
	if err != nil {
		t.Fatalf("ReadMountTableStrict: %v", err)
	}
	if !tab.IsMounted("/persist") || tab.IsMounted("/run/powernode/modules/sha256_zzz") {
		t.Errorf("IsMounted: /persist must be mounted and sha256_zzz must not")
	}
	lowers, err := tab.OverlayLowerDirs("/")
	if err != nil || len(lowers) != 3 {
		t.Fatalf("OverlayLowerDirs(/) = %v, %v; want 3 layers", lowers, err)
	}
	if _, err := tab.OverlayLowerDirs("/persist"); !errors.Is(err, ErrNoOverlayAt) {
		t.Errorf("OverlayLowerDirs on a non-overlay mount: err = %v, want ErrNoOverlayAt", err)
	}
}

// The tolerant reader skips a line it cannot parse; the strict table must not,
// because the skipped line could be the very mount being asked about.
func TestMountTable_UnparseableLineIsAnError(t *testing.T) {
	withMountInfo(t, pivotRootMountInfo+"garbage line without a separator\n")
	if _, err := ReadMountTableStrict(); err == nil {
		t.Fatal("ReadMountTableStrict accepted an unparseable line")
	}
	// Control: the tolerant reader still answers from the same table.
	if _, err := LiveUnionLowerDirs("/"); err != nil {
		t.Fatalf("control: tolerant reader failed on the same table: %v", err)
	}
}

func TestMountTable_UnreadableTableIsAnError(t *testing.T) {
	restore := SetMountInfoPathForTest("/nonexistent/mountinfo")
	defer restore()
	if _, err := ReadMountTableStrict(); err == nil {
		t.Fatal("ReadMountTableStrict returned no error for an unreadable table")
	}
}

func TestMountTable_StackedOverlaysAreAmbiguous(t *testing.T) {
	second := strings.Replace(strings.SplitN(pivotRootMountInfo, "\n", 4)[2], "27 1 0:24", "99 27 0:99", 1)
	withMountInfo(t, pivotRootMountInfo+second+"\n")
	tab, err := ReadMountTableStrict()
	if err != nil {
		t.Fatalf("ReadMountTableStrict: %v", err)
	}
	if _, err := tab.OverlayLowerDirs("/"); err == nil {
		t.Fatal("two overlays stacked at / must be an error, not a guess")
	}
}
