package mount

import (
	"context"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"
)

func TestSortByPriority_StableLowToHigh(t *testing.T) {
	in := ModuleStack{
		{ID: "z", Digest: "sha256:z", Priority: 100},
		{ID: "a", Digest: "sha256:a", Priority: 50},
		{ID: "m", Digest: "sha256:m", Priority: 50},
	}
	out := in.SortByPriority()
	if out[0].ID != "a" || out[1].ID != "m" || out[2].ID != "z" {
		t.Errorf("sort = %v", []string{out[0].ID, out[1].ID, out[2].ID})
	}
}

func TestLowerDirString_HighestFirst(t *testing.T) {
	l := DefaultLayout()
	stack := ModuleStack{
		{ID: "low", Digest: "sha256:low", Priority: 10},
		{ID: "high", Digest: "sha256:high", Priority: 20},
	}
	got := LowerDirString(l, stack)
	highPath := l.ModuleMountPath("sha256:high")
	lowPath := l.ModuleMountPath("sha256:low")
	want := highPath + ":" + lowPath
	if got != want {
		t.Errorf("LowerDirString = %q; want %q", got, want)
	}
}

func TestSanitizeDigest(t *testing.T) {
	if got := sanitizeDigest("sha256:deadbeef"); got != "sha256_deadbeef" {
		t.Errorf("sanitizeDigest = %q", got)
	}
}

func TestLayout_Resolve(t *testing.T) {
	l := DefaultLayout()
	l.Root = "/tmp/test-root"
	r := l.Resolve()
	if !strings.HasPrefix(r.SysRoot, "/tmp/test-root/") {
		t.Errorf("Resolve did not prefix Root: %q", r.SysRoot)
	}
	if !strings.HasPrefix(r.ModuleMountPath("sha256:abc"), "/tmp/test-root/") {
		t.Errorf("ModuleMountPath did not pick up resolved Root")
	}
}

func TestEnsureUpperWorkDirs_RecordsMounts(t *testing.T) {
	dir := t.TempDir()
	l := DefaultLayout()
	l.Root = dir
	l = l.Resolve()

	rec := &RecorderRunner{}
	o := &Overlay{Layout: l, Runner: rec}
	if err := o.EnsureUpperWorkDirs(context.Background()); err != nil {
		t.Fatalf("EnsureUpperWorkDirs: %v", err)
	}

	mountCalls := []Invocation{}
	for _, inv := range rec.Invocations {
		if inv.Op == "Run" && inv.Name == "mount" {
			mountCalls = append(mountCalls, inv)
		}
	}
	if len(mountCalls) != 2 {
		t.Errorf("expected 2 tmpfs mount calls, got %d: %+v", len(mountCalls), mountCalls)
	}
	for _, mc := range mountCalls {
		if !contains(mc.Args, "tmpfs") {
			t.Errorf("expected -t tmpfs arg in: %v", mc.Args)
		}
	}
}

func TestMountUnion_BuildsCorrectOverlayArgs(t *testing.T) {
	dir := t.TempDir()
	l := DefaultLayout()
	l.Root = dir
	l = l.Resolve()

	rec := &RecorderRunner{}
	o := &Overlay{Layout: l, Runner: rec}
	stack := ModuleStack{
		{ID: "base", Digest: "sha256:base", Priority: 10},
		{ID: "app", Digest: "sha256:app", Priority: 20},
	}
	if err := o.MountUnion(context.Background(), stack); err != nil {
		t.Fatalf("MountUnion: %v", err)
	}

	// Find the overlay mount call (last mount call should be it)
	var overlayCall *Invocation
	for i := len(rec.Invocations) - 1; i >= 0; i-- {
		if rec.Invocations[i].Op == "Run" && rec.Invocations[i].Name == "mount" {
			if contains(rec.Invocations[i].Args, "overlay") {
				inv := rec.Invocations[i]
				overlayCall = &inv
				break
			}
		}
	}
	if overlayCall == nil {
		t.Fatal("no overlay mount call recorded")
	}
	joined := strings.Join(overlayCall.Args, " ")
	if !strings.Contains(joined, "lowerdir=") {
		t.Errorf("missing lowerdir in: %s", joined)
	}
	if !strings.Contains(joined, "upperdir="+l.UpperDir) {
		t.Errorf("missing upperdir in: %s", joined)
	}
	if !strings.Contains(joined, "redirect_dir=on") {
		t.Errorf("missing redirect_dir=on in: %s", joined)
	}
	// High-priority module should appear FIRST in lowerdir
	highPath := l.ModuleMountPath("sha256:app")
	lowPath := l.ModuleMountPath("sha256:base")
	if strings.Index(joined, highPath) > strings.Index(joined, lowPath) {
		t.Errorf("expected high-priority before low; got: %s", joined)
	}
}

