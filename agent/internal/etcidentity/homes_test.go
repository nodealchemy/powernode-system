package etcidentity

import (
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"syscall"
	"testing"
)

func TestIsManagedHome(t *testing.T) {
	cases := map[string]bool{
		"/home/pnadmin":  true,
		"/home/pnagent":  true,
		"/home":          false, // the shared parent itself is not a managed home
		"/home/":         false,
		"/var/lib/redis": false,
		"/nonexistent":   false,
		"/root":          false,
		"/home/../etc":   false, // escape must not be treated as managed
	}
	for in, want := range cases {
		if got := isManagedHome(in); got != want {
			t.Errorf("isManagedHome(%q) = %v, want %v", in, got, want)
		}
	}
}

func TestEnsureTraversableDir(t *testing.T) {
	t.Run("creates missing dir 0755", func(t *testing.T) {
		p := filepath.Join(t.TempDir(), "home")
		if err := EnsureTraversableDir(p); err != nil {
			t.Fatal(err)
		}
		fi, err := os.Stat(p)
		if err != nil {
			t.Fatal(err)
		}
		if fi.Mode().Perm()&0o055 != 0o055 {
			t.Errorf("mode = %o, want group+other traversable", fi.Mode().Perm())
		}
	})

	t.Run("repairs a 0700 dir to be traversable", func(t *testing.T) {
		p := filepath.Join(t.TempDir(), "home")
		if err := os.Mkdir(p, 0o700); err != nil {
			t.Fatal(err)
		}
		if err := EnsureTraversableDir(p); err != nil {
			t.Fatal(err)
		}
		fi, _ := os.Stat(p)
		if fi.Mode().Perm()&0o055 != 0o055 {
			t.Errorf("mode = %o, want traversable after repair", fi.Mode().Perm())
		}
	})

	t.Run("refuses a symlink", func(t *testing.T) {
		base := t.TempDir()
		target := filepath.Join(base, "target")
		_ = os.Mkdir(target, 0o755)
		link := filepath.Join(base, "link")
		if err := os.Symlink(target, link); err != nil {
			t.Fatal(err)
		}
		if err := EnsureTraversableDir(link); err == nil {
			t.Error("expected error for symlink, got nil")
		}
	})
}

func TestEnsureOwnedDir(t *testing.T) {
	uid, gid := os.Getuid(), os.Getgid()

	t.Run("creates missing dir with mode", func(t *testing.T) {
		p := filepath.Join(t.TempDir(), "sub", "home")
		if err := EnsureOwnedDir(p, uid, gid, 0o700); err != nil {
			t.Fatal(err)
		}
		fi, err := os.Stat(p)
		if err != nil || !fi.IsDir() {
			t.Fatalf("dir not created: %v", err)
		}
		if fi.Mode().Perm() != 0o700 {
			t.Errorf("mode = %o, want 0700", fi.Mode().Perm())
		}
	})

	t.Run("idempotent on existing owned dir", func(t *testing.T) {
		p := filepath.Join(t.TempDir(), "home")
		_ = os.Mkdir(p, 0o700)
		if err := EnsureOwnedDir(p, uid, gid, 0o700); err != nil {
			t.Fatal(err)
		}
	})

	t.Run("refuses a symlink (swap guard)", func(t *testing.T) {
		base := t.TempDir()
		target := filepath.Join(base, "target")
		_ = os.Mkdir(target, 0o755)
		link := filepath.Join(base, "link")
		_ = os.Symlink(target, link)
		if err := EnsureOwnedDir(link, uid, gid, 0o700); err == nil {
			t.Error("expected error for symlink, got nil")
		}
	})

	t.Run("errors on a non-directory", func(t *testing.T) {
		p := filepath.Join(t.TempDir(), "afile")
		_ = os.WriteFile(p, []byte("x"), 0o600)
		if err := EnsureOwnedDir(p, uid, gid, 0o700); err == nil {
			t.Error("expected error for non-directory, got nil")
		}
	})
}

