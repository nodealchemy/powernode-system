package mount

import (
	"fmt"
	"path/filepath"
)

// MountTable is ONE strict read of the live mount table, for callers that must
// answer several questions against the same snapshot and must never mistake an
// unreadable answer for a negative one.
//
// It exists for the boot state rebase (runtime/state_rebase.go), which may only
// forget a module when it can PROVE the module is not live. The readers it would
// otherwise reuse each fail toward "absent": IsMountpoint turns a findmnt error
// into (false, nil), and the tolerant table read skips lines it cannot parse. A
// strict table errors on either, so the caller's only options are a proven
// answer or "unknown".
type MountTable struct {
	entries []mountInfoEntry
}

// ReadMountTableStrict reads the mount table at mountInfoPath. Any unreadable,
// truncated or unparseable line is an error.
func ReadMountTableStrict() (*MountTable, error) {
	entries, err := readMountInfoEntries(true)
	if err != nil {
		return nil, err
	}
	return &MountTable{entries: entries}, nil
}

// IsMounted reports whether anything is mounted exactly at path.
func (t *MountTable) IsMounted(path string) bool {
	want := filepath.Clean(path)
	for _, e := range t.entries {
		if e.mountPoint == want {
			return true
		}
	}
	return false
}

// OverlayLowerDirs returns the lower layers of the overlay mounted at
// mountPoint. It errors when there is no overlay there, or when there is more
// than one (stacked mounts make "which union is live" ambiguous). An empty
// slice is returned as-is; whether an empty union is meaningful is the
// caller's call.
func (t *MountTable) OverlayLowerDirs(mountPoint string) ([]string, error) {
	want := filepath.Clean(mountPoint)
	var found []mountInfoEntry
	for _, e := range t.entries {
		if e.mountPoint == want && e.fstype == "overlay" {
			found = append(found, e)
		}
	}
	switch len(found) {
	case 0:
		return nil, fmt.Errorf("%w: %s", ErrNoOverlayAt, want)
	case 1:
		return overlayLowerDirs(found[0].superOpts), nil
	default:
		return nil, fmt.Errorf("%d overlays are stacked at %s; cannot tell which one is live", len(found), want)
	}
}
