package main

import "testing"

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
