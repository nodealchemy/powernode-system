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

// higherPriorityLayerDirs is the heart of the winner resolution that fixes
// the hot-add priority inversion, and it had no direct test — three
// mutants (include-self, drop-the-top-of-stack-return, reversed order) all
// survived the suite. It must return ONLY the modules that out-rank modID,
// highest first, matching mount.LowerDirString's order exactly.
func TestHigherPriorityLayerDirs_OnlyHigherHighestFirst(t *testing.T) {
	r, layout := captureFixture(t)
	desired := mount.ModuleStack{
		{ID: "low", Digest: "sha256:l", Priority: 10},
		{ID: "self", Digest: "sha256:s", Priority: 50},
		{ID: "mid", Digest: "sha256:m", Priority: 70},
		{ID: "high", Digest: "sha256:h", Priority: 90},
	}

	got := r.higherPriorityLayerDirs(desired, "self")

	want := []string{
		layout.ModuleMountPath("sha256:h"),
		layout.ModuleMountPath("sha256:m"),
	}
	if len(got) != len(want) {
		t.Fatalf("got %v, want exactly the two higher layers %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("layer %d = %s, want %s (must be highest-priority FIRST)", i, got[i], want[i])
		}
	}
	for _, d := range got {
		if d == layout.ModuleMountPath("sha256:s") {
			t.Error("the module being synced must never appear in its own higher-layer list")
		}
		if d == layout.ModuleMountPath("sha256:l") {
			t.Error("a LOWER-priority module must never be treated as a higher layer")
		}
	}
}

// Top of the stack out-ranks nobody.
func TestHigherPriorityLayerDirs_TopOfStackHasNone(t *testing.T) {
	r, _ := captureFixture(t)
	desired := mount.ModuleStack{
		{ID: "low", Digest: "sha256:l", Priority: 10},
		{ID: "top", Digest: "sha256:t", Priority: 99},
	}
	if got := r.higherPriorityLayerDirs(desired, "top"); len(got) != 0 {
		t.Errorf("highest-priority module must have no higher layers, got %v", got)
	}
}

// A module absent from the desired set has no defined position; returning
// a partial list would resolve winners against the wrong stack.
func TestHigherPriorityLayerDirs_UnknownModuleHasNone(t *testing.T) {
	r, _ := captureFixture(t)
	desired := mount.ModuleStack{{ID: "a", Digest: "sha256:a", Priority: 10}}
	if got := r.higherPriorityLayerDirs(desired, "not-in-stack"); len(got) != 0 {
		t.Errorf("module absent from desired must yield no higher layers, got %v", got)
	}
}

// Ties must resolve the SAME way SortByPriority breaks them (equal
// priority → higher ID sits closer to the union top), or the live root
// disagrees with what the union serves.
func TestHigherPriorityLayerDirs_TieBreakMatchesSortByPriority(t *testing.T) {
	r, layout := captureFixture(t)
	desired := mount.ModuleStack{
		{ID: "aaa", Digest: "sha256:a", Priority: 50},
		{ID: "zzz", Digest: "sha256:z", Priority: 50},
	}
	got := r.higherPriorityLayerDirs(desired, "aaa")
	if len(got) != 1 || got[0] != layout.ModuleMountPath("sha256:z") {
		t.Errorf("got %v, want the same-priority higher-ID module to out-rank", got)
	}
	if other := r.higherPriorityLayerDirs(desired, "zzz"); len(other) != 0 {
		t.Errorf("the tie WINNER must have no higher layers, got %v", other)
	}
}
