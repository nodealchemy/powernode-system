package runtime

import (
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

func captureFixture(t *testing.T) (*Reconciler, mount.Layout) {
	t.Helper()
	layout := mount.Layout{ModulesMountRoot: t.TempDir()}
	return &Reconciler{cfg: ReconcilerConfig{
		Layout:  layout,
		OnError: func(string, error) {},
	}}, layout
}

// A module being REPLACED is inventoried; a module LEAVING the composition
// is not. The distinction matters because prune acts on the inventory: a
// full detach that got inventoried would delete the departing module's files
// off the live root immediately, racing an operator mid-reassignment, when
// the designed behaviour is for them to come out on the next recompose.
func TestCaptureOutgoingPaths_OnlyInventoriesReplacedModules(t *testing.T) {
	r, layout := captureFixture(t)
	replaced := mount.Module{ID: "dev-cell", Digest: "sha256:old"}
	leaving := mount.Module{ID: "retired-thing", Digest: "sha256:gone"}
	hpWriteFile(t, layout.ModuleMountPath(replaced.Digest), "etc/dropped.sh", "x")
	hpWriteFile(t, layout.ModuleMountPath(leaving.Digest), "etc/also-here", "y")

	out := r.captureOutgoingPaths(
		mount.ModuleStack{replaced, leaving},
		mount.ModuleStack{{ID: "dev-cell", Digest: "sha256:new"}},
		map[string]*manifest.Manifest{},
	)

	got, ok := out["dev-cell"]
	if !ok {
		t.Fatal("a module with a same-ID successor must be inventoried")
	}
	if !got["/etc/dropped.sh"] {
		t.Errorf("inventory missing the outgoing file: %v", got)
	}
	if _, ok := out["retired-thing"]; ok {
		t.Error("a module leaving the composition entirely must NOT be inventoried")
	}
}

// reboot_required modules short-circuit in hotReconcileIfNeeded long before
// the prune, so walking their (base-OS-sized) trees here is pure waste.
func TestCaptureOutgoingPaths_SkipsRebootRequired(t *testing.T) {
	r, layout := captureFixture(t)
	base := mount.Module{ID: "base-os", Digest: "sha256:oldbase"}
	hpWriteFile(t, layout.ModuleMountPath(base.Digest), "usr/bin/thing", "x")

	out := r.captureOutgoingPaths(
		mount.ModuleStack{base},
		mount.ModuleStack{{ID: "base-os", Digest: "sha256:newbase"}},
		map[string]*manifest.Manifest{"base-os": {RebootRequired: true}},
	)
	if _, ok := out["base-os"]; ok {
		t.Error("a reboot_required module must not be inventoried")
	}
}

// No detaches, or no attaches, means no version bump — nothing to inventory.
func TestCaptureOutgoingPaths_NoBumpCapturesNothing(t *testing.T) {
	r, _ := captureFixture(t)
	mod := mount.Module{ID: "x", Digest: "sha256:a"}
	if out := r.captureOutgoingPaths(nil, mount.ModuleStack{mod}, nil); out != nil {
		t.Errorf("no detaches must capture nothing, got %v", out)
	}
	if out := r.captureOutgoingPaths(mount.ModuleStack{mod}, nil, nil); out != nil {
		t.Errorf("no attaches must capture nothing, got %v", out)
	}
}

// survivingLayerDirs must exclude the module being updated and order the
// rest highest-priority first — the same order overlayfs resolves lowers in.
// Getting this backwards would resolve a dropped path to the wrong provider
// and rewrite the live root with a shadowed copy.
func TestSurvivingLayerDirs_ExcludesSelfAndOrdersHighestFirst(t *testing.T) {
	r, layout := captureFixture(t)
	desired := mount.ModuleStack{
		{ID: "low", Digest: "sha256:l", Priority: 10},
		{ID: "self", Digest: "sha256:s", Priority: 50},
		{ID: "high", Digest: "sha256:h", Priority: 90},
	}

	got := r.survivingLayerDirs(desired, "self")

	want := []string{
		layout.ModuleMountPath("sha256:h"),
		layout.ModuleMountPath("sha256:l"),
	}
	if len(got) != len(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("layer %d = %s, want %s", i, got[i], want[i])
		}
	}
}
