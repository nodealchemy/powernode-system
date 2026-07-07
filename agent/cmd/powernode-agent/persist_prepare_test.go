package main

import (
	"testing"
)

// TestRunPersistPrepare covers the #69 disk-backed /persist grow logic: the
// baked p2 (label "persist") is grown to a BOUNDED target size on first boot
// and left alone on subsequent boots. persist-prepare only resizes the
// partition + filesystem; persist.mount does the actual mount.
func TestRunPersistPrepare(t *testing.T) {
	origLookup, origSize, origRun := persistLookupLabelFn, persistPartitionBytesFn, persistRunFn
	t.Cleanup(func() {
		persistLookupLabelFn, persistPartitionBytesFn, persistRunFn = origLookup, origSize, origRun
	})

	const gib = int64(1024 * 1024 * 1024)

	// --- Scenario 1: first boot — partition smaller than target → grow ---
	t.Run("grows when smaller than target", func(t *testing.T) {
		persistLookupLabelFn = func(label string) (string, error) {
			if label != "persist" {
				t.Fatalf("label=%q; want persist", label)
			}
			return "/dev/sda2", nil
		}
		persistPartitionBytesFn = func(dev string) (int64, error) { return 511 * 1024 * 1024, nil } // 511M

		var calls [][]string
		persistRunFn = func(name, _ string, args ...string) error {
			calls = append(calls, append([]string{name}, args...))
			return nil
		}

		if err := runPersistPrepare("persist", 12); err != nil {
			t.Fatalf("runPersistPrepare: %v", err)
		}
		// Must resize the PARTITION (sfdisk on the parent disk, partition 2) then
		// re-read the table then grow the FS (resize2fs on the partition device).
		joined := ""
		for _, c := range calls {
			for _, a := range c {
				joined += a + " "
			}
			joined += "|"
		}
		if !containsCmd(calls, "sfdisk") {
			t.Errorf("expected an sfdisk partition resize; calls=%v", calls)
		}
		if !containsCmd(calls, "resize2fs") {
			t.Errorf("expected a resize2fs; calls=%v", calls)
		}
		// resize2fs must target the partition device, not the parent disk.
		if !cmdWithArg(calls, "resize2fs", "/dev/sda2") {
			t.Errorf("resize2fs should target /dev/sda2; calls=%v", calls)
		}
		// sfdisk must operate on the PARENT disk (/dev/sda), not the partition.
		if !cmdWithArg(calls, "sfdisk", "/dev/sda") {
			t.Errorf("sfdisk should target parent disk /dev/sda; calls=%v", calls)
		}
	})

	// --- Scenario 2: reboot — partition already at/above target → no-op ---
	t.Run("no-op when already at target", func(t *testing.T) {
		persistLookupLabelFn = func(string) (string, error) { return "/dev/sda2", nil }
		persistPartitionBytesFn = func(string) (int64, error) { return 12 * gib, nil } // already 12G

		var calls [][]string
		persistRunFn = func(name, _ string, args ...string) error {
			calls = append(calls, append([]string{name}, args...))
			return nil
		}
		if err := runPersistPrepare("persist", 12); err != nil {
			t.Fatalf("runPersistPrepare: %v", err)
		}
		if len(calls) != 0 {
			t.Errorf("expected no resize commands when already sized; got %v", calls)
		}
	})

	// --- Scenario 3: no persist-labeled partition → no-op, no error (tmpfs fallback) ---
	t.Run("no-op when label absent", func(t *testing.T) {
		persistLookupLabelFn = func(string) (string, error) { return "", nil }
		persistPartitionBytesFn = func(string) (int64, error) {
			t.Fatal("should not probe size when no label")
			return 0, nil
		}
		var called bool
		persistRunFn = func(string, string, ...string) error { called = true; return nil }
		if err := runPersistPrepare("persist", 12); err != nil {
			t.Fatalf("expected nil error when label absent, got %v", err)
		}
		if called {
			t.Error("expected no resize commands when persist label absent")
		}
	})
}

func containsCmd(calls [][]string, name string) bool {
	for _, c := range calls {
		if len(c) > 0 && c[0] == name {
			return true
		}
	}
	return false
}

func cmdWithArg(calls [][]string, name, arg string) bool {
	for _, c := range calls {
		if len(c) == 0 || c[0] != name {
			continue
		}
		for _, a := range c[1:] {
			if a == arg {
				return true
			}
		}
	}
	return false
}