func TestReconcileHomeOwnership(t *testing.T) {
	uid, gid := os.Getuid(), os.Getgid()
	root := t.TempDir()

	set := &Set{Users: []User{
		{Name: "pnadmin", UID: uid, PrimaryGID: gid, Home: "/home/pnadmin"},
		{Name: "redis", UID: uid, PrimaryGID: gid, Home: "/var/lib/redis"}, // not a /home user → skipped
	}}

	var warns int
	ReconcileHomeOwnership(set, root, func(string, error) { warns++ })

	// /home created + traversable, /home/pnadmin created.
	homeParent := filepath.Join(root, "home")
	fi, err := os.Stat(homeParent)
	if err != nil {
		t.Fatalf("/home not created: %v", err)
	}
	if fi.Mode().Perm()&0o055 != 0o055 {
		t.Errorf("/home mode = %o, want traversable", fi.Mode().Perm())
	}
	if _, err := os.Stat(filepath.Join(root, "home", "pnadmin")); err != nil {
		t.Errorf("/home/pnadmin not created: %v", err)
	}
	// The /var/lib/redis user must be skipped entirely (never created here).
	if _, err := os.Stat(filepath.Join(root, "var", "lib", "redis")); !os.IsNotExist(err) {
		t.Errorf("/var/lib/redis should NOT be touched by home reconcile")
	}
	if warns != 0 {
		t.Errorf("unexpected warnings: %d", warns)
	}
}

func TestReconcileHomeOwnership_NilSafe(t *testing.T) {
	ReconcileHomeOwnership(nil, "", nil) // must not panic
}

// chownCall is one ownership request the walk made, captured at the
// fchown seam: the inode it was made on (resolved through /proc/self/fd, so
// it names where the fd REALLY points, not the path the caller spelled) and
// the ids requested.
type chownCall struct {
	path     string
	uid, gid int
}

// recordChowns swaps the fchown seam for the test's lifetime. Every request
// is recorded, then forwarded to the real syscall against the runner's OWN
// ids: unprivileged, a chown to any other uid is EPERM, so the seam is the
// only place a test can see WHICH uid:gid the walk asked for and on WHICH
// inode. What it cannot prove is that the kernel honours a foreign-uid
// fchown for root — that is the syscall's contract, not the walk's.
func recordChowns(t *testing.T) *[]chownCall {
	t.Helper()
	var calls []chownCall
	orig := fchown
	fchown = func(fd, uid, gid int) error {
		target, err := os.Readlink(fmt.Sprintf("/proc/self/fd/%d", fd))
		if err != nil {
			t.Fatalf("resolve fd %d: %v", fd, err)
		}
		calls = append(calls, chownCall{path: target, uid: uid, gid: gid})
		return orig(fd, os.Getuid(), os.Getgid())
	}
	t.Cleanup(func() { fchown = orig })
	return &calls
}

