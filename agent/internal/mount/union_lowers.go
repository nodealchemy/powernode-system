package mount

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// This file answers one question: which directories does the CURRENTLY
// MOUNTED overlay at a given mount point still reference as lower layers?
//
// It exists because of a defect that silently deleted content from live
// nodes. On a pivot-booted node / IS the composed union, and its lowerdir
// is FIXED at mount time — the reconcile loop deliberately never rebuilds
// it (see the union-skip block in RunOnce). The detach path, however, was
// written against the cloud_init model, where the union lives at /sysroot
// and IS recomposed on every stack change; its comment reasoned that
// unmounting a superseded module is safe because "the union is rebuilt
// with the remaining stack". On a pivot node that rebuild never happens,
// so unmounting a module whose path the live union still lists rips that
// layer's files out of the running root. Nothing errors; the paths simply
// stop resolving.
//
// Observed 2026-08-07: /'s lowerdir still named the previous runtime-go
// layer while its mount point sat empty, and the entire Go toolchain —
// GOROOT/src included — was missing from /. Re-mounting the same blob at
// the same path restored it.

// mountInfoPath is the procfs source for the live mount table. A var, not
// a const, so tests can point it at a fixture instead of requiring a real
// overlay-rooted host.
var mountInfoPath = "/proc/self/mountinfo"

// LiveUnionLowerDirs returns the lowerdir entries of the overlay mounted at
// mountPoint, in the order the kernel holds them (highest-priority first,
// matching LowerDirString).
//
// Returns an empty slice and no error when mountPoint carries no overlay —
// that is the ordinary cloud_init case, not a failure. An error means the
// mount table could not be read at all, which callers must treat as "I do
// not know", never as "no layers".
func LiveUnionLowerDirs(mountPoint string) ([]string, error) {
	f, err := os.Open(mountInfoPath)
	if err != nil {
		return nil, fmt.Errorf("open %s: %w", mountInfoPath, err)
	}
	defer f.Close()

	want := filepath.Clean(mountPoint)
	sc := bufio.NewScanner(f)
	// Mount tables stay well under the default 64KiB token cap, but a
	// long lowerdir list is exactly the field that could approach it —
	// a 20-layer union of sha256-named paths runs to ~1.6KiB — so give
	// the scanner room rather than silently truncating the one line we
	// actually care about.
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)

	for sc.Scan() {
		line := sc.Text()
		// mountinfo: <id> <parent> <maj:min> <root> <mountpoint> <opts>
		// [optional fields...] - <fstype> <source> <super options>
		left, right, ok := strings.Cut(line, " - ")
		if !ok {
			continue
		}
		lf := strings.Fields(left)
		if len(lf) < 5 || unescapeMountInfo(lf[4]) != want {
			continue
		}
		rf := strings.Fields(right)
		if len(rf) < 3 || rf[0] != "overlay" {
			continue
		}
		for _, opt := range strings.Split(rf[2], ",") {
			val, found := strings.CutPrefix(opt, "lowerdir=")
			if !found {
				continue
			}
			// Colon separates layers. A module mount path can never
			// contain one — sanitizeDigest rewrites ':' to '_' precisely
			// so digests survive path handling — so a plain split is
			// safe here.
			out := make([]string, 0, strings.Count(val, ":")+1)
			for _, d := range strings.Split(val, ":") {
				if d = strings.TrimSpace(unescapeMountInfo(d)); d != "" {
					out = append(out, filepath.Clean(d))
				}
			}
			return out, nil
		}
		return []string{}, nil // overlay at this point, but no lowerdir opt
	}
	if err := sc.Err(); err != nil {
		return nil, fmt.Errorf("read %s: %w", mountInfoPath, err)
	}
	return []string{}, nil
}

// PathInLiveUnion reports whether dir is one of the lower layers of the
// overlay mounted at mountPoint.
//
// The error is deliberately NOT folded into the bool. The caller's failure
// modes are wildly asymmetric: wrongly believing a path is unused costs a
// live node its files, while wrongly believing it is in use costs one idle
// loop device until the next reboot. Callers must fail toward "in use".
func PathInLiveUnion(mountPoint, dir string) (bool, error) {
	lowers, err := LiveUnionLowerDirs(mountPoint)
	if err != nil {
		return false, err
	}
	target := filepath.Clean(dir)
	for _, l := range lowers {
		if l == target {
			return true, nil
		}
	}
	return false, nil
}

// unescapeMountInfo decodes the octal escapes the kernel uses in
// mountinfo for characters that would otherwise break field splitting
// (space \040, tab \011, newline \012, backslash \134).
func unescapeMountInfo(s string) string {
	if !strings.Contains(s, `\`) {
		return s
	}
	r := strings.NewReplacer(
		`\040`, " ",
		`\011`, "\t",
		`\012`, "\n",
		`\134`, `\`,
	)
	return r.Replace(s)
}

// SetMountInfoPathForTest points the mount-table parser at a fixture and
// returns a restore func. Exported so packages outside mount (the
// reconciler, whose detach guard keys off this) can exercise the guard
// without a real overlay-rooted host.
func SetMountInfoPathForTest(path string) (restore func()) {
	prev := mountInfoPath
	mountInfoPath = path
	return func() { mountInfoPath = prev }
}
