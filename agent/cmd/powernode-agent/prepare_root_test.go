package main

import (
	"os"
	"path/filepath"
	"testing"
)

// TestPrepareRootDispatch_RoutesBySource locks the #67 fix: `prepare-root
// --source oci` must delegate to the dynamic OCI composer (the platform's real
// assigned module set), NOT the legacy hardcoded-9p path — and the default
// still routes to the legacy 9p path. Before the OCI dispatch existed,
// prepare-root only ran the hardcoded `--modules system-base,nginx` 9p flow.
func TestPrepareRootDispatch_RoutesBySource(t *testing.T) {
	origOCI, orig9p := runPrepareRootOCIFn, runPrepareRoot9pFn
	t.Cleanup(func() { runPrepareRootOCIFn, runPrepareRoot9pFn = origOCI, orig9p })

	var ociCalls, nineCalls int
	var ociSysroot string
	var nine9pModules []string
	runPrepareRootOCIFn = func(sysroot string) error {
		ociCalls++
		ociSysroot = sysroot
		return nil
	}
	runPrepareRoot9pFn = func(_, _, _ string, modules []string) error {
		nineCalls++
		nine9pModules = modules
		return nil
	}

	// source=oci → OCI composer only, with the requested sysroot; the legacy
	// hardcoded-9p path is never taken.
	if err := dispatchPrepareRoot("oci", "/run/powernode/modules", "/sysroot", "powernode_modules", []string{"system-base", "nginx"}); err != nil {
		t.Fatalf("oci dispatch: %v", err)
	}
	if ociCalls != 1 || nineCalls != 0 {
		t.Errorf("source=oci: ociCalls=%d nineCalls=%d; want 1/0", ociCalls, nineCalls)
	}
	if ociSysroot != "/sysroot" {
		t.Errorf("source=oci: composed sysroot=%q; want /sysroot", ociSysroot)
	}

	// default (empty) → legacy 9p path only.
	ociCalls, nineCalls = 0, 0
	if err := dispatchPrepareRoot("", "/run/powernode/modules", "/sysroot", "powernode_modules", []string{"system-base"}); err != nil {
		t.Fatalf("default dispatch: %v", err)
	}
	if ociCalls != 0 || nineCalls != 1 {
		t.Errorf("source=default: ociCalls=%d nineCalls=%d; want 0/1", ociCalls, nineCalls)
	}
	if len(nine9pModules) != 1 || nine9pModules[0] != "system-base" {
		t.Errorf("source=default: 9p modules=%v; want [system-base]", nine9pModules)
	}

	// explicit 9p → legacy path.
	ociCalls, nineCalls = 0, 0
	if err := dispatchPrepareRoot("9p", "/run/powernode/modules", "/sysroot", "powernode_modules", nil); err != nil {
		t.Fatalf("9p dispatch: %v", err)
	}
	if ociCalls != 0 || nineCalls != 1 {
		t.Errorf("source=9p: ociCalls=%d nineCalls=%d; want 0/1", ociCalls, nineCalls)
	}

	// unknown source → error, no path taken.
	ociCalls, nineCalls = 0, 0
	if err := dispatchPrepareRoot("bogus", "", "/sysroot", "", nil); err == nil {
		t.Error("source=bogus: expected error, got nil")
	}
	if ociCalls != 0 || nineCalls != 0 {
		t.Errorf("source=bogus: ociCalls=%d nineCalls=%d; want 0/0", ociCalls, nineCalls)
	}
}