// realPath is where a temp path really lives (TMPDIR may be a symlink),
// for comparison with /proc/self/fd targets.
func realPath(t *testing.T, p string) string {
	t.Helper()
	r, err := filepath.EvalSymlinks(p)
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func permOf(t *testing.T, p string) os.FileMode {
	t.Helper()
	fi, err := os.Lstat(p)
	if err != nil {
		t.Fatal(err)
	}
	return fi.Mode().Perm()
}

type warnRec struct {
	stage string
	err   error
}

func collectWarns(dst *[]warnRec) func(string, error) {
	return func(stage string, err error) { *dst = append(*dst, warnRec{stage, err}) }
}

func hasWarn(warns []warnRec, stage string) bool {
	for _, w := range warns {
		if w.stage == "etcidentity:"+stage {
			return true
		}
	}
	return false
}

// A symlink in any PARENT component of a managed home must be refused,
// and nothing on the far side of the link may be created, chowned or
// chmodded. The link target sits INSIDE the temp root so the writeguard
// (which judges the resolved path) stays silent: what is under test is
// the walk's own refusal, not the sandbox.
func TestReconcileHomeOwnership_RefusesSymlinkedParent(t *testing.T) {
	cases := []struct {
		name string
		link string // path under root that is the symlink
		home string // the user's declared home
	}{
		{"first component", "home", "/home/mallory"},
		{"middle component", "home/team", "/home/team/mallory"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			root := t.TempDir()
			elsewhere := filepath.Join(root, "elsewhere")
			if err := os.Mkdir(elsewhere, 0o700); err != nil {
				t.Fatal(err)
			}
			link := filepath.Join(root, tc.link)
			if err := os.MkdirAll(filepath.Dir(link), 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(elsewhere, link); err != nil {
				t.Fatal(err)
			}
			calls := recordChowns(t)
			var warns []warnRec
			set := &Set{Users: []User{{Name: "mallory", UID: 4242, PrimaryGID: 4242, Home: tc.home}}}
			ReconcileHomeOwnership(set, root, collectWarns(&warns))

			if !hasWarn(warns, "home_dir_mallory") || !strings.Contains(warns[0].err.Error(), "is a symlink, refusing") {
				t.Errorf("refusal not reported as a symlink; warns=%v", warns)
			}
			if _, err := os.Lstat(filepath.Join(elsewhere, "mallory")); !os.IsNotExist(err) {
				t.Errorf("home was created THROUGH the symlinked parent (err=%v)", err)
			}
			if got := permOf(t, elsewhere); got != 0o700 {
				t.Errorf("link target mode changed to %o through the symlink", got)
			}
			if len(*calls) != 0 {
				t.Errorf("chown requested through a symlinked parent: %+v", *calls)
			}
		})
	}
}

// A home declared inside ANOTHER managed user's home is refused, and the
// enclosing home's mode is left exactly as it was: the nested user must
// not get the enclosing home widened to r-x for it.
func TestReconcileHomeOwnership_RefusesNestedHome(t *testing.T) {
	root := t.TempDir()
	uid, gid := os.Getuid(), os.Getgid()
	set := &Set{Users: []User{
		{Name: "alice", UID: uid, PrimaryGID: gid, Home: "/home/alice"},
		{Name: "bob", UID: uid, PrimaryGID: gid, Home: "/home/alice/bob"},
		{Name: "carol", UID: uid, PrimaryGID: gid, Home: "/home/alice/deep/carol"},
	}}
	var warns []warnRec
	ReconcileHomeOwnership(set, root, collectWarns(&warns))

	alice := filepath.Join(root, "home", "alice")
	if got := permOf(t, alice); got != 0o700 {
		t.Errorf("enclosing home mode = %o, want 0700 untouched", got)
	}
	for _, nested := range []string{"bob", "deep"} {
		if _, err := os.Lstat(filepath.Join(alice, nested)); !os.IsNotExist(err) {
			t.Errorf("%s was created inside another user's home (err=%v)", nested, err)
		}
	}
	for _, name := range []string{"bob", "carol"} {
		if !hasWarn(warns, "home_nested_"+name) {
			t.Errorf("nested home %s not reported; warns=%v", name, warns)
		}
	}
	if hasWarn(warns, "home_dir_alice") {
		t.Errorf("the legitimate home was refused: %v", warns)
	}
}

// A legitimate home is created with exactly homeDirMode, chowned to the
// declared uid:gid ON THAT INODE (seen at the fchown seam), and the shared
// parent ends up with exactly the traversable bits — regardless of the
// process umask, which mkdirat(2) applies and the walk must correct.
func TestReconcileHomeOwnership_CreatesLegitimateHome(t *testing.T) {
	old := syscall.Umask(0o077)
	defer syscall.Umask(old)

	root := t.TempDir()
	calls := recordChowns(t)
	var warns []warnRec
	set := &Set{Users: []User{{Name: "pnagent", UID: 4242, PrimaryGID: 4243, Home: "/home/pnagent"}}}
	ReconcileHomeOwnership(set, root, collectWarns(&warns))

	if len(warns) != 0 {
		t.Fatalf("unexpected warnings: %v", warns)
	}
	if got := permOf(t, filepath.Join(root, "home")); got != homeParentMode {
		t.Errorf("/home mode = %o, want exactly %o", got, homeParentMode)
	}
	home := filepath.Join(root, "home", "pnagent")
	if got := permOf(t, home); got != homeDirMode {
		t.Errorf("home mode = %o, want exactly %o", got, homeDirMode)
	}
	want := []chownCall{{path: realPath(t, home), uid: 4242, gid: 4243}}
	if !reflect.DeepEqual(*calls, want) {
		t.Errorf("chown calls = %+v, want %+v", *calls, want)
	}
}

// A pre-existing home keeps whatever mode it has (only ownership is
// reconciled), and a pre-existing shared parent gains ONLY r-x for group
// and other: no write bits, and the bits it already had are kept.
func TestReconcileHomeOwnership_ExistingDirsGetOnlyTheirBits(t *testing.T) {
	root := t.TempDir()
	parent := filepath.Join(root, "home")
	home := filepath.Join(parent, "pnadmin")
	if err := os.MkdirAll(home, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, m := range []os.FileMode{0o700, 0o750} {
		if err := os.Chmod(parent, m); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Chmod(home, 0o750); err != nil {
		t.Fatal(err)
	}
	calls := recordChowns(t)
	set := &Set{Users: []User{{Name: "pnadmin", UID: 4242, PrimaryGID: 4242, Home: "/home/pnadmin"}}}
	var warns []warnRec
	ReconcileHomeOwnership(set, root, collectWarns(&warns))
	if len(warns) != 0 {
		t.Fatalf("unexpected warnings: %v", warns)
	}
	if got := permOf(t, parent); got != 0o755 {
		t.Errorf("parent mode = %o, want 0750|0055 = 0755", got)
	}
	if got := permOf(t, home); got != 0o750 {
		t.Errorf("existing home mode changed to %o", got)
	}
	if len(*calls) != 1 || (*calls)[0].uid != 4242 || (*calls)[0].path != realPath(t, home) {
		t.Errorf("chown calls = %+v", *calls)
	}
	// A parent already wider than r-x is not narrowed.
	if err := os.Chmod(parent, 0o775); err != nil {
		t.Fatal(err)
	}
	ReconcileHomeOwnership(set, root, collectWarns(&warns))
	if got := permOf(t, parent); got != 0o775 {
		t.Errorf("parent mode = %o, want 0775 kept", got)
	}
}

// The leaf-is-a-symlink refusal predates this walk; pin that it survives.
func TestReconcileHomeOwnership_RefusesSymlinkedLeaf(t *testing.T) {
	root := t.TempDir()
	elsewhere := filepath.Join(root, "elsewhere")
	if err := os.Mkdir(elsewhere, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(root, "home"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(elsewhere, filepath.Join(root, "home", "eve")); err != nil {
		t.Fatal(err)
	}
	calls := recordChowns(t)
	var warns []warnRec
	set := &Set{Users: []User{{Name: "eve", UID: 4242, PrimaryGID: 4242, Home: "/home/eve"}}}
	ReconcileHomeOwnership(set, root, collectWarns(&warns))
	if !hasWarn(warns, "home_dir_eve") || !strings.Contains(warns[0].err.Error(), "is a symlink, refusing") {
		t.Errorf("symlinked leaf not refused as a symlink: %v", warns)
	}
	if len(*calls) != 0 {
		t.Errorf("chown requested on a symlinked leaf: %+v", *calls)
	}
	if got := permOf(t, elsewhere); got != 0o700 {
		t.Errorf("link target mode changed to %o", got)
	}
}

// The exported single-dir helpers (used by the authorized_keys writer on
// the live root) get the same parent-component refusal.
func TestEnsureHelpers_RefuseSymlinkedParent(t *testing.T) {
	base := t.TempDir()
	elsewhere := filepath.Join(base, "elsewhere")
	if err := os.Mkdir(elsewhere, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(elsewhere, filepath.Join(base, "link")); err != nil {
		t.Fatal(err)
	}
	uid, gid := os.Getuid(), os.Getgid()
	if err := EnsureTraversableDir(filepath.Join(base, "link", "sub")); err == nil {
		t.Error("EnsureTraversableDir followed a symlinked parent")
	}
	if err := EnsureOwnedDir(filepath.Join(base, "link", "sub"), uid, gid, 0o700); err == nil {
		t.Error("EnsureOwnedDir followed a symlinked parent")
	}
	if _, err := os.Lstat(filepath.Join(elsewhere, "sub")); !os.IsNotExist(err) {
		t.Errorf("sub was created through the symlink (err=%v)", err)
	}
	if got := permOf(t, elsewhere); got != 0o700 {
		t.Errorf("link target mode changed to %o", got)
	}
	// The walk itself (below the writeguard, which is what refuses a
	// relative path while the guard is armed) must not resolve a relative
	// path against the working directory in production either.
	if err := walkNoFollow("", "relative/home", 0o700, func(openedDir) error { return nil }); err == nil {
		t.Error("walkNoFollow accepted a relative path")
	}
}