func TestEnsurePersistentVar_BindMounts(t *testing.T) {
	dir := t.TempDir()
	l := DefaultLayout()
	l.Root = dir
	l = l.Resolve()
	rec := &RecorderRunner{}

	if err := EnsurePersistentVar(context.Background(), rec, l); err != nil {
		t.Fatalf("EnsurePersistentVar: %v", err)
	}
	// expect: findmnt (returns nonzero so "not mounted") + mount --bind ...
	found := false
	for _, inv := range rec.Invocations {
		if inv.Op == "Run" && inv.Name == "mount" && contains(inv.Args, "--bind") {
			found = true
		}
	}
	if !found {
		t.Errorf("no mount --bind call recorded; got: %+v", rec.Invocations)
	}
}

func TestSaveState_LoadState_RoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.json")
	want := &State{
		BootID:            "boot-abc",
		AgentVersion:      "0.1.0",
		UnionMounted:      true,
		PersistentVarBind: true,
		AttachedModules: []Module{
			{ID: "m1", Digest: "sha256:1", Priority: 5},
			{ID: "m2", Digest: "sha256:2", Priority: 10},
		},
	}
	if err := SaveState(path, want); err != nil {
		t.Fatalf("SaveState: %v", err)
	}
	got, err := LoadState(path)
	if err != nil {
		t.Fatalf("LoadState: %v", err)
	}
	if got.BootID != want.BootID || got.AgentVersion != want.AgentVersion {
		t.Errorf("got = %+v, want = %+v", got, want)
	}
	if !reflect.DeepEqual(got.AttachedModules, want.AttachedModules) {
		t.Errorf("AttachedModules: got %+v, want %+v", got.AttachedModules, want.AttachedModules)
	}
	if got.LastUpdated.IsZero() {
		t.Error("LastUpdated should have been stamped on Save")
	}
}

func TestLoadState_MissingFile_ReturnsZero(t *testing.T) {
	s, err := LoadState(filepath.Join(t.TempDir(), "nonexistent.json"))
	if err != nil {
		t.Fatalf("LoadState on missing file: %v", err)
	}
	if s == nil || len(s.AttachedModules) != 0 {
		t.Errorf("expected zero State, got %+v", s)
	}
}

func TestReconcile_DiffsCorrectly(t *testing.T) {
	current := &State{
		AttachedModules: []Module{
			{Digest: "sha256:keep", Priority: 1},
			{Digest: "sha256:drop", Priority: 2},
		},
	}
	desired := ModuleStack{
		{Digest: "sha256:keep", Priority: 1},
		{Digest: "sha256:add", Priority: 3},
	}
	toAttach, toDetach := Reconcile(current, desired)

	attachDigests := digests(toAttach)
	detachDigests := digests(toDetach)
	sort.Strings(attachDigests)
	sort.Strings(detachDigests)
	if !reflect.DeepEqual(attachDigests, []string{"sha256:add"}) {
		t.Errorf("toAttach = %v", attachDigests)
	}
	if !reflect.DeepEqual(detachDigests, []string{"sha256:drop"}) {
		t.Errorf("toDetach = %v", detachDigests)
	}
}

