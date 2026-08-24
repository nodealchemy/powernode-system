package runtime

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/lifecycle"
	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// WIRING test for review finding F2. TestPrivilegedApproved proves the gate
// PREDICATE; this proves the pivot/compose boot path actually CONSULTS it —
// the predicate-vs-wiring split. renderPivotUnits derives enforcePrivileged
// from bc internally, so setting `enforcePrivileged := false` (reinstating the
// F2 hole) makes TestRenderPivotUnits_FrozenAllowlistRefusesUnapproved fail.
//
// Observable: AttachServicesNative writes a unit file to
// sysroot/etc/systemd/system/<unit> and runs `systemctl --root enable <unit>`.
// A REFUSED module produces neither; an enabled one produces both.

func privModule(id string) (mount.Module, *manifest.Manifest) {
	return mount.Module{ID: id, Priority: 1}, &manifest.Manifest{
		ID:       id,
		Name:     id,
		Services: []manifest.Service{{Name: "app", StartCommand: "/bin/true"}},
		Config:   map[string]any{"security": map[string]any{"privileged": true}},
	}
}

func plainModule(id string) (mount.Module, *manifest.Manifest) {
	return mount.Module{ID: id, Priority: 1}, &manifest.Manifest{
		ID:       id,
		Name:     id,
		Services: []manifest.Service{{Name: "app", StartCommand: "/bin/true"}},
	}
}

func unitEnabled(t *testing.T, sysroot string, rec *mount.RecorderRunner, modID string) bool {
	t.Helper()
	unit := lifecycle.UnitName(modID, "app")
	_, statErr := os.Stat(filepath.Join(sysroot, "etc", "systemd", "system", unit))
	fileWritten := statErr == nil
	enableRan := false
	for _, inv := range rec.Invocations {
		if inv.Name != "systemctl" {
			continue
		}
		for _, a := range inv.Args {
			if a == unit {
				enableRan = true
			}
		}
	}
	// The two observables must agree; a split would mean a half-applied unit.
	if fileWritten != enableRan {
		t.Fatalf("module %s: unit file written=%v but enable ran=%v (inconsistent)", modID, fileWritten, enableRan)
	}
	return fileWritten
}

func newPivotReconciler(rec *mount.RecorderRunner) *Reconciler {
	return &Reconciler{cfg: ReconcilerConfig{
		MountRunner: rec,
		OnError:     func(string, error) {},
	}}
}

// FROZEN allowlist that does NOT contain the privileged module: the module's
// services MUST NOT be enabled post-pivot. Fails if enforcePrivileged is
// disabled (the F2 regression).
func TestRenderPivotUnits_FrozenAllowlistRefusesUnapproved(t *testing.T) {
	sysroot := t.TempDir()
	rec := &mount.RecorderRunner{}
	r := newPivotReconciler(rec)

	pm, pmf := privModule("priv-unapproved")
	nm, nmf := plainModule("plain")
	stack := mount.ModuleStack{pm, nm}
	manifests := map[string]*manifest.Manifest{pm.ID: pmf, nm.ID: nmf}

	bc := &BootComposedBreadcrumb{
		PrivilegedAllowlistFrozen: true,
		PrivilegedModuleIDs:       []string{"some-other-module"}, // NOT the priv module
	}
	r.renderPivotUnits(context.Background(), sysroot, stack, manifests, bc)

	if unitEnabled(t, sysroot, rec, "priv-unapproved") {
		t.Error("F2 REGRESSION: an unapproved privileged module was enabled on the pivot path despite a frozen allowlist")
	}
	if !unitEnabled(t, sysroot, rec, "plain") {
		t.Error("a non-privileged module must still be enabled (over-refusal)")
	}
}

// FROZEN allowlist that DOES contain the privileged module: it is enabled.
func TestRenderPivotUnits_FrozenAllowlistGrantsApproved(t *testing.T) {
	sysroot := t.TempDir()
	rec := &mount.RecorderRunner{}
	r := newPivotReconciler(rec)

	pm, pmf := privModule("priv-approved")
	stack := mount.ModuleStack{pm}
	manifests := map[string]*manifest.Manifest{pm.ID: pmf}

	bc := &BootComposedBreadcrumb{
		PrivilegedAllowlistFrozen: true,
		PrivilegedModuleIDs:       []string{"priv-approved"},
	}
	r.renderPivotUnits(context.Background(), sysroot, stack, manifests, bc)

	if !unitEnabled(t, sysroot, rec, "priv-approved") {
		t.Error("an approved privileged module must be enabled")
	}
}

// PRE-FIELD set (PrivilegedAllowlistFrozen=false): the gate is SKIPPED so an
// upgrade cannot brick a node whose frozen set predates the field. The
// privileged module is enabled even though it is not in any allowlist. This
// pins the conditional (frozen-vs-unfrozen) arm.
func TestRenderPivotUnits_UnfrozenSetSkipsGate(t *testing.T) {
	sysroot := t.TempDir()
	rec := &mount.RecorderRunner{}
	r := newPivotReconciler(rec)

	pm, pmf := privModule("priv-legacy")
	stack := mount.ModuleStack{pm}
	manifests := map[string]*manifest.Manifest{pm.ID: pmf}

	bc := &BootComposedBreadcrumb{
		PrivilegedAllowlistFrozen: false, // old-format set: no allowlist captured
		PrivilegedModuleIDs:       nil,
	}
	r.renderPivotUnits(context.Background(), sysroot, stack, manifests, bc)

	if !unitEnabled(t, sysroot, rec, "priv-legacy") {
		t.Error("upgrade-safety REGRESSION: a pre-field frozen set must SKIP the gate, not refuse the module")
	}
}
