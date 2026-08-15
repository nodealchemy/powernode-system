package mount

import (
	"fmt"
	"path/filepath"
)

// This file answers one question: which mounts does the live table hold
// BENEATH a given mount point?
//
// It exists for runtime.NextrootSurvivalGate. prepareNextrootMounts binds
// /persist into the nextroot with `mount --rbind`, and an rbind reproduces
// every child mount of the source as a separate mount beneath the
// destination — each with its own mountinfo-generated systemd unit and its
// own survival properties. A gate that probes the destination as ONE unit
// is blind to all of them: the top-level bind survives, a nested submount
// (a storage volume ReconcileStorageVolume mounted under /persist, say) is
// torn down at umount.target, and the new root comes up with /persist
// present but the volume's data gone from under it. The gate needs the
// full set to probe, and this walk is how it gets it.
//
// PARENT-ID WALK, NOT PATH PREFIX. Membership is decided by walking
// mountinfo parent ids from the entry (or entries) at mountPoint, never by
// string-prefix on paths. Prefix matching gets overmounts wrong twice: a
// second mount AT mountPoint is prefix-equal yet not beneath it, and the
// children hanging under that overmount ARE beneath it while sharing its
// exact path. The parent-id graph is the kernel's own answer to "what is
// attached under what", so it is the one this walk uses.
//
// FAIL CLOSED, EVERYWHERE. The caller is a boot-survival gate, so every
// ambiguity is an error, never an empty result:
//
//   - table unreadable            -> error (unknown is not "no submounts")
//   - any line unparseable        -> error (the line skipped could be the
//     submount this walk exists to find). "Unparseable" is judged by
//     parseMountInfoLine, which is strict on the left half this walk
//     stands on and tolerant of right-half-only defects — see its doc for
//     why a real kernel can emit those.
//   - mountPoint has NO entry     -> error (a destination the caller just
//     established that the table cannot see means the table cannot be
//     trusted about what lies beneath it)
//
// An empty result therefore carries meaning: mountPoint IS mounted and the
// kernel holds nothing beneath it.

// SubmountsBeneath returns the mount point of every entry in the live
// mount table attached (transitively) beneath mountPoint, walked by
// parent id. Overmounts AT mountPoint itself are traversed but not
// returned — they are the same path, and the caller probes that path
// already. See the file comment for the fail-closed contract.
func SubmountsBeneath(mountPoint string) ([]string, error) {
	want := filepath.Clean(mountPoint)
	entries, err := readMountInfoEntries(true) // strict: a skipped line could be the submount this walk exists to find
	if err != nil {
		return nil, fmt.Errorf("%w — a table this walk cannot fully read proves nothing about what is mounted beneath %s", err, want)
	}

	// EVERY entry at mountPoint seeds the walk, and seeding is also what
	// keeps overmounts out of the result: an overmount AT mountPoint is a
	// child entry with the same path, so collecting all same-path entries
	// as roots (marked seen up front) means the BFS below walks THROUGH
	// them to their children without ever emitting them — they are the
	// path the caller already probes. Do not "simplify" this to the first
	// matching entry: with a single root the overmount would surface as
	// its own submount, and its children would go unwalked.
	children := make(map[int][]mountInfoEntry, len(entries))
	var queue []int
	seen := map[int]bool{}
	for _, e := range entries {
		children[e.parentID] = append(children[e.parentID], e)
		if e.mountPoint == want && !seen[e.id] {
			queue = append(queue, e.id)
			seen[e.id] = true
		}
	}
	if len(queue) == 0 {
		return nil, fmt.Errorf("%s has no entry in %s — not mounted, or the table cannot be trusted; either way what lies beneath it is unknowable", want, mountInfoPath)
	}

	var out []string
	for len(queue) > 0 {
		id := queue[0]
		queue = queue[1:]
		for _, c := range children[id] {
			if seen[c.id] {
				continue
			}
			seen[c.id] = true
			queue = append(queue, c.id)
			out = append(out, c.mountPoint)
		}
	}
	return out, nil
}
