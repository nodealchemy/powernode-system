package mount

import (
	"context"
	"fmt"
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

	// Expect exactly ONE tmpfs mount call (for ScratchRoot). Upper +
	// work are subdirs of that single mount — overlayfs requires
	// upperdir and workdir under the same mount point.
	mountCalls := []Invocation{}
	for _, inv := range rec.Invocations {
		if inv.Op == "Run" && inv.Name == "mount" {
			mountCalls = append(mountCalls, inv)
		}
	}
	if len(mountCalls) != 1 {
		t.Errorf("expected 1 tmpfs mount call (ScratchRoot), got %d: %+v", len(mountCalls), mountCalls)
	}
	if len(mountCalls) > 0 {
		mc := mountCalls[0]
		if !contains(mc.Args, "tmpfs") {
			t.Errorf("expected -t tmpfs arg in: %v", mc.Args)
		}
		if !contains(mc.Args, l.ScratchRoot) {
			t.Errorf("expected ScratchRoot=%s in mount args: %v", l.ScratchRoot, mc.Args)
		}
	}

	// Both upper and work must exist as subdirs of ScratchRoot after the call.
	for _, sub := range []string{l.UpperDir, l.WorkDir} {
		if _, err := os.Stat(sub); err != nil {
			t.Errorf("expected %s to exist as subdir of ScratchRoot, got: %v", sub, err)
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

// When /sysroot is already mounted (digest swap mid-tick), MountUnion
// must umount + fresh-mount to pick up the new lowerdir. The kernel
// silently ignores `mount -o remount,lowerdir=...` on overlayfs
// (lowerdir is set at mount time), so a remount-then-success path
// would leave the OLD lowerdir in place and downstream services would
// fail to see the new module content.
func TestMountUnion_AlreadyMounted_UmountThenFreshMount(t *testing.T) {
	dir := t.TempDir()
	l := DefaultLayout()
	l.Root = dir
	l = l.Resolve()

	rec := &RecorderRunner{
		StubOutput: map[string][]byte{
			"findmnt --noheadings " + l.SysRoot: []byte("/sysroot overlay overlay rw\n"),
		},
	}
	o := &Overlay{Layout: l, Runner: rec}
	stack := ModuleStack{
		{ID: "base", Digest: "sha256:base", Priority: 10},
		{ID: "app", Digest: "sha256:app", Priority: 20},
	}
	if err := o.MountUnion(context.Background(), stack); err != nil {
		t.Fatalf("MountUnion: %v", err)
	}

	var sawUmount, sawFreshMount, sawRemount bool
	for _, inv := range rec.Invocations {
		if inv.Op != "Run" {
			continue
		}
		if inv.Name == "umount" && contains(inv.Args, l.SysRoot) {
			sawUmount = true
		}
		if inv.Name == "mount" && contains(inv.Args, "overlay") {
			sawFreshMount = true
		}
		for _, a := range inv.Args {
			if strings.HasPrefix(a, "remount,") {
				sawRemount = true
			}
		}
	}
	if !sawUmount {
		t.Errorf("expected umount call, got: %+v", rec.Invocations)
	}
	if !sawFreshMount {
		t.Errorf("expected fresh `mount -t overlay overlay` call, got: %+v", rec.Invocations)
	}
	if sawRemount {
		t.Errorf("remount path must not run for overlayfs lowerdir swap (kernel silently ignores it); got: %+v", rec.Invocations)
	}
}

// Lazy umount fallback: when /sysroot is held open by a downstream
// service (e.g. a unit still in `activating auto-restart`), the first
// `umount` returns EBUSY. The fallback `umount -l` (MNT_DETACH) is the
// recovery path that lets the digest swap proceed without forcing the
// operator to stop dependent units by hand.
func TestMountUnion_AlreadyMounted_LazyUmountFallbackOnBusy(t *testing.T) {
	dir := t.TempDir()
	l := DefaultLayout()
	l.Root = dir
	l = l.Resolve()

	rec := &RecorderRunner{
		StubOutput: map[string][]byte{
			"findmnt --noheadings " + l.SysRoot: []byte("/sysroot overlay overlay rw\n"),
		},
		StubErr: map[string]error{
			"umount " + l.SysRoot: fmt.Errorf("target is busy"),
		},
	}
	o := &Overlay{Layout: l, Runner: rec}
	stack := ModuleStack{{ID: "base", Digest: "sha256:base", Priority: 10}}
	if err := o.MountUnion(context.Background(), stack); err != nil {
		t.Fatalf("MountUnion: %v", err)
	}
	var sawLazyUmount bool
	for _, inv := range rec.Invocations {
		if inv.Op == "Run" && inv.Name == "umount" && contains(inv.Args, "-l") {
			sawLazyUmount = true
		}
	}
	if !sawLazyUmount {
		t.Errorf("expected `umount -l` fallback after busy error; got: %+v", rec.Invocations)
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
	if !strings.Contains(err.Error(), "erofs blob missing") {
		t.Errorf("error message = %q", err.Error())
	}
}

func TestMountModule_AlreadyMounted_NoOp(t *testing.T) {
	// Idempotency: when findmnt reports the mountpoint is already a mount,
	// MountModule must skip the actual `mount -t erofs` invocation.
	l := DefaultLayout()
	l.Root = t.TempDir()
	l = l.Resolve()
	digest := "sha256:abc"
	mountpoint := l.ModuleMountPath(digest)

	rec := &RecorderRunner{
		StubOutput: map[string][]byte{
			"findmnt --noheadings " + mountpoint: []byte(mountpoint + " erofs ro,...\n"),
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

func TestMountModule_WithBlob_IssuesErofsMount(t *testing.T) {
	l := DefaultLayout()
	l.Root = t.TempDir()
	l = l.Resolve()

	// Stage a fake .erofs blob so the existence check passes.
	digest := "sha256:abc"
	if err := os.MkdirAll(l.ModulesCacheRoot, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(l.ModuleCachePath(digest), []byte("fake erofs"), 0o644); err != nil {
		t.Fatal(err)
	}

	rec := &RecorderRunner{}
	if err := MountModule(context.Background(), rec, l, Module{Digest: digest, ID: "m1"}); err != nil {
		t.Fatalf("MountModule: %v", err)
	}
	found := false
	for _, inv := range rec.Invocations {
		if inv.Op == "Run" && inv.Name == "mount" && contains(inv.Args, "erofs") {
			found = true
			// erofs uses `-o loop,ro` (kernel handles loop-device
			// allocation automatically); no basedir/digest-store
			// arg like composefs needed.
			if !contains(inv.Args, "loop,ro") {
				t.Errorf("expected loop,ro mount option, got %v", inv.Args)
			}
		}
	}
	if !found {
		t.Errorf("no erofs mount call recorded; got %+v", rec.Invocations)
	}
}

// raceRunner models a concurrent sibling racing MountModule: the `mount`
// command fails, and `findmnt` returns a scripted mounted/not-mounted result
// per successive call (so the pre-check can read "not mounted" while the
// post-failure recheck reads "mounted", i.e. the sibling completed the mount in
// between). Any call past the script reuses the last scripted value.
type raceRunner struct {
	mountErr       error
	findmntMounted []bool
	findmntCalls   int
	mountCalls     int
}

func (r *raceRunner) Run(_ context.Context, name string, _ ...string) error {
	if name == "mount" {
		r.mountCalls++
		return r.mountErr
	}
	return nil
}

func (r *raceRunner) Output(_ context.Context, name string, _ ...string) ([]byte, error) {
	if name != "findmnt" {
		return nil, nil
	}
	i := r.findmntCalls
	r.findmntCalls++
	mounted := false
	switch {
	case i < len(r.findmntMounted):
		mounted = r.findmntMounted[i]
	case len(r.findmntMounted) > 0:
		mounted = r.findmntMounted[len(r.findmntMounted)-1]
	}
	if mounted {
		return []byte("mountpoint erofs ro\n"), nil
	}
	return nil, nil
}

func stageBlob(t *testing.T, l Layout, digest string) {
	t.Helper()
	if err := os.MkdirAll(l.ModulesCacheRoot, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(l.ModuleCachePath(digest), []byte("fake erofs"), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestMountModule_ConcurrentSiblingWonRace_ReturnsNil(t *testing.T) {
	// A sibling caller mounts the same digest between our pre-check and our mount:
	// pre-check says "not mounted", our `mount` fails "already mounted / busy",
	// the recheck now says "mounted" → MountModule must treat that as success
	// (the digest-addressed path can only hold this exact content).
	l := DefaultLayout()
	l.Root = t.TempDir()
	l = l.Resolve()
	digest := "sha256:abc"
	stageBlob(t, l, digest)

	rr := &raceRunner{
		mountErr:       fmt.Errorf("exit status 32: /dev/loop6 already mounted or mount point busy"),
		findmntMounted: []bool{false, true}, // pre-check: no; recheck: yes
	}
	if err := MountModule(context.Background(), rr, l, Module{Digest: digest, ID: "m1"}); err != nil {
		t.Fatalf("expected nil (sibling won the race), got: %v", err)
	}
	if rr.mountCalls != 1 {
		t.Errorf("expected exactly one mount attempt, got %d", rr.mountCalls)
	}
	if rr.findmntCalls != 2 {
		t.Errorf("expected pre-check + one recheck (2 findmnt calls), got %d", rr.findmntCalls)
	}
}

func TestMountModule_MountFailsAndStillNotMounted_ReturnsError(t *testing.T) {
	// A genuine mount failure (not a lost race): mount fails and the recheck still
	// reports "not mounted" → MountModule must return the original error, not mask
	// it as success.
	l := DefaultLayout()
	l.Root = t.TempDir()
	l = l.Resolve()
	digest := "sha256:def"
	stageBlob(t, l, digest)

	wantErr := fmt.Errorf("exit status 1: mount: unknown filesystem type 'erofs'")
	rr := &raceRunner{
		mountErr:       wantErr,
		findmntMounted: []bool{false, false}, // never mounted
	}
	err := MountModule(context.Background(), rr, l, Module{Digest: digest, ID: "m1"})
	if err == nil {
		t.Fatal("expected the original mount error, got nil")
	}
	if !strings.Contains(err.Error(), "unknown filesystem type") {
		t.Errorf("expected original mount error to propagate, got: %v", err)
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
