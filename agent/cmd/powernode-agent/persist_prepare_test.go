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

// TestRunPersistSetup covers the race-free /persist bring-up: settle for udev,
// then decide ONCE — disk-backed ext4 when the label resolves, tmpfs fallback
// when it doesn't, no-op when /persist is already mounted. No ConditionPathExists
// anywhere, so neither path can race udev.
func TestRunPersistSetup(t *testing.T) {
	origWait, origMounted := persistWaitForLabelFn, persistIsMountedFn
	origLookup, origSize, origRun := persistLookupLabelFn, persistPartitionBytesFn, persistRunFn
	t.Cleanup(func() {
		persistWaitForLabelFn, persistIsMountedFn = origWait, origMounted
		persistLookupLabelFn, persistPartitionBytesFn, persistRunFn = origLookup, origSize, origRun
	})

	t.Run("disk-backed ext4 when label resolves", func(t *testing.T) {
		persistIsMountedFn = func(string) bool { return false }
		persistWaitForLabelFn = func(string) string { return "/dev/sda2" }
		persistLookupLabelFn = func(string) (string, error) { return "/dev/sda2", nil }
		persistPartitionBytesFn = func(string) (int64, error) { return 511 * 1024 * 1024, nil }
		var calls [][]string
		persistRunFn = func(name, _ string, args ...string) error {
			calls = append(calls, append([]string{name}, args...))
			return nil
		}
		if err := runPersistSetup("persist", "/persist", 12); err != nil {
			t.Fatalf("runPersistSetup: %v", err)
		}
		// Grows (sfdisk+resize2fs) AND mounts ext4 at /persist; never tmpfs.
		if !containsCmd(calls, "sfdisk") || !containsCmd(calls, "resize2fs") {
			t.Errorf("expected grow (sfdisk+resize2fs); calls=%v", calls)
		}
		if !mountArgs(calls, "ext4", "/dev/sda2", "/persist") {
			t.Errorf("expected `mount -t ext4 /dev/sda2 /persist`; calls=%v", calls)
		}
		if mountType(calls, "tmpfs") {
			t.Errorf("must NOT tmpfs-mount when the label resolves; calls=%v", calls)
		}
	})

	t.Run("tmpfs fallback when label absent", func(t *testing.T) {
		persistIsMountedFn = func(string) bool { return false }
		persistWaitForLabelFn = func(string) string { return "" }
		persistLookupLabelFn = func(string) (string, error) { return "", nil }
		var calls [][]string
		persistRunFn = func(name, _ string, args ...string) error {
			calls = append(calls, append([]string{name}, args...))
			return nil
		}
		if err := runPersistSetup("persist", "/persist", 12); err != nil {
			t.Fatalf("runPersistSetup: %v", err)
		}
		if !mountType(calls, "tmpfs") {
			t.Errorf("expected tmpfs fallback mount; calls=%v", calls)
		}
		if containsCmd(calls, "sfdisk") || mountType(calls, "ext4") {
			t.Errorf("must NOT grow or ext4-mount when label absent; calls=%v", calls)
		}
	})

	t.Run("no-op when already mounted", func(t *testing.T) {
		persistIsMountedFn = func(string) bool { return true }
		var called bool
		persistWaitForLabelFn = func(string) string { t.Fatal("should not settle when already mounted"); return "" }
		persistRunFn = func(string, string, ...string) error { called = true; return nil }
		if err := runPersistSetup("persist", "/persist", 12); err != nil {
			t.Fatalf("runPersistSetup: %v", err)
		}
		if called {
			t.Error("expected no commands when /persist already mounted")
		}
	})
}

// mountArgs reports whether a `mount -t <fstype> ... <what> <where>` call is present.
func mountArgs(calls [][]string, fstype, what, where string) bool {
	for _, c := range calls {
		if len(c) == 0 || c[0] != "mount" {
			continue
		}
		var hasType, hasWhat, hasWhere bool
		for i, a := range c {
			if a == "-t" && i+1 < len(c) && c[i+1] == fstype {
				hasType = true
			}
			if a == what {
				hasWhat = true
			}
			if a == where {
				hasWhere = true
			}
		}
		if hasType && hasWhat && hasWhere {
			return true
		}
	}
	return false
}

func mountType(calls [][]string, fstype string) bool {
	for _, c := range calls {
		if len(c) == 0 || c[0] != "mount" {
			continue
		}
		for i, a := range c {
			if a == "-t" && i+1 < len(c) && c[i+1] == fstype {
				return true
			}
		}
	}
	return false
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
