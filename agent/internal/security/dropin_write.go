package security

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/nodealchemy/powernode-system/agent/internal/writeguard"
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
//
// changed (W1, IMP-caef5c00d63f round W, HIGH) reports whether the on-disk
// bytes actually DIFFERED from body (true) or were already byte-identical,
// so nothing was written (false) — a plain nil error cannot distinguish "I
// wrote something new" from "there was nothing to do", and a caller whose
// job is deciding whether a RUNNING unit needs a restart/reload needs
// exactly that distinction: a no-op write must never trigger one, but a
// real content change (e.g. a security drop-in) must, even though no unit
// BODY changed at all and AttachServicesModeOpts' own writeIfChanged never
// sees this write. A read failure (most commonly os.ErrNotExist, the
// ordinary first-ever-write case) counts as changed — going from "absent"
// to "present" is exactly the kind of change a caller must act on.
func writeDropInFile(dropInDir, filename, body string) (changed bool, err error) {
	// The ONE choke point every drop-in writer reaches (capabilities, seccomp,
	// userns, the restore path): under a test the directory must be inside the
	// sandbox, so a default /etc/systemd/system root is refused before any I/O.
	// The checked path is the FILE, so a filename that climbs out of the
	// directory (".." in it) is judged by where it really lands.
	if err := writeguard.Check(filepath.Join(dropInDir, filename)); err != nil {
		return false, fmt.Errorf("writeDropInFile: %w", err)
	}
	if err := os.MkdirAll(dropInDir, 0o755); err != nil {
		return false, fmt.Errorf("writeDropInFile: mkdir %s: %w", dropInDir, err)
	}

	dropInPath := filepath.Join(dropInDir, filename)

	// L3(c): skip entirely when nothing would change. A read failure (most
	// commonly os.ErrNotExist, the ordinary first-ever-write case) falls
	// through to the write below exactly as before this existed.
	if existing, err := os.ReadFile(dropInPath); err == nil && string(existing) == body {
		return false, nil
	}

	tmp := dropInPath + ".tmp"
	// L3(b): the fixed staging name gets the same non-regular-file check the
	// probe already applies to the final target — a real write's WriteFile
	// onto a path a directory (or other non-regular entry) already occupies
	// fails anyway, but this names the actual cause rather than surfacing
	// whatever bare os error WriteFile happens to return for it.
	if fi, err := os.Lstat(tmp); err == nil && !fi.Mode().IsRegular() {
		return false, fmt.Errorf("writeDropInFile: %s exists and is not a regular file (mode %v) — cannot stage the write", tmp, fi.Mode())
	}
	if err := os.WriteFile(tmp, []byte(body), 0o644); err != nil {
		return false, fmt.Errorf("writeDropInFile: write tmp %s: %w", tmp, err)
	}
	if err := os.Rename(tmp, dropInPath); err != nil {
		_ = os.Remove(tmp)
		return false, fmt.Errorf("writeDropInFile: rename %s: %w", tmp, err)
	}
	return true, nil
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
//
// changed (W1) mirrors writeDropInFile's own: true only when a file
// genuinely existed and was removed — an ALREADY-absent file (the ordinary
// steady-state case, re-checked every tick) is not a confinement change a
// caller needs to restart/reload for.
func removeDropInFile(dropInDir, filename string) (changed bool, err error) {
	path := filepath.Join(dropInDir, filename)
	if err := writeguard.Check(path); err != nil {
		return false, fmt.Errorf("removeDropInFile: %w", err)
	}
	if err := os.Remove(path); err != nil {
		if os.IsNotExist(err) {
			return false, nil
		}
		return false, fmt.Errorf("removeDropInFile: remove %s: %w", path, err)
	}
	return true, nil
}
