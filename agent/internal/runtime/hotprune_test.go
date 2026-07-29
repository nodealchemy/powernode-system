package runtime

import (
	"os"
	"path/filepath"
	"testing"
)

// --- helpers -------------------------------------------------------------

func hpWriteFile(t *testing.T, root, rel, content string) string {
	t.Helper()
	p := filepath.Join(root, rel)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatalf("mkdir for %s: %v", rel, err)
	}
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatalf("write %s: %v", rel, err)
	}
	return p
}

func hpWriteLink(t *testing.T, root, rel, target string) string {
	t.Helper()
	p := filepath.Join(root, rel)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatalf("mkdir for %s: %v", rel, err)
	}
	if err := os.Symlink(target, p); err != nil {
		t.Fatalf("symlink %s: %v", rel, err)
	}
	return p
}

func hpRead(t *testing.T, p string) string {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatalf("read %s: %v", p, err)
	}
	return string(b)
}

func hpExists(t *testing.T, p string) bool {
	t.Helper()
	_, err := os.Lstat(p)
	return err == nil
}

// --- ModuleTreePaths -----------------------------------------------------

func TestModuleTreePaths_SeparatesFilesFromDirs(t *testing.T) {
	src := t.TempDir()
	hpWriteFile(t, src, "usr/local/bin/go", "binary")
	hpWriteLink(t, src, "usr/local/bin/gofmt", "/usr/local/go/bin/gofmt")
	if err := os.MkdirAll(filepath.Join(src, "usr/share/empty"), 0o755); err != nil {
		t.Fatal(err)
	}

	tp, err := ModuleTreePaths(src)
	if err != nil {
		t.Fatalf("ModuleTreePaths: %v", err)
	}

	// Files carries regular files AND symlinks — the prunable entry kinds.
	for _, want := range []string{"/usr/local/bin/go", "/usr/local/bin/gofmt"} {
		if !tp.Files[want] {
			t.Errorf("Files missing %s (got %v)", want, tp.Files)
		}
	}
	if tp.Files["/usr/share/empty"] {
		t.Error("Files must not contain directories")
	}
	// All carries everything, so a path the new version turns into a
	// directory still counts as "provided" and is not a prune candidate.
	for _, want := range []string{"/usr/local/bin/go", "/usr/share/empty", "/usr/local"} {
		if !tp.All[want] {
			t.Errorf("All missing %s", want)
		}
	}
	// The tree root itself is not an entry.
	if tp.All["/"] || tp.All[""] {
		t.Error("tree root must not be recorded as an entry")
	}
}

func TestModuleTreePaths_MissingDirIsNotAnError(t *testing.T) {
	tp, err := ModuleTreePaths(filepath.Join(t.TempDir(), "never-mounted"))
	if err != nil {
		t.Fatalf("a never-mounted layer must degrade to empty, got %v", err)
	}
	if len(tp.All) != 0 || len(tp.Files) != 0 {
		t.Errorf("expected empty tree, got %v", tp)
	}
}

// --- matchesAnySpec ------------------------------------------------------

func TestMatchesAnySpec(t *testing.T) {
	cases := []struct {
		path  string
		specs []string
		want  bool
	}{
		{"/usr/local/bin/go", []string{"/usr/local/**"}, true},
		{"/usr/local", []string{"/usr/local/**"}, false},
		{"/etc/ssh/sshd_config", []string{"/etc/ssh/**"}, true},
		{"/etc/a.conf", []string{"/etc/*.conf"}, true},
		{"/etc/sub/a.conf", []string{"/etc/*.conf"}, false},
		{"/etc/passwd", []string{"/etc/passwd"}, true},
		{"/etc/passwd-", []string{"/etc/passwd"}, false},
		{"/var/lib/x", nil, false},
		{"/var/lib/x", []string{"/etc/**", "/var/**"}, true},
		// A bare "**" protects everything — a module opting out entirely.
		{"/anything/at/all", []string{"**"}, true},
	}
	for _, c := range cases {
		if got := matchesAnySpec(c.path, c.specs); got != c.want {
			t.Errorf("matchesAnySpec(%q, %v) = %v, want %v", c.path, c.specs, got, c.want)
		}
	}
}

// --- PruneRemovedFiles ---------------------------------------------------

