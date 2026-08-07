package runtime

import (
	"context"
	"strings"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/lifecycle"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

func stubVersionRunner(out string) *mount.RecorderRunner {
	return &mount.RecorderRunner{
		StubOutput: map[string][]byte{"systemctl --version": []byte(out)},
	}
}

func pinRootMode(t *testing.T, mode lifecycle.RootMode) {
	t.Helper()
	orig := pivotAwareRootMode
	pivotAwareRootMode = func() lifecycle.RootMode { return mode }
	t.Cleanup(func() { pivotAwareRootMode = orig })
}

func pinPendingSlot(t *testing.T, pending string) {
	t.Helper()
	orig := pendingBootSlot
	pendingBootSlot = func() string { return pending }
	t.Cleanup(func() { pendingBootSlot = orig })
}

func TestSystemdVersion_ParsesNobleOutput(t *testing.T) {
	run := stubVersionRunner("systemd 255 (255.4-1ubuntu8.4)\n+PAM +AUDIT +SELINUX ...\n")
	v, err := SystemdVersion(context.Background(), run)
	if err != nil {
		t.Fatalf("SystemdVersion: %v", err)
	}
	if v != 255 {
		t.Errorf("version = %d, want 255", v)
	}
}

func TestSystemdVersion_RejectsGarbage(t *testing.T) {
	run := stubVersionRunner("sysvinit 2.96\n")
	if _, err := SystemdVersion(context.Background(), run); err == nil {
		t.Error("non-systemd output must error, not misparse")
	}
}

func TestSoftRecomposePreflight_RefusesNonPivotNode(t *testing.T) {
	pinRootMode(t, lifecycle.RootModeChroot)
	pinPendingSlot(t, "")
	err := SoftRecomposePreflight(context.Background(), stubVersionRunner("systemd 255 (x)\n"))
	if err == nil || !strings.Contains(err.Error(), "pivot-booted") {
		t.Errorf("want a pivot-only refusal, got %v", err)
	}
}

func TestSoftRecomposePreflight_RefusesOldSystemd(t *testing.T) {
	pinRootMode(t, lifecycle.RootModeNative)
	pinPendingSlot(t, "")
	err := SoftRecomposePreflight(context.Background(), stubVersionRunner("systemd 249 (249.11)\n"))
	if err == nil || !strings.Contains(err.Error(), "soft-reboot") {
		t.Errorf("want an old-systemd refusal, got %v", err)
	}
}

// The A/B interplay guard: with an unproven slot upgrade armed, a
// soft-reboot would neither boot the pending slot nor exercise
// bless-or-rollback — the preflight must refuse (memory: "A/B Pending
// needs a boot identity").
func TestSoftRecomposePreflight_RefusesWhileSlotUpgradeArmed(t *testing.T) {
	pinRootMode(t, lifecycle.RootModeNative)
	pinPendingSlot(t, "B")
	err := SoftRecomposePreflight(context.Background(), stubVersionRunner("systemd 255 (x)\n"))
	if err == nil || !strings.Contains(err.Error(), "armed") {
		t.Errorf("want an armed-upgrade refusal, got %v", err)
	}
}

// NextrootLayout must never share scratch (upper/work) with the live
// layout — two overlays over one upperdir/workdir is undefined kernel
// behavior — while SHARING the module mounts and blob cache.
func TestNextrootLayout_OwnScratchSharedModules(t *testing.T) {
	live := mount.DefaultLayout()
	next := mount.NextrootLayout("gen1")

	if next.SysRoot != "/run/nextroot" {
		t.Errorf("SysRoot = %s, want /run/nextroot (where systemd-soft-reboot looks)", next.SysRoot)
	}
	for _, pair := range [][2]string{
		{next.ScratchRoot, live.ScratchRoot},
		{next.UpperDir, live.UpperDir},
		{next.WorkDir, live.WorkDir},
	} {
		if pair[0] == pair[1] {
			t.Errorf("nextroot layout shares %q with the live layout — undefined overlay behavior", pair[0])
		}
	}
	if next.ModulesMountRoot != live.ModulesMountRoot || next.ModulesCacheRoot != live.ModulesCacheRoot {
		t.Error("module mounts + cache must be shared — erofs lowers are read-only and safe to share")
	}
	if mount.NextrootLayout("gen1").ScratchRoot == mount.NextrootLayout("gen2").ScratchRoot {
		t.Error("distinct generations must get distinct scratch roots")
	}
}

// The mount-survival guard. systemd tears down every mount except /run
// unless its unit opts out, and a stock fleet node's persist.mount does
// NOT (verified live 2026-08-07: DefaultDependencies=yes,
// Conflicts=umount.target) — soft-rebooting into a root without /persist
// loses the enrolled PKI and durable /var, which on a self-hosted control
// plane is unrecoverable.
func softRebootRunner(persistProps string) *mount.RecorderRunner {
	return &mount.RecorderRunner{StubOutput: map[string][]byte{
		"systemctl --version": []byte("systemd 255 (255.4)\n"),
		"systemctl show persist.mount -p DefaultDependencies -p Conflicts -p LoadState": []byte(persistProps),
	}}
}

func TestSoftRecomposePreflight_RefusesWhenPersistWouldBeUnmounted(t *testing.T) {
	pinRootMode(t, lifecycle.RootModeNative)
	pinPendingSlot(t, "")
	// Exactly what a live fleet node reports today.
	run := softRebootRunner("DefaultDependencies=yes\nConflicts=umount.target\nLoadState=loaded\n")
	err := SoftRecomposePreflight(context.Background(), run)
	if err == nil || !strings.Contains(err.Error(), "/persist") {
		t.Fatalf("want a /persist survival refusal, got %v", err)
	}
}

func TestSoftRecomposePreflight_RefusesOnEitherHalfOfTheGuard(t *testing.T) {
	pinRootMode(t, lifecycle.RootModeNative)
	pinPendingSlot(t, "")
	// Each clause must independently refuse — a compound guard where only
	// one half is exercised is how a broken guard ships.
	for name, props := range map[string]string{
		"conflicts only":   "DefaultDependencies=no\nConflicts=umount.target\nLoadState=loaded\n",
		"deps only":        "DefaultDependencies=yes\nConflicts=\nLoadState=loaded\n",
		"unit unknown":     "LoadState=not-found\n",
		"no output at all": "",
	} {
		if err := SoftRecomposePreflight(context.Background(), softRebootRunner(props)); err == nil {
			t.Errorf("%s: must refuse, got nil", name)
		}
	}
}

func TestSoftRecomposePreflight_PassesWhenPersistIsConfiguredToSurvive(t *testing.T) {
	pinRootMode(t, lifecycle.RootModeNative)
	pinPendingSlot(t, "")
	run := softRebootRunner("DefaultDependencies=no\nConflicts=\nLoadState=loaded\n")
	if err := SoftRecomposePreflight(context.Background(), run); err != nil {
		t.Errorf("a persist.mount configured to survive must pass, got %v", err)
	}
}

func TestMountUnitName(t *testing.T) {
	cases := map[string]string{
		"/persist":       "persist.mount",
		"/":              "-.mount",
		"/var/lib/thing": "var-lib-thing.mount",
		"/my-dir":        `my\x2ddir.mount`,
	}
	for path, want := range cases {
		if got := MountUnitName(path); got != want {
			t.Errorf("MountUnitName(%q) = %q, want %q", path, got, want)
		}
	}
}
