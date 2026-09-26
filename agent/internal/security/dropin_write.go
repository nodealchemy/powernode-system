package security

import (
	"fmt"
	"os"
	"path/filepath"
)

// writeDropInFile is the ONE tmp-write-then-rename implementation shared by
// every real drop-in writer (WriteCapabilityDropIn/WriteCapabilityDropInAt,
// writeSeccompDropInAt, writeUserNamespaceDropInAt) — previously each of the
// four carried its own copy of the same three steps (mkdir, write-tmp,
// rename), which is exactly the kind of duplication that let the unit-name
// guard (validateDropInUnitName) drift apart before being unified (see that
// function's own doc comment). Centralizing this one too means an L3-class
// fix (review round 7) lands once for all four call sites, not four times
// with three chances to diverge.
//
// L3 part (c) (review round 7, HIGH): skips the write ENTIRELY when the
// on-disk file already holds byte-identical content. This is not merely an
// optimization — it is what makes a version-bump ROLLBACK
// (rollbackVersionBumpDetach, runtime/reconcile.go) succeed on a genuinely
// full disk: rollback re-attaches the OLD digest, which re-renders the
// SAME content that is already sitting at dropInPath. Before this, that
// re-render still went through the full tmp-write-then-rename path — which
// needs to allocate new blocks for the tmp file even though the content
// never changes — so a disk-full condition that caused the ORIGINAL
// (new-digest) attach to fail would ALSO fail the rollback's own re-write
// of unchanged old content, defeating the very thing rollback exists to
// guarantee. Skipping the write when nothing would change needs no new
// blocks at all, so the rollback path succeeds precisely when the old
// files are — as review round 7 put it — "intact": already on disk, in the
// state a no-op write would have left them in anyway.
//
// L3 part (b) (review round 7, HIGH): the FIXED ".tmp" staging name this
// function still uses (unlike ProbeDropInWritable's uniquely-generated
// probe name — see that function's own doc for why the two must never
// share a name) is Lstat-checked here as the SAME failure mode the final
// target already gets: if something non-regular already occupies the tmp
// path (most commonly a stray directory, review's own repro shape), the
// write is refused up front with a clear diagnosis instead of failing
// opaquely inside os.WriteFile.
func writeDropInFile(dropInDir, filename, body string) error {
	if err := os.MkdirAll(dropInDir, 0o755); err != nil {
		return fmt.Errorf("writeDropInFile: mkdir %s: %w", dropInDir, err)
	}

	dropInPath := filepath.Join(dropInDir, filename)

	// L3(c): skip entirely when nothing would change. A read failure (most
	// commonly os.ErrNotExist, the ordinary first-ever-write case) falls
	// through to the write below exactly as before this existed.
	if existing, err := os.ReadFile(dropInPath); err == nil && string(existing) == body {
		return nil
	}

	tmp := dropInPath + ".tmp"
	// L3(b): the fixed staging name gets the same non-regular-file check the
	// probe already applies to the final target — a real write's WriteFile
	// onto a path a directory (or other non-regular entry) already occupies
	// fails anyway, but this names the actual cause rather than surfacing
	// whatever bare os error WriteFile happens to return for it.
	if fi, err := os.Lstat(tmp); err == nil && !fi.Mode().IsRegular() {
		return fmt.Errorf("writeDropInFile: %s exists and is not a regular file (mode %v) — cannot stage the write", tmp, fi.Mode())
	}
	if err := os.WriteFile(tmp, []byte(body), 0o644); err != nil {
		return fmt.Errorf("writeDropInFile: write tmp %s: %w", tmp, err)
	}
	if err := os.Rename(tmp, dropInPath); err != nil {
		_ = os.Remove(tmp)
		return fmt.Errorf("writeDropInFile: rename %s: %w", tmp, err)
	}
	return nil
}
