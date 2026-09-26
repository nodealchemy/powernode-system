package security

import (
	"os/signal"
	"syscall"
	"testing"

	"golang.org/x/sys/unix"
)

// TestProbeDropInWritable_SizedBodyCatchesADiskFullOfDataWithFreeInodes is
// L3(a)'s red-first test (review round 7, HIGH): the ORIGINAL probe wrote
// only a zero-length throwaway file, which needs no DATA blocks at all — on
// a filesystem that is full of data but still has free inodes/metadata
// space (the ordinary shape of "disk full"), that empty-file probe reports
// success while a REAL write (which must actually persist the rendered
// drop-in's bytes) would fail with ENOSPC. Sizing the probe's throwaway
// write to the real rendered body is what makes this check mean anything.
//
// Reproducing a genuine ENOSPC needs a real size-limited filesystem, which
// needs root to mount (verified unavailable in this sandbox). RLIMIT_FSIZE
// is the standard non-root substitute: it caps how many bytes ANY single
// write to a regular file in THIS PROCESS may produce, returning EFBIG
// ("file too large") from the write call itself once exceeded -- the same
// observable shape (a write that fails because there was nowhere left to
// put the bytes) a real ENOSPC produces, without needing an actual
// size-limited block device. SIGXFSZ must be ignored first, or the
// default action kills the process outright instead of the write simply
// returning an error.
func TestProbeDropInWritable_SizedBodyCatchesADiskFullOfDataWithFreeInodes(t *testing.T) {
	dropIns := t.TempDir()
	t.Cleanup(SetSystemdDropInRootForTest(dropIns))

	signal.Ignore(syscall.SIGXFSZ)
	defer signal.Reset(syscall.SIGXFSZ)

	var lim unix.Rlimit
	if err := unix.Getrlimit(unix.RLIMIT_FSIZE, &lim); err != nil {
		t.Skipf("cannot read RLIMIT_FSIZE in this environment: %v", err)
	}
	orig := lim
	defer func() { _ = unix.Setrlimit(unix.RLIMIT_FSIZE, &orig) }()

	lim.Cur = 32 // bytes: enough for a handful of bytes, nowhere near a real drop-in body
	if err := unix.Setrlimit(unix.RLIMIT_FSIZE, &lim); err != nil {
		t.Skipf("cannot lower RLIMIT_FSIZE in this environment: %v", err)
	}

	largeBody, err := RenderCapabilityDropInBody([]string{"CAP_CHOWN", "CAP_FOWNER", "CAP_DAC_OVERRIDE", "CAP_NET_BIND_SERVICE"})
	if err != nil {
		t.Fatal(err)
	}
	if len(largeBody) <= int(lim.Cur) {
		t.Fatalf("test setup: rendered body (%d bytes) must exceed the %d-byte rlimit for this test to mean anything", len(largeBody), lim.Cur)
	}

	if perr := ProbeDropInWritable("app.service", "capabilities.conf", largeBody); perr == nil {
		t.Errorf("L3(a) REGRESSION: expected ProbeDropInWritable to refuse when the REAL body's size exceeds available space, got nil error")
	}

	// Sanity, same rlimit still active: a body genuinely within the limit
	// still probes clean. Without this, the failure above could just as
	// easily mean "this rlimit trick broke ProbeDropInWritable generally",
	// not specifically "large bodies are now correctly caught".
	if perr := ProbeDropInWritable("app.service", "userns.conf", "ok"); perr != nil {
		t.Errorf("expected a body well within the limit to still probe clean, got %v", perr)
	}
}
