package security

import (
	"os/signal"
	"syscall"
	"testing"

	"golang.org/x/sys/unix"
)

// TestWriteCapabilityDropIn_SkipsTheWriteWhenContentIsAlreadyIdentical is
// L3(c)'s red-first test (review round 7, HIGH). The scenario it exists
// for: the round-9 in-place-upgrade's partial-failure recovery
// (upgradeModule, runtime/reconcile.go) re-applies the OLD digest's policy
// on a failure after the new digest's has already been written — content
// that is ALREADY sitting on disk unchanged, since the old process never
// stopped. Before this fix, that re-render still went through the full
// tmp-write-then-rename path, which needs to allocate NEW blocks even
// though the bytes never change — so a disk-full condition that caused the
// original (new-digest) write to fail would ALSO fail the recovery's own
// re-write of unchanged old content, defeating the guarantee it exists to
// provide. Skipping the write when nothing would change needs no new
// blocks at all.
//
// Proven here via RLIMIT_FSIZE, with SIGXFSZ ignored, standing in for a
// real (root-only) size-limited filesystem: a write that ACTUALLY changes
// content still correctly fails under the same tiny limit (proving this
// isn't "writes never fail anymore"), while re-writing byte-identical
// content succeeds because it is never attempted at all.
func TestWriteCapabilityDropIn_SkipsTheWriteWhenContentIsAlreadyIdentical(t *testing.T) {
	dropIns := t.TempDir()
	t.Cleanup(SetSystemdDropInRootForTest(dropIns))

	unit := "app.service"
	allow := []string{"CAP_CHOWN", "CAP_FOWNER", "CAP_DAC_OVERRIDE", "CAP_NET_BIND_SERVICE"}

	// First write happens with no rlimit constraint — establishes the
	// on-disk content this test's "unchanged" re-write will match.
	if err := WriteCapabilityDropIn(unit, allow); err != nil {
		t.Fatalf("initial write: %v", err)
	}

	signal.Ignore(syscall.SIGXFSZ)
	defer signal.Reset(syscall.SIGXFSZ)
	var lim unix.Rlimit
	if err := unix.Getrlimit(unix.RLIMIT_FSIZE, &lim); err != nil {
		t.Skipf("cannot read RLIMIT_FSIZE in this environment: %v", err)
	}
	orig := lim
	defer func() { _ = unix.Setrlimit(unix.RLIMIT_FSIZE, &orig) }()
	lim.Cur = 8 // bytes: far smaller than any real rendered drop-in body
	if err := unix.Setrlimit(unix.RLIMIT_FSIZE, &lim); err != nil {
		t.Skipf("cannot lower RLIMIT_FSIZE in this environment: %v", err)
	}

	// Sanity FIRST, same tiny limit: a write that must ACTUALLY change
	// content still fails under it — proving the limit is doing real work,
	// not that WriteCapabilityDropIn has stopped writing altogether.
	if err := WriteCapabilityDropIn(unit, []string{"CAP_SYS_ADMIN"}); err == nil {
		t.Fatalf("test setup: expected a genuinely CHANGED write to fail under an 8-byte RLIMIT_FSIZE")
	}
	// Restore the original content the "unchanged" case below expects,
	// still under no rlimit constraint (writing a small amount here is not
	// what this test is about).
	_ = unix.Setrlimit(unix.RLIMIT_FSIZE, &orig)
	if err := WriteCapabilityDropIn(unit, allow); err != nil {
		t.Fatalf("re-establish original content: %v", err)
	}
	if err := unix.Setrlimit(unix.RLIMIT_FSIZE, &lim); err != nil {
		t.Skipf("cannot lower RLIMIT_FSIZE in this environment: %v", err)
	}

	// The actual assertion: re-writing the EXACT SAME allow list (byte-
	// identical rendered content) must succeed even though a real write
	// could not possibly fit under this limit.
	if err := WriteCapabilityDropIn(unit, allow); err != nil {
		t.Errorf("L3(c) REGRESSION: expected re-writing byte-identical content to succeed by skipping the write entirely, got %v", err)
	}
}
