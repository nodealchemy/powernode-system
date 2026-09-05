package security

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// G2 offer 01a02f70-57ce — selinux_profile / apparmor_profile are
// operator-reachable strings from a module's config block. Under the
// SECURITY-BLOCK CONTRACT (server/app/services/system/module_config_validator.rb)
// they are bare NAMES that resolve against an AGENT-OWNED profile set —
// never a host path, never a module-rootfs path — and resolution fails
// CLOSED.
//
// SAFETY: temp dirs only. The RecorderRunner never executes anything.

// TestLoadAppArmorProfile_RefusesHostPath: a module that declares an
// absolute host path must be refused BEFORE anything reaches
// apparmor_parser. Pre-fix, LoadAppArmorProfile os.Stat()s the arbitrary
// path and hands it straight to the loader.
func TestLoadAppArmorProfile_RefusesHostPath(t *testing.T) {
	evil := filepath.Join(t.TempDir(), "evil-profile")
	if err := os.WriteFile(evil, []byte("profile evil { }\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	rec := &mount.RecorderRunner{}
	err := LoadAppArmorProfile(context.Background(), rec, evil)
	if err == nil {
		t.Fatalf("accepted arbitrary host path %q", evil)
	}
	if errors.Is(err, ErrAppArmorNotAvailable) {
		t.Fatalf("refusal must be the name-containment check, not host LSM availability; got %v", err)
	}
	for _, inv := range rec.Invocations {
		if inv.Name == "apparmor_parser" {
			t.Fatalf("apparmor_parser invoked with %v despite refusal", inv.Args)
		}
	}
}

// Same containment for SELinux. The error must be the containment
// refusal — not ErrSELinuxNotAvailable, which merely reflects the test
// host's LSM state and would let the payload through on an SELinux host.
func TestLoadSELinuxProfile_RefusesHostPath(t *testing.T) {
	evil := filepath.Join(t.TempDir(), "evil.pp")
	if err := os.WriteFile(evil, []byte{0xf1}, 0o644); err != nil {
		t.Fatal(err)
	}
	rec := &mount.RecorderRunner{}
	err := LoadSELinuxProfile(context.Background(), rec, evil)
	if err == nil {
		t.Fatalf("accepted arbitrary host path %q", evil)
	}
	if errors.Is(err, ErrSELinuxNotAvailable) {
		t.Fatalf("refusal must be the name-containment check, not host LSM availability; got %v", err)
	}
	for _, inv := range rec.Invocations {
		if inv.Name == "semodule" {
			t.Fatalf("semodule invoked with %v despite refusal", inv.Args)
		}
	}
}

// A ../ traversal spelling must be refused for the same reason.
func TestLoadAppArmorProfile_RefusesTraversal(t *testing.T) {
	rec := &mount.RecorderRunner{}
	for _, payload := range []string{"../../etc/passwd", "a/../../b", "./x", "sub/prof"} {
		if err := LoadAppArmorProfile(context.Background(), rec, payload); err == nil {
			t.Errorf("accepted traversal/path spelling %q", payload)
		} else if errors.Is(err, ErrAppArmorNotAvailable) {
			t.Errorf("%q: refusal must come from name validation, not LSM availability", payload)
		}
	}
	if len(rec.Invocations) != 0 {
		t.Errorf("no loader may run for refused names; got %+v", rec.Invocations)
	}
}

// Fail-CLOSED existence guard, isolated. A GRAMMAR-VALID name that does not
// exist in the agent-owned directory must be refused — the module asked for
// confinement and must not silently get none. This pins the EvalSymlinks/stat
// mechanism specifically: the name passes profileNamePattern, so ONLY the
// existence check stands between it and the loader.
func TestLoadAppArmorProfile_FailsClosedWhenAbsent(t *testing.T) {
	dir := t.TempDir()
	orig := AppArmorProfileDir
	AppArmorProfileDir = dir
	t.Cleanup(func() { AppArmorProfileDir = orig })

	rec := &mount.RecorderRunner{}
	// "app-profile" is a valid bare name but nothing exists at dir/app-profile.
	if err := LoadAppArmorProfile(context.Background(), rec, "app-profile"); err == nil {
		t.Fatal("absent profile accepted — must fail closed")
	} else if errors.Is(err, ErrAppArmorNotAvailable) {
		t.Fatalf("must fail as not-found, not LSM-availability; got %v", err)
	}
	for _, inv := range rec.Invocations {
		if inv.Name == "apparmor_parser" {
			t.Fatalf("loader ran for an absent profile: %v", inv.Args)
		}
	}
	// A profile that DOES exist in the agent-owned dir resolves and loads
	// (over-rejection guard — the containment must not strand a real profile).
	//
	// LoadAppArmorProfile consults apparmorAvailable() AFTER resolution, so
	// this arm needs the LSM present to reach the loader at all. Pinning it
	// true makes the assertion measure the CONTAINMENT decision on every host
	// instead of the host's LSM state: unpinned it passed on a dev box and
	// failed in CI with "present agent-owned profile rejected", which
	// described neither the code nor the cause. Skipping when AppArmor is
	// absent would be worse — the over-rejection guard would then never run
	// in CI, silently, which is the failure this test exists to catch.
	stubApparmorAvailable(t, true)

	if err := os.WriteFile(filepath.Join(dir, "app-profile"), []byte("profile app {}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	rec2 := &mount.RecorderRunner{}
	if err := LoadAppArmorProfile(context.Background(), rec2, "app-profile"); err != nil {
		t.Fatalf("present agent-owned profile rejected: %v", err)
	}
	var loaded bool
	for _, inv := range rec2.Invocations {
		if inv.Name == "apparmor_parser" {
			loaded = true
			if inv.Args[len(inv.Args)-1] != filepath.Join(dir, "app-profile") {
				t.Errorf("loaded wrong path: %v", inv.Args)
			}
		}
	}
	if !loaded {
		t.Error("expected apparmor_parser to run for a present agent-owned profile")
	}
}

// Symlink-escape guard, isolated. A symlink planted INSIDE the agent-owned
// directory that points OUTSIDE it must be refused — this pins the final
// EvalSymlinks + prefix-recheck, the mechanism that grammar and the plain
// join-prefix check cannot provide (they see an in-dir name).
func TestLoadAppArmorProfile_RefusesSymlinkEscape(t *testing.T) {
	dir := t.TempDir()
	outside := filepath.Join(t.TempDir(), "host-secret")
	if err := os.WriteFile(outside, []byte("evil\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(dir, "escape")); err != nil {
		t.Fatal(err)
	}
	orig := AppArmorProfileDir
	AppArmorProfileDir = dir
	t.Cleanup(func() { AppArmorProfileDir = orig })

	rec := &mount.RecorderRunner{}
	if err := LoadAppArmorProfile(context.Background(), rec, "escape"); err == nil {
		t.Fatal("symlink escaping the agent-owned dir was accepted")
	}
	for _, inv := range rec.Invocations {
		if inv.Name == "apparmor_parser" {
			t.Fatalf("loader ran for a symlink escape: %v", inv.Args)
		}
	}
}

// stubApparmorAvailable pins the host-LSM probe for one test, restoring it on
// cleanup. Only the over-rejection arm needs it: every REFUSAL assertion here
// is deliberately host-independent, because containment runs before the
// availability check and those tests assert the error is NOT
// ErrAppArmorNotAvailable.
func stubApparmorAvailable(t *testing.T, present bool) {
	t.Helper()
	orig := apparmorAvailable
	apparmorAvailable = func() bool { return present }
	t.Cleanup(func() { apparmorAvailable = orig })
}

// The availability gate itself must stay real. Without this, the seam added
// for the over-rejection arm could be left stubbed, or the gate deleted
// outright, and nothing in the suite would object — a profile would then be
// handed to apparmor_parser on a host with no AppArmor at all.
func TestLoadAppArmorProfile_RefusesWhenLSMAbsent(t *testing.T) {
	dir := t.TempDir()
	orig := AppArmorProfileDir
	AppArmorProfileDir = dir
	t.Cleanup(func() { AppArmorProfileDir = orig })

	if err := os.WriteFile(filepath.Join(dir, "app-profile"), []byte("profile app {}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	stubApparmorAvailable(t, false)

	rec := &mount.RecorderRunner{}
	err := LoadAppArmorProfile(context.Background(), rec, "app-profile")
	if !errors.Is(err, ErrAppArmorNotAvailable) {
		t.Fatalf("a present, contained profile on a host with no AppArmor must report "+
			"ErrAppArmorNotAvailable; got %v", err)
	}
	for _, inv := range rec.Invocations {
		if inv.Name == "apparmor_parser" {
			t.Fatalf("loader ran with no AppArmor on the host: %v", inv.Args)
		}
	}
}
