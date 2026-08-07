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

func TestSoftRecomposePreflight_PassesOnHealthyPivotNode(t *testing.T) {
	pinRootMode(t, lifecycle.RootModeNative)
	pinPendingSlot(t, "")
	if err := SoftRecomposePreflight(context.Background(), stubVersionRunner("systemd 256 (256.5)\n")); err != nil {
		t.Errorf("healthy pivot node must pass preflight, got %v", err)
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
