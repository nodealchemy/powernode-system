package security

import (
	"fmt"
	"os"
	"path/filepath"
)

// ProbeDropInWritable reports whether unit's systemd drop-in directory
// (systemdDropInRoot/<unit>.d) can currently accept a real write of body to
// targetBasename ("capabilities.conf" / "seccomp.conf" / "userns.conf"),
// WITHOUT writing or touching any of that unit's REAL drop-in content.
//
// K1 (review round 6, CRITICAL): the version-bump pre-check
// (filterUnsafeVersionBumpDetaches, selfhost.go) used to run
// applyModuleSecurityPolicy — the SAME function the real attach uses — which
// calls the REAL writers (WriteCapabilityDropIn et al.) unconditionally. On
// a version bump, the new and old digest of a module share the exact same
// unit name, so that pre-check was silently REWRITING the STILL-RUNNING old
// digest's live drop-ins with the NEW digest's content on every tick a bump
// was deferred — running the old binary under the new confinement, and
// repeating the mutation every tick until the bump either lands or is
// abandoned. This function exists so the pre-check can learn "would a write
// here succeed" without ever answering that question by actually performing
// the mutation it is trying to avoid.
//
// Three independent checks, because a real write's failure modes split into
// three shapes that no single probe catches all of:
//
//  1. The real writers all write-to-temp-then-rename ONTO targetBasename —
//     WriteCapabilityDropIn writes "capabilities.conf.tmp" then renames it
//     over "capabilities.conf" (mirrored exactly for seccomp.conf/
//     userns.conf). If something already occupies that exact name and is
//     NOT a regular file (most commonly a stray directory — the standard
//     write-failure fixture used throughout this package's own tests), the
//     rename fails exactly the same way for the real writer. Lstat-only:
//     never opens, renames onto, or replaces whatever is there, so an
//     EXISTING regular file (the unit's real, current drop-in content) is
//     read only for its file MODE, never its bytes.
//  2. L3(b) (review round 7, HIGH): the FIXED ".tmp" staging name itself —
//     the same real writers use, see writeDropInFile — gets the identical
//     Lstat check. Before this, a stray non-regular entry planted at
//     exactly "<targetBasename>.tmp" (rather than at the final target) was
//     invisible to this probe even though the real write's own tmp-file
//     creation would fail on it exactly the same way.
//  3. L3(a) (review round 7, HIGH): everything else a write could fail on —
//     ENOSPC, EROFS, a permission problem on the directory itself — is
//     reproduced by creating+writing+removing a UNIQUELY NAMED temp file in
//     the SAME directory, containing the REAL body's exact bytes, never
//     reusing or colliding with a real writer's own fixed ".tmp" staging
//     name (checked separately, above) so a probe can never race or clobber
//     an in-flight real write. Writing an EMPTY file (the original version
//     of this probe) needs no data blocks at all and so passes on a disk
//     that is full of DATA but has free inodes/metadata space — the real
//     write, which must actually persist body's bytes, would fail there.
//     Sizing the probe write to match what would really be written is what
//     makes this check mean anything on a full disk.
//
// Also creates the directory first (MkdirAll — harmless: an empty <unit>.d
// is indistinguishable from an absent one to systemd, and this is the same
// mkdir the real writers themselves would need to succeed).
func ProbeDropInWritable(unit, targetBasename, body string) error {
	if err := validateDropInUnitName("ProbeDropInWritable", unit); err != nil {
		return err
	}

	dropInDir := filepath.Join(systemdDropInRoot, unit+".d")
	if err := os.MkdirAll(dropInDir, 0o755); err != nil {
		return fmt.Errorf("ProbeDropInWritable: mkdir %s: %w", dropInDir, err)
	}

	target := filepath.Join(dropInDir, targetBasename)
	if fi, err := os.Lstat(target); err == nil {
		if !fi.Mode().IsRegular() {
			return fmt.Errorf("ProbeDropInWritable: %s exists and is not a regular file (mode %v) — the real write's rename onto it would fail the same way", target, fi.Mode())
		}
	} else if !os.IsNotExist(err) {
		return fmt.Errorf("ProbeDropInWritable: stat %s: %w", target, err)
	}

	// L3(b): the real writer's own fixed staging name — see writeDropInFile,
	// which applies this identical check before its real tmp-write.
	tmp := target + ".tmp"
	if fi, err := os.Lstat(tmp); err == nil {
		if !fi.Mode().IsRegular() {
			return fmt.Errorf("ProbeDropInWritable: %s exists and is not a regular file (mode %v) — the real write's own tmp-file creation would fail the same way", tmp, fi.Mode())
		}
	} else if !os.IsNotExist(err) {
		return fmt.Errorf("ProbeDropInWritable: stat %s: %w", tmp, err)
	}

	// L3(a): write the REAL body's exact bytes to a throwaway, uniquely
	// named file — never targetBasename or targetBasename+".tmp" (checked
	// above, never touched or raced by this probe) — so this reproduces the
	// real write's actual disk-space requirement, not merely "can we create
	// a zero-length file here".
	probe, err := os.CreateTemp(dropInDir, ".dropin-writable-probe-*")
	if err != nil {
		return fmt.Errorf("ProbeDropInWritable: create probe file: %w", err)
	}
	name := probe.Name()
	_, writeErr := probe.WriteString(body)
	closeErr := probe.Close()
	if writeErr != nil {
		_ = os.Remove(name)
		return fmt.Errorf("ProbeDropInWritable: write probe file: %w", writeErr)
	}
	if closeErr != nil {
		_ = os.Remove(name)
		return fmt.Errorf("ProbeDropInWritable: close probe file: %w", closeErr)
	}
	if err := os.Remove(name); err != nil {
		return fmt.Errorf("ProbeDropInWritable: remove probe file: %w", err)
	}
	return nil
}