// The core case: the new version dropped a file, nothing else provides it,
// so it must come off the live root.
func TestPrune_RemovesFileNoSurvivingProviderHas(t *testing.T) {
	newTree, dst := t.TempDir(), t.TempDir()
	stale := hpWriteFile(t, dst, "etc/profile.d/50-dev-cell-go.sh", "export PATH=/persist/dev/...")

	res, err := PruneRemovedFiles(PruneOptions{
		OldPaths:    map[string]bool{"/etc/profile.d/50-dev-cell-go.sh": true},
		NewErofsDir: newTree,
		DstRoot:     dst,
	})
	if err != nil {
		t.Fatalf("PruneRemovedFiles: %v", err)
	}
	if hpExists(t, stale) {
		t.Error("stale file dropped by the new version must be removed")
	}
	if res.Removed != 1 || res.Restored != 0 {
		t.Errorf("got %+v, want Removed=1 Restored=0", res)
	}
}

// The constraint that makes this safe: another layer still ships the path,
// so removing it would punch a hole in the union. Restore, never unlink.
func TestPrune_RestoresFromSurvivingLayerInsteadOfRemoving(t *testing.T) {
	newTree, dst := t.TempDir(), t.TempDir()
	survivor := t.TempDir()
	hpWriteFile(t, survivor, "usr/bin/tool", "from-base-os")
	live := hpWriteFile(t, dst, "usr/bin/tool", "from-the-removed-module")

	res, err := PruneRemovedFiles(PruneOptions{
		OldPaths:        map[string]bool{"/usr/bin/tool": true},
		NewErofsDir:     newTree,
		DstRoot:         dst,
		SurvivingLayers: []string{survivor},
	})
	if err != nil {
		t.Fatalf("PruneRemovedFiles: %v", err)
	}
	if !hpExists(t, live) {
		t.Fatal("a path another layer still provides must NOT be removed")
	}
	if got := hpRead(t, live); got != "from-base-os" {
		t.Errorf("live content = %q, want the surviving layer's copy", got)
	}
	if res.Restored != 1 || res.Removed != 0 {
		t.Errorf("got %+v, want Restored=1 Removed=0", res)
	}
}

// Layers are consulted highest-priority first, matching overlayfs lower order.
func TestPrune_HighestPriorityLayerWins(t *testing.T) {
	newTree, dst := t.TempDir(), t.TempDir()
	high, low := t.TempDir(), t.TempDir()
	hpWriteFile(t, high, "usr/bin/tool", "high-priority")
	hpWriteFile(t, low, "usr/bin/tool", "low-priority")
	live := hpWriteFile(t, dst, "usr/bin/tool", "stale")

	if _, err := PruneRemovedFiles(PruneOptions{
		OldPaths:        map[string]bool{"/usr/bin/tool": true},
		NewErofsDir:     newTree,
		DstRoot:         dst,
		SurvivingLayers: []string{high, low},
	}); err != nil {
		t.Fatalf("PruneRemovedFiles: %v", err)
	}
	if got := hpRead(t, live); got != "high-priority" {
		t.Errorf("live content = %q, want the FIRST listed layer to win", got)
	}
}

// protected_spec gets its first real consumer here: a protected path is
// never removed and never rewritten, whatever the layers say.
func TestPrune_ProtectedPathsAreNeverTouched(t *testing.T) {
	newTree, dst := t.TempDir(), t.TempDir()
	survivor := t.TempDir()
	hpWriteFile(t, survivor, "etc/ssh/ssh_host_ed25519_key", "layer-copy")
	live := hpWriteFile(t, dst, "etc/ssh/ssh_host_ed25519_key", "node-generated")

	res, err := PruneRemovedFiles(PruneOptions{
		OldPaths:        map[string]bool{"/etc/ssh/ssh_host_ed25519_key": true},
		NewErofsDir:     newTree,
		DstRoot:         dst,
		SurvivingLayers: []string{survivor},
		Protected:       []string{"/etc/ssh/**"},
	})
	if err != nil {
		t.Fatalf("PruneRemovedFiles: %v", err)
	}
	if got := hpRead(t, live); got != "node-generated" {
		t.Errorf("protected path was rewritten to %q", got)
	}
	if res.Removed != 0 || res.Restored != 0 || res.Kept != 1 {
		t.Errorf("got %+v, want Kept=1 only", res)
	}
}

// A path the new version still ships is not a candidate at all.
func TestPrune_PathStillShippedIsNotACandidate(t *testing.T) {
	newTree, dst := t.TempDir(), t.TempDir()
	hpWriteFile(t, newTree, "usr/bin/tool", "new-version")
	live := hpWriteFile(t, dst, "usr/bin/tool", "already-synced")

	res, err := PruneRemovedFiles(PruneOptions{
		OldPaths:    map[string]bool{"/usr/bin/tool": true},
		NewErofsDir: newTree,
		DstRoot:     dst,
	})
	if err != nil {
		t.Fatalf("PruneRemovedFiles: %v", err)
	}
	if !hpExists(t, live) {
		t.Fatal("a path the new version still ships must never be pruned")
	}
	if res.Removed != 0 {
		t.Errorf("got %+v, want Removed=0", res)
	}
}

