package manifest

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/nodealchemy/powernode-system/agent/internal/fsutil"
)

// SaveAttachedSnapshot and LoadAttachedSnapshot (N3, review round 11) form a
// manifest store keyed by (moduleID, digest), independent of the ordinary
// ID-keyed "latest fetch" cache (writeCache/LoadFromDisk above). That cache
// answers "what did the platform most recently say about this module ID" —
// exactly one entry per ID, overwritten by every fetch regardless of
// digest — which is the right question for LoadOrFetch's offline fallback,
// but the WRONG one for reconcile.go's identity/sudoers/egress union and
// upgradeModule's own drop-in-snapshot bookkeeping (N6/N7): both need to
// know what a SPECIFIC digest's manifest content actually was, independent
// of whatever a LATER tick's fetch of a DIFFERENT (attempted) digest wrote
// over the ID-keyed cache in between. Without this, a second consecutive
// failed upgrade attempt reads the FIRST attempt's own (new) fetch back as
// "the old manifest" — reverting an identity union to new-only and
// dropping the old digest's own users, or losing track of which content
// the old digest's drop-ins should describe.
//
// This mechanism previously existed under the same names, deleted in round
// 9 when the detach-before-attach mitigation stack that used it for a
// different reason was removed. Brought back here because the in-place
// upgrade design has its own, independent need for the same fact.
//
// Callers persist a snapshot at the moment a digest becomes (or remains)
// the module's actually-attached, running content: a fresh attach, a
// version bump's step-7 commit, and a manifest-only reattach at an
// unchanged digest (which may have edited the content the snapshot at that
// digest describes). A digest's snapshot is never mutated by a fetch for
// ANY OTHER digest of the same module ID — that is the entire point.

// attachedSnapshotPath returns root/<moduleID>/attached/<digest>.json.
// sanitizeDigest mirrors mount.Layout's own (unexported, duplicated rather
// than shared to avoid a manifest<->mount import edge neither package
// otherwise needs): a real digest is "sha256:<hex>", and ':' is not a safe
// path component on every filesystem this agent targets.
func attachedSnapshotPath(root, moduleID, digest string) string {
	return filepath.Join(root, moduleID, "attached", sanitizeDigestForPath(digest)+".json")
}

func sanitizeDigestForPath(d string) string {
	out := make([]byte, 0, len(d))
	for _, c := range []byte(d) {
		switch {
		case c == ':' || c == '/' || c == ' ':
			out = append(out, '_')
		default:
			out = append(out, c)
		}
	}
	return string(out)
}

// SaveAttachedSnapshot persists m as the manifest content attached under
// (moduleID, digest). moduleID and digest must both be non-empty — an
// empty digest has no stable path (every empty-digest module shares one
// filename) and would let one module's genuinely-undigested snapshot
// silently overwrite another's.
func SaveAttachedSnapshot(root, moduleID, digest string, m *Manifest) error {
	if moduleID == "" {
		return errors.New("manifest.SaveAttachedSnapshot: empty moduleID")
	}
	if digest == "" {
		return errors.New("manifest.SaveAttachedSnapshot: empty digest")
	}
	if m == nil {
		return errors.New("manifest.SaveAttachedSnapshot: nil manifest")
	}
	path := attachedSnapshotPath(root, moduleID, digest)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("mkdir %s: %w", filepath.Dir(path), err)
	}
	return fsutil.AtomicWriteJSON(path, m, 0o644)
}

// LoadAttachedSnapshot reads the manifest previously saved for (moduleID,
// digest). Returns os.ErrNotExist (wrapped) when no snapshot exists — a
// pre-N3 agent build's entries, or a digest this build never itself
// attached.
func LoadAttachedSnapshot(root, moduleID, digest string) (*Manifest, error) {
	if moduleID == "" || digest == "" {
		return nil, os.ErrNotExist
	}
	path := attachedSnapshotPath(root, moduleID, digest)
	body, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var m Manifest
	if err := json.Unmarshal(body, &m); err != nil {
		return nil, fmt.Errorf("decode attached snapshot %s: %w", path, err)
	}
	return &m, nil
}