func TestReconcile_NilCurrent_AllAttach(t *testing.T) {
	desired := ModuleStack{
		{Digest: "sha256:a", Priority: 1},
		{Digest: "sha256:b", Priority: 2},
	}
	toAttach, toDetach := Reconcile(nil, desired)
	if len(toAttach) != 2 || len(toDetach) != 0 {
		t.Errorf("nil current: toAttach=%v toDetach=%v", toAttach, toDetach)
	}
}

func TestUnmountModule_NotMounted_NoOp(t *testing.T) {
	l := DefaultLayout()
	l.Root = t.TempDir()
	l = l.Resolve()
	rec := &RecorderRunner{}

	if err := UnmountModule(context.Background(), rec, l, "sha256:nope"); err != nil {
		t.Fatalf("UnmountModule should be no-op: %v", err)
	}
	for _, inv := range rec.Invocations {
		if inv.Op == "Run" && inv.Name == "umount" {
			t.Errorf("unexpected umount call when not mounted: %+v", inv)
		}
	}
}

func TestMountModule_MissingBlob_FailsClearly(t *testing.T) {
	l := DefaultLayout()
	l.Root = t.TempDir()
	l = l.Resolve()
	rec := &RecorderRunner{}

	err := MountModule(context.Background(), rec, l, Module{Digest: "sha256:missing"})
	if err == nil {
		t.Fatal("expected error for missing blob")
	}
	if !strings.Contains(err.Error(), "composefs blob missing") {
		t.Errorf("error message = %q", err.Error())
	}
}

func TestMountModule_AlreadyMounted_NoOp(t *testing.T) {
	// Idempotency: when findmnt reports the mountpoint is already a mount,
	// MountModule must skip the actual `mount -t composefs` invocation.
	l := DefaultLayout()
	l.Root = t.TempDir()
	l = l.Resolve()
	digest := "sha256:abc"
	mountpoint := l.ModuleMountPath(digest)

	rec := &RecorderRunner{
		StubOutput: map[string][]byte{
			"findmnt --noheadings " + mountpoint: []byte(mountpoint + " composefs ro,...\n"),
		},
	}
	if err := MountModule(context.Background(), rec, l, Module{Digest: digest}); err != nil {
		t.Fatalf("MountModule: %v", err)
	}
	for _, inv := range rec.Invocations {
		if inv.Op == "Run" && inv.Name == "mount" {
			t.Errorf("expected no mount call when already mounted; got: %+v", inv)
		}
	}
}

func TestMountModule_WithBlob_IssuesComposefsMount(t *testing.T) {
	l := DefaultLayout()
	l.Root = t.TempDir()
	l = l.Resolve()

	// Stage a fake .cfs blob so the existence check passes
	digest := "sha256:abc"
	if err := os.MkdirAll(l.ModulesCacheRoot, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(l.ModuleCachePath(digest), []byte("fake cfs"), 0o644); err != nil {
		t.Fatal(err)
	}

	rec := &RecorderRunner{}
	if err := MountModule(context.Background(), rec, l, Module{Digest: digest, ID: "m1"}); err != nil {
		t.Fatalf("MountModule: %v", err)
	}
	found := false
	for _, inv := range rec.Invocations {
		if inv.Op == "Run" && inv.Name == "mount" && contains(inv.Args, "composefs") {
			found = true
			if !contains(inv.Args, "basedir="+l.DigestStorePath()) {
				t.Errorf("expected basedir arg with %s, got %v", l.DigestStorePath(), inv.Args)
			}
		}
	}
	if !found {
		t.Errorf("no composefs mount call recorded; got %+v", rec.Invocations)
	}
}

// ---------- helpers ----------

func contains(haystack []string, needle string) bool {
	for _, h := range haystack {
		if strings.Contains(h, needle) {
			return true
		}
	}
	return false
}

func digests(s ModuleStack) []string {
	out := make([]string, 0, len(s))
	for _, m := range s {
		out = append(out, m.Digest)
	}
	return out
}