// File → directory is a legitimate module refactor, not a deletion.
func TestPrune_FileReplacedByDirectoryIsNotACandidate(t *testing.T) {
	newTree, dst := t.TempDir(), t.TempDir()
	if err := os.MkdirAll(filepath.Join(newTree, "usr/bin/tool"), 0o755); err != nil {
		t.Fatal(err)
	}
	live := hpWriteFile(t, dst, "usr/bin/tool", "old-file-form")

	if _, err := PruneRemovedFiles(PruneOptions{
		OldPaths:    map[string]bool{"/usr/bin/tool": true},
		NewErofsDir: newTree,
		DstRoot:     dst,
	}); err != nil {
		t.Fatalf("PruneRemovedFiles: %v", err)
	}
	if !hpExists(t, live) {
		t.Error("new version providing the path as a DIRECTORY is not a removal")
	}
}

// The invariant that protects operator state: the candidate set is exactly
// what the old module shipped, so an unrelated file is structurally
// unreachable — not merely skipped by a check that could regress.
func TestPrune_NeverTouchesPathsTheModuleNeverShipped(t *testing.T) {
	newTree, dst := t.TempDir(), t.TempDir()
	operator := hpWriteFile(t, dst, "etc/my-operator-edit.conf", "hand-written")
	hpWriteFile(t, dst, "etc/profile.d/50-dev-cell-go.sh", "stale")

	if _, err := PruneRemovedFiles(PruneOptions{
		OldPaths:    map[string]bool{"/etc/profile.d/50-dev-cell-go.sh": true},
		NewErofsDir: newTree,
		DstRoot:     dst,
	}); err != nil {
		t.Fatalf("PruneRemovedFiles: %v", err)
	}
	if !hpExists(t, operator) {
		t.Error("a path outside OldPaths must never be considered")
	}
	if got := hpRead(t, operator); got != "hand-written" {
		t.Errorf("operator file mutated to %q", got)
	}
}

func TestPrune_RemovesDroppedSymlink(t *testing.T) {
	newTree, dst := t.TempDir(), t.TempDir()
	link := hpWriteLink(t, dst, "usr/local/bin/go", "/persist/dev/toolchain/go/bin/go")

	res, err := PruneRemovedFiles(PruneOptions{
		OldPaths:    map[string]bool{"/usr/local/bin/go": true},
		NewErofsDir: newTree,
		DstRoot:     dst,
	})
	if err != nil {
		t.Fatalf("PruneRemovedFiles: %v", err)
	}
	if hpExists(t, link) {
		t.Error("a dropped symlink must be removed")
	}
	if res.Removed != 1 {
		t.Errorf("got %+v, want Removed=1", res)
	}
}

func TestPrune_RestoresSymlinkFromSurvivingLayer(t *testing.T) {
	newTree, dst := t.TempDir(), t.TempDir()
	survivor := t.TempDir()
	hpWriteLink(t, survivor, "usr/local/bin/go", "/usr/local/go/bin/go")
	hpWriteLink(t, dst, "usr/local/bin/go", "/persist/dev/toolchain/go/bin/go")

	if _, err := PruneRemovedFiles(PruneOptions{
		OldPaths:        map[string]bool{"/usr/local/bin/go": true},
		NewErofsDir:     newTree,
		DstRoot:         dst,
		SurvivingLayers: []string{survivor},
	}); err != nil {
		t.Fatalf("PruneRemovedFiles: %v", err)
	}
	got, err := os.Readlink(filepath.Join(dst, "usr/local/bin/go"))
	if err != nil {
		t.Fatalf("readlink: %v", err)
	}
	if got != "/usr/local/go/bin/go" {
		t.Errorf("symlink target = %q, want the surviving layer's target", got)
	}
}

// Already-absent is the steady state on every tick after the first — it
// must be silent and cheap, not an error.
func TestPrune_AbsentDestinationIsNotAnError(t *testing.T) {
	newTree, dst := t.TempDir(), t.TempDir()

	res, err := PruneRemovedFiles(PruneOptions{
		OldPaths:    map[string]bool{"/etc/gone-already": true},
		NewErofsDir: newTree,
		DstRoot:     dst,
	})
	if err != nil {
		t.Fatalf("an already-absent path must not error: %v", err)
	}
	if res.Removed != 0 || res.Kept != 1 {
		t.Errorf("got %+v, want Kept=1 Removed=0", res)
	}
}

