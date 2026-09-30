package etcidentity

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/sys/unix"

	"github.com/nodealchemy/powernode-system/agent/internal/writeguard"
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
// The home path is manifest input and the reconcile runs as root, so the
// path is never trusted as a whole: every component is opened by
// descriptor with no-follow semantics (walkNoFollow), a symlink anywhere
// in the chain is refused, and every chown/chmod lands on an opened
// descriptor rather than a path. A path-based MkdirAll/Chown/Chmod would
// follow a symlinked PARENT (/home/x -> /etc) and act outside /home.
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

// fchown and fstat are the two syscalls the walk applies to an opened
// directory that an unprivileged test cannot drive to their interesting
// arm: it cannot chown to any uid but its own, and it cannot create a
// directory owned by anyone else. Vars so a test can observe the (fd, uid,
// gid) a chown requests, and report a foreign owner for a directory it
// made, while the real calls still run.
var (
	fchown = unix.Fchown
	fstat  = unix.Fstat
)

// ReconcileHomeOwnership makes the filesystem agree with the rendered
// passwd for every managed-home user in the set. Idempotent, best-effort:
// each per-user failure is reported via onWarn (may be nil) and does not
// abort the rest. Only top-level ownership is reconciled — never
// recursive, so a user's own files are left alone. root is a sysroot
// prefix ("" for the live root; a union path during compose/pivot).
//
// Every ancestor of a home inside the managed prefix is a shared parent
// and is made traversable (r-x added for group and other, nothing else);
// a home's own mode is set only when this call creates it. A home declared
// inside ANOTHER managed user's home is refused outright: reconciling it
// would have to widen that user's home, which is theirs to keep 0700. The
// same refusal applies on disk, keyed on the owner (ensureTraversableFd):
// the Set can be partial mid-delivery, so a pre-existing ancestor that is
// not owned by the reconcile's own uid is treated as someone's home
// whether or not this run's Set names them.
func ReconcileHomeOwnership(set *Set, root string, onWarn func(stage string, err error)) {
	if set == nil {
		return
	}
	managed := managedHomes(set)
	for _, u := range set.Users {
		if !isManagedHome(u.Home) {
			continue
		}
		home := filepath.Clean(u.Home)
		if enc := enclosingHome(home, managed); enc != "" {
			warnHome(onWarn, "home_nested_"+u.Name,
				fmt.Errorf("%s lies inside managed home %s, refusing", home, enc))
			continue
		}
		if err := writeguard.Check(filepath.Join(root, home)); err != nil {
			warnHome(onWarn, "home_dir_"+u.Name, err)
			continue
		}
		err := walkNoFollow(root, home, homeDirMode, func(d openedDir) error {
			if d.leaf {
				return ensureOwnedFd(d, u.UID, u.PrimaryGID, homeDirMode)
			}
			return ensureTraversableFd(d)
		})
		if err != nil {
			warnHome(onWarn, "home_dir_"+u.Name, err)
		}
	}
}

// managedHomes is the cleaned set of every managed home the set declares.
func managedHomes(set *Set) map[string]bool {
	m := map[string]bool{}
	for _, u := range set.Users {
		if isManagedHome(u.Home) {
			m[filepath.Clean(u.Home)] = true
		}
	}
	return m
}

// enclosingHome returns the managed home that home (cleaned) lies strictly
// inside, or "" when there is none.
func enclosingHome(home string, managed map[string]bool) string {
	for other := range managed {
		if other != home && strings.HasPrefix(home, other+"/") {
			return other
		}
	}
	return ""
}

// EnsureTraversableDir ensures path exists and is group/other-traversable
// (adds r-x) so a non-root user can path through it. Creates it, and any
// missing parent, at homeParentMode. Never changes ownership (the parent
// stays root:root). Refuses a symlink at any component. The live root
// itself ("/", the parent of a home declared directly under it) is a
// no-op: it is neither created nor rewritten, so there is no write for
// the guard to judge either.
func EnsureTraversableDir(path string) error {
	if filepath.Clean(path) == "/" {
		return nil
	}
	if err := writeguard.Check(path); err != nil {
		return err
	}
	return walkNoFollow("", path, homeParentMode, func(d openedDir) error {
		if d.leaf || d.created {
			return ensureTraversableFd(d)
		}
		return nil
	})
}

// EnsureOwnedDir ensures dir exists as a directory owned by uid:gid.
// Creates it (mode, missing parents homeParentMode) if missing, else
// reconciles its top-level ownership only (never recursive, never its
// mode). Refuses a symlink at any component (swap-attack guard).
// Idempotent.
func EnsureOwnedDir(dir string, uid, gid int, mode os.FileMode) error {
	if err := writeguard.Check(dir); err != nil {
		return err
	}
	return walkNoFollow("", dir, mode, func(d openedDir) error {
		if d.leaf {
			return ensureOwnedFd(d, uid, gid, mode)
		}
		if d.created {
			return ensureTraversableFd(d)
		}
		return nil
	})
}

// openedDir is one component the walk has opened: fd is an
// O_NOFOLLOW|O_DIRECTORY descriptor for exactly that inode, created
// reports whether this walk made it, leaf whether it is the last
// component. path is for messages only and is never used for I/O.
type openedDir struct {
	fd      int
	path    string
	created bool
	leaf    bool
}

