package etcidentity

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/nodealchemy/powernode-system/agent/internal/fsutil"
	"github.com/nodealchemy/powernode-system/agent/internal/writeguard"
)

// TimezoneNameMax bounds a zoneinfo name. The longest real one is well under
// this; the bound exists so a hostile value cannot grow a path.
const TimezoneNameMax = 64

// timezoneNameRe is the SHAPE of a zoneinfo name: path segments of letters,
// digits, underscore, plus and minus ("America/Argentina/Buenos_Aires",
// "Etc/GMT+5"), joined by single slashes. No dot, so neither "." nor ".." can
// appear, no leading or trailing slash, no whitespace, control byte or NUL.
var timezoneNameRe = regexp.MustCompile(`^[A-Za-z0-9_+\-]+(?:/[A-Za-z0-9_+\-]+)*$`)

// zoneinfoDir is where the image's zone files live, relative to a root.
const zoneinfoDir = "usr/share/zoneinfo"

// ValidTimezoneName reports whether name has the shape of a zoneinfo name. It
// does NOT check the image; ApplyTimezone does, against the root it renders into.
func ValidTimezoneName(name string) bool {
	return name != "" && len(name) <= TimezoneNameMax && timezoneNameRe.MatchString(name)
}

// ApplyTimezone makes <root>/etc/localtime a relative symlink to the named zone
// and <root>/etc/timezone hold its name, the two files `timedatectl
// set-timezone` writes. It is the timezone analogue of ApplyHostname: the agent
// OWNS these files, because /etc on a module-composed node is on the root
// overlay and a timezone set by hand reverts to UTC at the next boot.
//
// The name comes from per-node configuration, so it is VALIDATED before
// anything is written: it must have the shape of a zoneinfo name
// (ValidTimezoneName), and it must name a real zone file in THIS image, i.e.
// <root>/usr/share/zoneinfo/<name> must resolve (symlinks followed) to a regular
// file that stays inside the zoneinfo tree and starts with the TZif magic. A name
// the image does not carry is refused rather than rendered as a dangling link,
// and a refusal leaves both files untouched.
//
// Every path is write-guarded (writeguard.Check) before any mutation, and the
// writes are atomic: the link is swapped in by rename, the file by
// fsutil.AtomicWrite. Idempotent: a zone already rendered is a no-op, so
// reconcile ticks never churn the files.
//
// root == "" targets the live filesystem; a non-empty root targets a composed
// union (the pivot sysroot). An empty name is a no-op: this function never
// invents a timezone, and clearing the declared setting does not revert an
// already-rendered one (the caller owns sourcing the value, see
// runtime.desiredTimezone).
//
// Returns (changed, error): changed is true when either file was mutated.
func ApplyTimezone(root, name string) (changed bool, err error) {
	name = strings.TrimSpace(name)
	if name == "" {
		return false, nil
	}
	if !ValidTimezoneName(name) {
		return false, fmt.Errorf("timezone %q is not a zoneinfo name", name)
	}
	if err := checkZoneInImage(root, name); err != nil {
		return false, err
	}

	etcDir := filepath.Join(root, "etc")
	if root == "" {
		etcDir = "/etc"
	}
	localtime := filepath.Join(etcDir, "localtime")
	tzfile := filepath.Join(etcDir, "timezone")
	for _, p := range []string{localtime, tzfile} {
		if err := writeguard.Check(p); err != nil {
			return false, err
		}
	}

	// Relative, as systemd writes it, so the link means the same thing inside the
	// pivot sysroot and after switch_root.
	target := "../" + zoneinfoDir + "/" + name

	if cur, rerr := os.Readlink(localtime); rerr != nil || cur != target {
		if err := os.MkdirAll(etcDir, 0o755); err != nil {
			return changed, fmt.Errorf("mkdir %s: %w", etcDir, err)
		}
		tmp := filepath.Join(etcDir, fmt.Sprintf(".localtime.tmp-%d", os.Getpid()))
		_ = os.Remove(tmp)
		if err := os.Symlink(target, tmp); err != nil {
			return changed, fmt.Errorf("symlink %s: %w", tmp, err)
		}
		if err := os.Rename(tmp, localtime); err != nil {
			_ = os.Remove(tmp)
			return changed, fmt.Errorf("replace %s: %w", localtime, err)
		}
		changed = true
	}

	if cur, rerr := os.ReadFile(tzfile); rerr != nil || !bytes.Equal(bytes.TrimSpace(cur), []byte(name)) {
		if err := fsutil.AtomicWrite(tzfile, []byte(name+"\n"), 0o644); err != nil {
			return changed, fmt.Errorf("write %s: %w", tzfile, err)
		}
		changed = true
	}
	return changed, nil
}

// checkZoneInImage proves <root>/usr/share/zoneinfo/<name> is a real zone file
// of this image: resolved through every symlink it must remain inside the
// zoneinfo tree (a link out of it is refused), be a regular file, and start with
// the TZif magic every compiled zone file carries.
func checkZoneInImage(root, name string) error {
	base := filepath.Join(root, zoneinfoDir)
	if root == "" {
		base = "/" + zoneinfoDir
	}
	realBase, err := filepath.EvalSymlinks(base)
	if err != nil {
		return fmt.Errorf("timezone %q: image has no zoneinfo tree (%s): %w", name, base, err)
	}
	resolved, err := filepath.EvalSymlinks(filepath.Join(base, name))
	if err != nil {
		return fmt.Errorf("timezone %q: not present in the image's zoneinfo", name)
	}
	if !strings.HasPrefix(resolved, realBase+string(filepath.Separator)) {
		return fmt.Errorf("timezone %q: resolves outside the zoneinfo tree", name)
	}
	info, err := os.Stat(resolved)
	if err != nil || !info.Mode().IsRegular() {
		return fmt.Errorf("timezone %q: not a zone file", name)
	}
	f, err := os.Open(resolved)
	if err != nil {
		return fmt.Errorf("timezone %q: %w", name, err)
	}
	defer f.Close()
	magic := make([]byte, 4)
	if _, err := io.ReadFull(f, magic); err != nil || string(magic) != "TZif" {
		return fmt.Errorf("timezone %q: not a compiled zone file", name)
	}
	return nil
}
