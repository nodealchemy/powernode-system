package security

import (
	"os"
	"path/filepath"
	"testing"
)

// TestProbeDropInWritable_RefusesWhenTheFixedTmpStagingNameIsBlocked is
// L3(b)'s red-first test (review round 7, HIGH): the real writers
// (writeDropInFile) all stage through a FIXED name — "<target>.tmp" — before
// renaming it onto the final target. If a stray non-regular entry (most
// commonly a directory, this package's standard write-failure fixture)
// already occupies exactly that fixed name, the real write's own tmp-file
// creation fails — a failure mode ProbeDropInWritable's original Lstat check
// (on the FINAL target only) never looked for, since a version-bump pre-check
// probing a still-healthy target would see nothing wrong there at all.
func TestProbeDropInWritable_RefusesWhenTheFixedTmpStagingNameIsBlocked(t *testing.T) {
	dropIns := t.TempDir()
	t.Cleanup(SetSystemdDropInRootForTest(dropIns))

	unit := "app.service"
	dropInDir := filepath.Join(dropIns, unit+".d")
	if err := os.MkdirAll(dropInDir, 0o755); err != nil {
		t.Fatal(err)
	}
	// Block the FIXED tmp staging name with a directory — the final target
	// itself ("capabilities.conf") is deliberately left ABSENT, so the
	// original final-target-only Lstat check has nothing to object to.
	if err := os.MkdirAll(filepath.Join(dropInDir, "capabilities.conf.tmp"), 0o755); err != nil {
		t.Fatal(err)
	}

	if err := ProbeDropInWritable(unit, "capabilities.conf", "irrelevant body"); err == nil {
		t.Errorf("L3(b) REGRESSION: expected ProbeDropInWritable to refuse when the fixed .tmp staging name is blocked by a non-regular entry, got nil error")
	}
}