// walkNoFollow opens every component of the absolute path rel beneath
// base (the sysroot prefix; "" is the live root) one at a time, each with
// openat(2) O_NOFOLLOW|O_DIRECTORY relative to the descriptor of the
// component before it, so a symlink anywhere in the chain fails the open
// (Linux reports it as ENOTDIR) instead of being followed. A missing
// component is created with
// mkdirat(2) on that same parent descriptor — parents at homeParentMode,
// the leaf at leafMode — and then opened the same way. visit runs on each
// opened component, in order, and does its chmod/chown on the descriptor.
//
// TOCTOU between check and use is closed by construction: after base is
// opened, no syscall takes a path longer than one component, and every
// one of those is relative to a descriptor this walk holds. There is no
// check-then-act pair on a name — the openat IS the check, and its result
// is the object acted on. A name swapped for a symlink after its openat
// changes nothing the descriptor points at; a name swapped between the
// mkdirat and its openat is refused by that openat's O_NOFOLLOW.
//
// base is the agent's own mount point (or "/"), not manifest input, and is
// opened following symlinks; the manifest-supplied part is rel.
func walkNoFollow(base, rel string, leafMode os.FileMode, visit func(openedDir) error) error {
	if !filepath.IsAbs(rel) {
		return fmt.Errorf("%q is not an absolute path", rel)
	}
	parts := strings.Split(strings.TrimPrefix(filepath.Clean(rel), "/"), "/")
	if parts[0] == "" {
		return fmt.Errorf("%q has no component to manage", rel)
	}
	if base == "" {
		base = "/"
	}
	dirfd, err := openDir(unix.AT_FDCWD, base, 0)
	if err != nil {
		return fmt.Errorf("open %s: %w", base, err)
	}
	cur := base
	for i, name := range parts {
		leaf := i == len(parts)-1
		mode := homeParentMode
		if leaf {
			mode = leafMode
		}
		cur = filepath.Join(cur, name)
		fd, created, err := openChildNoFollow(dirfd, name, mode)
		unix.Close(dirfd)
		if err != nil {
			return fmt.Errorf("%s: %w", cur, err)
		}
		if err := visit(openedDir{fd: fd, path: cur, created: created, leaf: leaf}); err != nil {
			unix.Close(fd)
			return fmt.Errorf("%s: %w", cur, err)
		}
		dirfd = fd
	}
	return unix.Close(dirfd)
}

// openChildNoFollow opens name beneath dirfd as a directory without
// following a symlink, creating it with mode (umask applies; the caller
// sets the exact mode on the descriptor) when it does not exist. The
// verdict comes from the openat alone; nothing here is decided by a
// separate stat.
func openChildNoFollow(dirfd int, name string, mode os.FileMode) (fd int, created bool, err error) {
	fd, err = openDir(dirfd, name, unix.O_NOFOLLOW)
	if errors.Is(err, unix.ENOENT) {
		switch err = unix.Mkdirat(dirfd, name, uint32(mode.Perm())); {
		case err == nil:
			created = true
		case errors.Is(err, unix.EEXIST):
			// Raced into existence; whatever it is now, the openat below
			// judges it.
		default:
			return -1, false, fmt.Errorf("mkdir: %w", err)
		}
		fd, err = openDir(dirfd, name, unix.O_NOFOLLOW)
	}
	switch {
	case err == nil:
		return fd, created, nil
	case errors.Is(err, unix.ELOOP), errors.Is(err, unix.ENOTDIR):
		// Linux reports a symlink under O_NOFOLLOW|O_DIRECTORY as ENOTDIR
		// (the link is not a directory), so the two are told apart for the
		// message only; the refusal is already decided by the failed open.
		var st unix.Stat_t
		if unix.Fstatat(dirfd, name, &st, unix.AT_SYMLINK_NOFOLLOW) == nil && st.Mode&unix.S_IFMT == unix.S_IFLNK {
			return -1, false, errors.New("is a symlink, refusing")
		}
		return -1, false, errors.New("is not a directory")
	}
	return -1, false, err
}

// openDir is openat(2) for a directory, retried on EINTR.
func openDir(dirfd int, name string, extra int) (int, error) {
	for {
		fd, err := unix.Openat(dirfd, name, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_CLOEXEC|extra, 0)
		if !errors.Is(err, unix.EINTR) {
			return fd, err
		}
	}
}

// ensureTraversableFd gives the opened directory r-x for group and other:
// exactly homeParentMode when this walk created it (mkdirat applied the
// umask), otherwise its current bits plus 0o055 and nothing more. A
// pre-existing directory is widened only when the reconcile's own uid
// owns it (root in production): a shared parent stays root:root by
// contract, so any other owner marks a user's directory — a home this
// run's Set does not happen to list — and is refused, never widened.
func ensureTraversableFd(d openedDir) error {
	if d.created {
		return unix.Fchmod(d.fd, uint32(homeParentMode))
	}
	var st unix.Stat_t
	if err := fstat(d.fd, &st); err != nil {
		return err
	}
	if st.Uid != uint32(os.Geteuid()) {
		return fmt.Errorf("owned by uid %d, not a shared parent, refusing", st.Uid)
	}
	perm := st.Mode & 0o7777
	if perm&0o055 != 0o055 { // needs r-x for BOTH group and other
		return unix.Fchmod(d.fd, perm|0o055)
	}
	return nil
}

// ensureOwnedFd chowns the opened directory to uid:gid, first setting its
// mode exactly when this walk created it. A pre-existing directory keeps
// its mode.
func ensureOwnedFd(d openedDir, uid, gid int, mode os.FileMode) error {
	if d.created {
		if err := unix.Fchmod(d.fd, uint32(mode.Perm())); err != nil {
			return err
		}
	}
	return fchown(d.fd, uid, gid)
}

func warnHome(cb func(string, error), stage string, err error) {
	if cb != nil && err != nil {
		cb("etcidentity:"+stage, err)
	}
}
