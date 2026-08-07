package runtime

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/lifecycle"
	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// detachGuardFixture builds a Reconciler whose mount commands are recorded, with
// a mountinfo fixture describing a pivot root whose union references
// modulesRoot/sha256_live.
func detachGuardFixture(t *testing.T, mountInfo string) (*Reconciler, *mount.RecorderRunner, *[]string) {
	t.Helper()
	layout := mount.Layout{Root: "/", ModulesMountRoot: "/run/powernode/modules"}
	// findmnt must report these paths as mounted. Without this
	// UnmountModule short-circuits in IsMountpoint and never reaches the
	// umount — which would make every assertion below pass whether or not
	// the guard exists (they did, until this was added).
	run := &mount.RecorderRunner{StubOutput: map[string][]byte{
		"findmnt --noheadings /run/powernode/modules/sha256_live":         []byte("/run/powernode/modules/sha256_live erofs\n"),
		"findmnt --noheadings /run/powernode/modules/sha256_unreferenced": []byte("/run/powernode/modules/sha256_unreferenced erofs\n"),
	}}
	var signals []string
	r := &Reconciler{cfg: ReconcilerConfig{
		Layout:      layout,
		MountRunner: run,
		OnError:     func(stage string, err error) { signals = append(signals, stage+": "+err.Error()) },
	}}
	p := filepath.Join(t.TempDir(), "mountinfo")
	if err := os.WriteFile(p, []byte(mountInfo), 0o644); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
	t.Cleanup(mount.SetMountInfoPathForTest(p))
	return r, run, &signals
}

const liveUnionInfo = "27 1 0:24 / / rw,relatime shared:1 - overlay overlay rw," +
	"lowerdir=/run/powernode/modules/sha256_live:/run/powernode/modules/sha256_other," +
	"upperdir=/run/powernode/scratch/upper,workdir=/run/powernode/scratch/work\n"

func umountWasCalled(run *mount.RecorderRunner) bool {
	for _, inv := range run.Invocations {
		if strings.Contains(inv.Name, "umount") {
			return true
		}
		for _, a := range inv.Args {
			if strings.Contains(a, "umount") {
				return true
			}
		}
	}
	return false
}

func pinDetachMode(t *testing.T, m lifecycle.RootMode) {
	t.Helper()
	orig := pivotAwareRootMode
	pivotAwareRootMode = func() lifecycle.RootMode { return m }
	t.Cleanup(func() { pivotAwareRootMode = orig })
}

// THE REGRESSION. On a pivot node the live union's lowerdir is frozen at
// boot, so unmounting a layer it still names strips those files from the
// RUNNING root — silently. Detach must leave that mount alone.
func TestDetachModule_KeepsLayerStillInLiveUnion(t *testing.T) {
	pinDetachMode(t, lifecycle.RootModeNative)
	r, run, signals := detachGuardFixture(t, liveUnionInfo)

	err := r.detachModule(context.Background(), &mount.State{},
		mount.Module{ID: "runtime-go", Digest: "sha256:live"},
		map[string]*manifest.Manifest{})
	if err != nil {
		t.Fatalf("detachModule: %v", err)
	}
	if umountWasCalled(run) {
		t.Fatal("unmounted a layer the live union still references — this is the bug that deleted a live node's Go toolchain")
	}
	found := false
	for _, s := range *signals {
		if strings.Contains(s, "unmount_skipped") {
			found = true
		}
	}
	if !found {
		t.Errorf("skipping an unmount must be surfaced, got %v", *signals)
	}
}

// A layer the union does NOT reference is genuinely unused; reclaim it.
func TestDetachModule_UnmountsLayerNotInLiveUnion(t *testing.T) {
	pinDetachMode(t, lifecycle.RootModeNative)
	r, run, _ := detachGuardFixture(t, liveUnionInfo)

	if err := r.detachModule(context.Background(), &mount.State{},
		mount.Module{ID: "gone", Digest: "sha256:unreferenced"},
		map[string]*manifest.Manifest{}); err != nil {
		t.Fatalf("detachModule: %v", err)
	}
	if !umountWasCalled(run) {
		t.Error("a layer absent from the live union must still be unmounted — otherwise loop devices leak forever")
	}
}

// FAIL CLOSED. If the mount table cannot be read we cannot prove the layer
// is unreferenced, and the asymmetry says keep it.
func TestDetachModule_UnreadableMountTableKeepsTheMount(t *testing.T) {
	pinDetachMode(t, lifecycle.RootModeNative)
	r, run, signals := detachGuardFixture(t, liveUnionInfo)
	t.Cleanup(mount.SetMountInfoPathForTest(filepath.Join(t.TempDir(), "absent")))

	if err := r.detachModule(context.Background(), &mount.State{},
		mount.Module{ID: "x", Digest: "sha256:live"},
		map[string]*manifest.Manifest{}); err != nil {
		t.Fatalf("detachModule: %v", err)
	}
	if umountWasCalled(run) {
		t.Fatal("unmounted despite being unable to read the mount table — must fail closed")
	}
	found := false
	for _, s := range *signals {
		if strings.Contains(s, "cannot read the live mount table") {
			found = true
		}
	}
	if !found {
		t.Errorf("the fail-closed reason must be surfaced, got %v", *signals)
	}
}

// Chroot (cloud_init) nodes DO recompose the union at SysRoot on every
// stack change, so the old behaviour is correct there and must be kept.
func TestDetachModule_ChrootModeStillUnmounts(t *testing.T) {
	pinDetachMode(t, lifecycle.RootModeChroot)
	r, run, _ := detachGuardFixture(t, liveUnionInfo)

	if err := r.detachModule(context.Background(), &mount.State{},
		mount.Module{ID: "runtime-go", Digest: "sha256:live"},
		map[string]*manifest.Manifest{}); err != nil {
		t.Fatalf("detachModule: %v", err)
	}
	if !umountWasCalled(run) {
		t.Error("chroot mode recomposes the union, so the superseded layer must still be unmounted")
	}
}
