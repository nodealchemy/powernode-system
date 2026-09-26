package security

import (
	"fmt"
	"os"
	"path/filepath"
)

// ProbeDropInWritable reports whether unit's systemd drop-in directory
// (systemdDropInRoot/<unit>.d) can currently accept a real write to
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
// Two independent checks, because a real write's failure modes split into
// two shapes that no single probe catches both of:
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
//  2. Everything else a write could fail on (ENOSPC, EROFS, a permission
//     problem on the directory itself) is reproduced by creating+removing a
//     UNIQUELY NAMED temp file in the SAME directory — never reusing or
//     colliding with a real writer's own fixed ".tmp" staging name, so a
//     probe can never race or clobber an in-flight real write.
//
// Also creates the directory first (MkdirAll — harmless: an empty <unit>.d
// is indistinguishable from an absent one to systemd, and this is the same
// mkdir the real writers themselves would need to succeed).
func ProbeDropInWritable(unit, targetBasename string) error {
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

	probe, err := os.CreateTemp(dropInDir, ".dropin-writable-probe-*")
	if err != nil {
		return fmt.Errorf("ProbeDropInWritable: create probe file: %w", err)
	}
	name := probe.Name()
	if cerr := probe.Close(); cerr != nil {
		_ = os.Remove(name)
		return fmt.Errorf("ProbeDropInWritable: close probe file: %w", cerr)
	}
	if err := os.Remove(name); err != nil {
		return fmt.Errorf("ProbeDropInWritable: remove probe file: %w", err)
	}
	return nil
}
