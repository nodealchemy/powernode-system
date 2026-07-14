package etcidentity

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// Home-directory ownership reconcile.
//
// etcidentity authoritatively renders /etc/passwd (uid/gid = platform
// source of truth), but rendering the passwd file does not make the
// filesystem agree: a user's home directory can exist owned root:root
// (created by the image build, or by an earlier os.MkdirAll before the
// user existed), which leaves the user unable to traverse into its own
// home. sshd (dropping to that uid to read ~/.ssh/authorized_keys under
// StrictModes) then fails "Permission denied", and any unprivileged
// service with HOME under it hits EACCES.
//
// This is the runtime half of the platform's ownership contract: module
// erofs layers are root:root by design (mkfs.erofs --all-root); ownership
// is derived from the rendered passwd at runtime, by NAME/uid, every tick
// — the same philosophy as systemd StateDirectory=, dockerd re-chowning
// docker.sock, and the storage chown task. A baked numeric uid can't be
// used because ids are per-install allocated; only a runtime reconcile
// can follow a mutable source of truth.
//
// Modes are single-sourced here and MUST match the base-os module's
// rootfs/usr/lib/tmpfiles.d/powernode-home.conf boot-time backstop.
const (
	// homeParentMode is the mode for the shared parent (/home): world-
	// traversable (r-x for group+other) so a non-root user can path
	// through it to reach its own home. Ownership stays root:root.
	homeParentMode os.FileMode = 0o755
	// homeDirMode is the mode for a user's own home dir — private to the
	// user (who owns it, so can still traverse).
	homeDirMode os.FileMode = 0o700
)

// managedHomeRoots are the home-directory prefixes this reconcile will
// create/repair ownership for. Scoped deliberately to /home/* (human-
// login accounts like pnadmin + module users like pnagent). Service data
// dirs under /var/lib/* are owned by their own systemd StateDirectory=
// or root-supervisor mechanism and are intentionally NOT touched here.
var managedHomeRoots = []string{"/home/"}

func isManagedHome(home string) bool {
	clean := filepath.Clean(home)
	for _, root := range managedHomeRoots {
		// Must be strictly under the root (e.g. "/home/pnadmin"), never
		// the root itself ("/home") or an escape ("/home/../etc").
		if strings.HasPrefix(clean+"/", root) && clean != filepath.Clean(root) {
			return true
		}
	}
	return false
}

// ReconcileHomeOwnership makes the filesystem agree with the rendered
// passwd for every managed-home user in the set. Idempotent, best-effort:
// each per-user failure is reported via onWarn (may be nil) and does not
// abort the rest. Only top-level ownership is reconciled — never
// recursive, so a user's own files are left alone. root is a sysroot
// prefix ("" for the live root; a union path during compose/pivot).
func ReconcileHomeOwnership(set *Set, root string, onWarn func(stage string, err error)) {
	if set == nil {
		return
	}
	seenParents := map[string]bool{}
	for _, u := range set.Users {
		if !isManagedHome(u.Home) {
			continue
		}
		home := filepath.Join(root, u.Home)
		parent := filepath.Dir(home)
		// Ensure the shared parent (/home) is traversable, once per parent.
		if !seenParents[parent] {
			seenParents[parent] = true
			if err := EnsureTraversableDir(parent); err != nil {
				warnHome(onWarn, "home_parent", err)
			}
		}
		if err := EnsureOwnedDir(home, u.UID, u.PrimaryGID, homeDirMode); err != nil {
			warnHome(onWarn, "home_dir_"+u.Name, err)
		}
	}
}

// EnsureTraversableDir ensures path exists and is group/other-traversable
// (adds r-x) so a non-root user can path through it. Creates it 0755 if
// missing. Never changes ownership (the parent stays root:root). Refuses
// symlinks.
func EnsureTraversableDir(path string) error {
	fi, err := os.Lstat(path)
	if err != nil {
		if os.IsNotExist(err) {
			return os.MkdirAll(path, homeParentMode)
		}
		return err
	}
	if fi.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("%s is a symlink, refusing", path)
	}
	if !fi.IsDir() {
		return fmt.Errorf("%s is not a directory", path)
	}
	if fi.Mode().Perm()&0o055 != 0o055 { // needs r-x for BOTH group and other
		return os.Chmod(path, fi.Mode().Perm()|0o055)
	}
	return nil
}

// EnsureOwnedDir ensures dir exists as a directory owned by uid:gid.
// Creates it (0700, parents 0755-traversable) if missing, else reconciles
// its top-level ownership only (never recursive). Refuses to follow a
// symlink (swap-attack guard). Idempotent.
func EnsureOwnedDir(dir string, uid, gid int, mode os.FileMode) error {
	fi, err := os.Lstat(dir)
	switch {
	case os.IsNotExist(err):
		if err := os.MkdirAll(filepath.Dir(dir), homeParentMode); err != nil {
			return err
		}
		if err := os.Mkdir(dir, mode); err != nil && !os.IsExist(err) {
			return err
		}
	case err != nil:
		return err
	case fi.Mode()&os.ModeSymlink != 0:
		return fmt.Errorf("%s is a symlink, refusing", dir)
	case !fi.IsDir():
		return fmt.Errorf("%s is not a directory", dir)
	}
	return os.Chown(dir, uid, gid)
}

func warnHome(cb func(string, error), stage string, err error) {
	if cb != nil && err != nil {
		cb("etcidentity:"+stage, err)
	}
}
