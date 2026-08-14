package mount

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
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

// mountInfoEntry is one parsed mountinfo line — just the fields this
// package's readers consult. There is deliberately ONE parser
// (parseMountInfoLine) shared by LiveUnionLowerDirs and SubmountsBeneath;
// two parsers of the same table is how they drift apart.
type mountInfoEntry struct {
	id         int
	parentID   int
	mountPoint string // unescaped and cleaned
	fstype     string
	superOpts  string
}

// parseMountInfoLine parses one /proc/self/mountinfo line:
//
//	<id> <parent> <maj:min> <root> <mountpoint> <opts> [optional...] - <fstype> <source> <super opts>
//
// Callers decide what an unparseable line MEANS. LiveUnionLowerDirs skips
// it (its question — "which lowers does the overlay at X hold" — is
// answered by the one line that does parse); SubmountsBeneath errors (its
// question — "what is mounted beneath X" — is falsified by any line it
// cannot read).
//
// The LEFT half (id, parent, mount point) is strict — those fields are
// what the submount walk stands on. The RIGHT half is deliberately
// tolerant beyond the fstype: real kernels emit lines whose right half
// collapses under strings.Fields — `mount -t tmpfs "" /x` (an empty
// source, accepted by mount(2)) renders a double space and leaves two
// fields — and hard-erroring on that would let one unrelated exotic mount
// anywhere on the node fail every strict reader of the table. A missing
// right half loses only superOpts, which no left-half question needs.
func parseMountInfoLine(line string) (mountInfoEntry, error) {
	left, right, ok := strings.Cut(line, " - ")
	if !ok {
		return mountInfoEntry{}, fmt.Errorf("no ' - ' separator in %q", line)
	}
	lf := strings.Fields(left)
	if len(lf) < 5 {
		return mountInfoEntry{}, fmt.Errorf("%d fields before the separator in %q (want at least 5: id, parent, major:minor, root, mount point)", len(lf), line)
	}
	id, err := strconv.Atoi(lf[0])
	if err != nil {
		return mountInfoEntry{}, fmt.Errorf("mount id %q is not a number in %q", lf[0], line)
	}
	parent, err := strconv.Atoi(lf[1])
	if err != nil {
		return mountInfoEntry{}, fmt.Errorf("parent id %q is not a number in %q", lf[1], line)
	}
	rf := strings.Fields(right)
	if len(rf) == 0 {
		return mountInfoEntry{}, fmt.Errorf("nothing after the separator in %q (want at least a filesystem type)", line)
	}
	e := mountInfoEntry{
		id:         id,
		parentID:   parent,
		mountPoint: filepath.Clean(unescapeMountInfo(lf[4])),
		fstype:     rf[0],
	}
	if len(rf) >= 3 {
		e.superOpts = rf[2]
	}
	return e, nil
}

// readMountInfoEntries reads the whole table at mountInfoPath. strict
// decides what a line that fails to parse means: false skips it
// (LiveUnionLowerDirs — the one matching line answers its question),
// true errors (SubmountsBeneath — the skipped line could be the very
// mount the caller needs to know about). An unreadable or truncated
// table errors in both modes.
func readMountInfoEntries(strict bool) ([]mountInfoEntry, error) {
	f, err := os.Open(mountInfoPath)
	if err != nil {
		return nil, fmt.Errorf("open %s: %w", mountInfoPath, err)
	}
	defer f.Close()

	sc := bufio.NewScanner(f)
	// Mount tables stay well under the default 64KiB token cap, but a
	// long lowerdir list is exactly the field that could approach it —
	// a 20-layer union of sha256-named paths runs to ~1.6KiB — so give
	// the scanner room rather than silently truncating the one line we
	// actually care about.
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)

	var entries []mountInfoEntry
	for lineNo := 1; sc.Scan(); lineNo++ {
		e, perr := parseMountInfoLine(sc.Text())
		if perr != nil {
			if strict {
				return nil, fmt.Errorf("%s line %d: %w", mountInfoPath, lineNo, perr)
			}
			continue
		}
		entries = append(entries, e)
	}
	if err := sc.Err(); err != nil {
		return nil, fmt.Errorf("read %s: %w", mountInfoPath, err)
	}
	return entries, nil
}

// LiveUnionLowerDirs returns the lowerdir entries of the overlay mounted at
// mountPoint, in the order the kernel holds them (highest-priority first,
// matching LowerDirString).
//
// Returns an empty slice and no error when mountPoint carries no overlay —
// that is the ordinary cloud_init case, not a failure. An error means the
// mount table could not be read at all, which callers must treat as "I do
// not know", never as "no layers".
func LiveUnionLowerDirs(mountPoint string) ([]string, error) {
	entries, err := readMountInfoEntries(false)
	if err != nil {
		return nil, err
	}
	want := filepath.Clean(mountPoint)
	for _, e := range entries {
		if e.mountPoint != want || e.fstype != "overlay" {
			continue
		}
		for _, opt := range strings.Split(e.superOpts, ",") {
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
