package etcidentity

import (
	"os"
	"path/filepath"
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