// A directory the old version shipped is left alone: removing it could
// take unrelated content with it, and an empty dir is harmless.
func TestPrune_NeverRemovesDirectories(t *testing.T) {
	newTree, dst := t.TempDir(), t.TempDir()
	d := filepath.Join(dst, "usr/share/dev-cell")
	if err := os.MkdirAll(d, 0o755); err != nil {
		t.Fatal(err)
	}
	hpWriteFile(t, dst, "usr/share/dev-cell/keep-me", "unrelated")

	if _, err := PruneRemovedFiles(PruneOptions{
		// A caller that wrongly passes a directory must not cause data loss.
		OldPaths:    map[string]bool{"/usr/share/dev-cell": true},
		NewErofsDir: newTree,
		DstRoot:     dst,
	}); err != nil {
		t.Fatalf("PruneRemovedFiles: %v", err)
	}
	if !hpExists(t, d) {
		t.Fatal("directories must never be removed")
	}
	if !hpExists(t, filepath.Join(dst, "usr/share/dev-cell/keep-me")) {
		t.Error("directory removal would have taken unrelated content with it")
	}
}

// Escaping the destination root via a crafted path must be impossible.
func TestPrune_RejectsPathEscapingDstRoot(t *testing.T) {
	newTree, dst := t.TempDir(), t.TempDir()
	outside := hpWriteFile(t, filepath.Dir(dst), "outside-the-root", "must-survive")

	res, err := PruneRemovedFiles(PruneOptions{
		OldPaths:    map[string]bool{"/../outside-the-root": true},
		NewErofsDir: newTree,
		DstRoot:     dst,
	})
	if !hpExists(t, outside) {
		t.Fatal("a path escaping DstRoot must never be acted on")
	}
	// Nothing upstream should ever produce such a path, so refusing it
	// quietly would hide a real bug. It must be both refused AND reported.
	if err == nil {
		t.Error("an escaping path must be surfaced as an error, not skipped silently")
	}
	if res.Removed != 0 {
		t.Errorf("got %+v, want Removed=0", res)
	}
}

// One bad entry must not stop the rest — same contract as SyncModuleFilesToRoot.
func TestPrune_ContinuesPastAnUnremovableEntry(t *testing.T) {
	newTree, dst := t.TempDir(), t.TempDir()
	// A non-empty directory where the caller claims a file was shipped:
	// os.Remove fails on it, but it must not abort the other candidates.
	if err := os.MkdirAll(filepath.Join(dst, "etc/stuck"), 0o755); err != nil {
		t.Fatal(err)
	}
	hpWriteFile(t, dst, "etc/stuck/child", "x")
	ok := hpWriteFile(t, dst, "etc/also-stale", "y")

	res, _ := PruneRemovedFiles(PruneOptions{
		OldPaths:    map[string]bool{"/etc/stuck": true, "/etc/also-stale": true},
		NewErofsDir: newTree,
		DstRoot:     dst,
	})
	if hpExists(t, ok) {
		t.Error("a later candidate must still be pruned after an earlier failure")
	}
	if res.Removed != 1 {
		t.Errorf("got %+v, want Removed=1", res)
	}
}

// The highest-consequence branch in the file. If the incoming tree can only
// be read in part, the missing entries are indistinguishable from entries
// the new version deliberately dropped — and acting on that reading deletes
// files the module still ships. Skipping a tick is recoverable; an erroneous
// prune is not, so the walk error must abort the whole pass.
func TestPrune_PartiallyReadNewTreeAbortsRatherThanDeleting(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root bypasses directory permissions, so no walk error can be provoked")
	}
	newTree, dst := t.TempDir(), t.TempDir()
	hpWriteFile(t, newTree, "usr/bin/tool", "new-version-still-ships-this")
	unreadable := filepath.Join(newTree, "usr")
	if err := os.Chmod(unreadable, 0o000); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(unreadable, 0o755) })

	live := hpWriteFile(t, dst, "usr/bin/tool", "must-survive")

	res, err := PruneRemovedFiles(PruneOptions{
		OldPaths:    map[string]bool{"/usr/bin/tool": true},
		NewErofsDir: newTree,
		DstRoot:     dst,
	})
	if err == nil {
		t.Error("a partially-read new tree must abort, not be treated as authoritative")
	}
	if !hpExists(t, live) {
		t.Fatal("an unreadable new tree must never be interpreted as a deletion")
	}
	if res.Removed != 0 {
		t.Errorf("got %+v, want Removed=0", res)
	}
}