// TestEnsureCanonicalInit_SynthesizesSbinInit locks the last-mile switch_root
// fix: the composed module rootfs may ship systemd only at
// /usr/lib/systemd/systemd with NO /sbin/init. The mount unit's
// `systemctl switch-root /sysroot /sbin/init` chase-validates that init path
// and fails the whole unit (no pivot) when it's absent. The composer must
// therefore guarantee a canonical /sbin/init resolving to whatever init the
// module rootfs actually provides.
func TestEnsureCanonicalInit_SynthesizesSbinInit(t *testing.T) {
	// Rootfs that ships systemd only at usr/lib/systemd/systemd — the exact
	// shape observed on the real erofs hub modules (no /sbin/init).
	sysroot := t.TempDir()
	realInit := filepath.Join(sysroot, "usr/lib/systemd/systemd")
	if err := os.MkdirAll(filepath.Dir(realInit), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(realInit, []byte("#!/bin/true\n"), 0o755); err != nil {
		t.Fatal(err)
	}

	got, err := ensureCanonicalInit(sysroot)
	if err != nil {
		t.Fatalf("ensureCanonicalInit: %v", err)
	}
	if got != "/usr/lib/systemd/systemd" {
		t.Errorf("resolved init=%q; want /usr/lib/systemd/systemd (new-root-absolute)", got)
	}

	// /sbin/init must now exist and resolve to the real init, so
	// `switch-root /sysroot /sbin/init` succeeds.
	sbinInit := filepath.Join(sysroot, "sbin/init")
	lst, err := os.Lstat(sbinInit)
	if err != nil {
		t.Fatalf("stat %s: %v", sbinInit, err)
	}
	if lst.Mode()&os.ModeSymlink == 0 {
		t.Errorf("%s is not a symlink (mode=%v)", sbinInit, lst.Mode())
	}
	target, err := os.Readlink(sbinInit)
	if err != nil {
		t.Fatalf("readlink %s: %v", sbinInit, err)
	}
	if target != "/usr/lib/systemd/systemd" {
		t.Errorf("/sbin/init -> %q; want /usr/lib/systemd/systemd (new-root-absolute)", target)
	}
}

// TestEnsureCanonicalInit_LeavesExistingSbinInit: when the rootfs already
// ships /sbin/init, it's honored as-is with no symlink munging.
func TestEnsureCanonicalInit_LeavesExistingSbinInit(t *testing.T) {
	sysroot := t.TempDir()
	sbinInit := filepath.Join(sysroot, "sbin/init")
	if err := os.MkdirAll(filepath.Dir(sbinInit), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(sbinInit, []byte("#!/bin/true\n"), 0o755); err != nil {
		t.Fatal(err)
	}

	got, err := ensureCanonicalInit(sysroot)
	if err != nil {
		t.Fatalf("ensureCanonicalInit: %v", err)
	}
	if got != "/sbin/init" {
		t.Errorf("resolved init=%q; want /sbin/init", got)
	}
	// Must remain a regular file, not have been replaced by a symlink.
	lst, err := os.Lstat(sbinInit)
	if err != nil {
		t.Fatal(err)
	}
	if lst.Mode()&os.ModeSymlink != 0 {
		t.Errorf("%s was replaced by a symlink; existing /sbin/init must be left intact", sbinInit)
	}
}

// TestEnsureCanonicalInit_ReplacesDanglingSbinInit: a dangling /sbin/init
// symlink (points nowhere) must not block synthesis — it's os.Stat-invisible
// yet would EEXIST a naive os.Symlink. The fix must replace it.
func TestEnsureCanonicalInit_ReplacesDanglingSbinInit(t *testing.T) {
	sysroot := t.TempDir()
	if err := os.MkdirAll(filepath.Join(sysroot, "sbin"), 0o755); err != nil {
		t.Fatal(err)
	}
	// Dangling: target does not exist.
	if err := os.Symlink("/nonexistent/init", filepath.Join(sysroot, "sbin/init")); err != nil {
		t.Fatal(err)
	}
	realInit := filepath.Join(sysroot, "usr/lib/systemd/systemd")
	if err := os.MkdirAll(filepath.Dir(realInit), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(realInit, []byte("#!/bin/true\n"), 0o755); err != nil {
		t.Fatal(err)
	}

	got, err := ensureCanonicalInit(sysroot)
	if err != nil {
		t.Fatalf("ensureCanonicalInit: %v", err)
	}
	if got != "/usr/lib/systemd/systemd" {
		t.Errorf("resolved init=%q; want /usr/lib/systemd/systemd", got)
	}
	target, err := os.Readlink(filepath.Join(sysroot, "sbin/init"))
	if err != nil {
		t.Fatalf("readlink: %v", err)
	}
	if target != "/usr/lib/systemd/systemd" {
		t.Errorf("dangling /sbin/init not repaired: -> %q; want /usr/lib/systemd/systemd", target)
	}
}

// TestEnsureCanonicalInit_NoInit: a rootfs with no init anywhere is a hard
// error (better a loud compose failure than a silent no-pivot).
func TestEnsureCanonicalInit_NoInit(t *testing.T) {
	if _, err := ensureCanonicalInit(t.TempDir()); err == nil {
		t.Error("expected error for rootfs with no init, got nil")
	}
}
