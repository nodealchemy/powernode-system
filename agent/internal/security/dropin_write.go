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
// optimization — it is what makes the round-9 in-place-upgrade's own
// partial-failure recovery succeed on a genuinely full disk: on a failure
// after the new digest's policy has already been applied, upgradeModule
// re-applies the OLD digest's policy to restore the still-running old
// process's on-disk confinement — best-effort, and it must never itself
// fail for lack of disk space when the content it is "writing" is already
// exactly what's there. Before this property existed (round 7), a fresh
// tmp-write-then-rename needed to allocate new blocks for the tmp file
// even when the content never changes, so a disk-full condition could
// defeat exactly the re-apply this exists to guarantee. Skipping the write
// when nothing would change needs no new blocks at all.
//
// L3 part (b) (review round 7, HIGH): the FIXED ".tmp" staging name this
// function uses is Lstat-checked here for the SAME failure mode the final
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

// removeDropInFile removes ONE drop-in file, shared by every stale-drop-in
// remover (R7, review round 14, hygiene — RemoveSeccompDropIn(At),
// RemoveCapabilityDropIn(At)): a manifest edit that stops declaring a
// seccomp profile, or a unit becoming privileged (which opts out of the
// capability/seccomp WRITES entirely), must not leave the file a PRIOR
// policy wrote still in effect — systemd keeps loading it until something
// removes it, unlike a write, which the reconciler re-runs every tick
// regardless of whether the content changed. Absence is success
// (os.ErrNotExist), matching every other drop-in remover in this codebase
// (stopDepartingUnits' own os.Remove/os.RemoveAll for a genuinely departed
// unit's WHOLE <unit>.d directory) — this function removes exactly one file
// within it, for a unit that is NOT departing, just no longer declaring
// that one directive.
func removeDropInFile(dropInDir, filename string) error {
	path := filepath.Join(dropInDir, filename)
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("removeDropInFile: remove %s: %w", path, err)
	}
	return nil
}
