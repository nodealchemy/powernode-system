package bootupgrade

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/bootslots"
	"github.com/nodealchemy/powernode-system/agent/internal/espwrite"
)

// blessEnv is confirmEnvWithEntry plus a REAL (temp) ESP, so the bless can be
// asserted from the filesystem rather than from the commands attempted. The
// distinction matters: the whole defect below is that a slot's counter-suffixed
// file was never renamed, and only the directory shows that.
//
// Returns a recording runner and the ESP's EFI/Linux directory.
func blessEnv(t *testing.T, st bootslots.State, bootedEntry string, espEntries ...string) (*recRunner, string) {
	t.Helper()
	confirmEnvWithEntry(t, st, bootedEntry)

	esp := t.TempDir()
	linux := filepath.Join(esp, "EFI", "Linux")
	if err := os.MkdirAll(linux, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, e := range espEntries {
		if err := os.WriteFile(filepath.Join(linux, e), []byte("uki"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.MkdirAll(filepath.Join(esp, "loader"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(esp, "loader", "loader.conf"),
		[]byte("timeout 3\ndefault powernode-a.efi\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(espwrite.SetESPMountForTest(esp))
	return &recRunner{}, linux
}

func loaderDefault(t *testing.T, linuxDir string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(filepath.Dir(filepath.Dir(linuxDir)), "loader", "loader.conf"))
	if err != nil {
		t.Fatal(err)
	}
	for _, ln := range strings.Split(string(b), "\n") {
		if f := strings.Fields(ln); len(f) == 2 && f[0] == "default" {
			return f[1]
		}
	}
	return ""
}

// THE regression, observed on ops-hub 2026-07-28 and blessed by hand.
//
// An earlier confirm saw a fallback and cleared Pending, but the UKI stayed on
// the ESP with boot tries remaining. A LATER boot landed on that slot and was
// healthy — and ConfirmBoot returned immediately, because its cheap pre-check
// only looks at Pending. The node ran the new image and would have silently
// reverted on the next reboot, since the slot was never blessed.
func TestConfirmBoot_BlessesHealthySlotAfterPendingWasCleared(t *testing.T) {
	r, linux := blessEnv(t,
		bootslots.State{Active: "a", LastTargetSHA: "deadbeef"},
		"powernode-b+1-2.efi",
		"powernode-a.efi", "powernode-b+1-2.efi")

	if err := ConfirmBoot(context.Background(), r, "deadbeef"); err != nil {
		t.Fatalf("ConfirmBoot: %v", err)
	}

	if _, err := os.Stat(filepath.Join(linux, "powernode-b.efi")); err != nil {
		t.Fatalf("slot b was never blessed — the node reverts on the next reboot: %v", err)
	}
	if !r.ran("set-default powernode-b.efi") {
		t.Fatalf("blessed but never promoted in NVRAM: %v", r.calls)
	}
	if got := loaderDefault(t, linux); got != "powernode-b.efi" {
		t.Errorf("loader.conf still names %q — losing the varstore silently reverts the node", got)
	}
	if got := bootslots.Load(); got.Active != "b" || got.LastTargetSHA != "" {
		t.Fatalf("state not reconciled after blessing: %+v", got)
	}
	// Slot A must survive as the rollback target.
	if _, err := os.Stat(filepath.Join(linux, "powernode-a.efi")); err != nil {
		t.Fatalf("the rollback target was removed: %v", err)
	}
}

// The gate that keeps this narrow. An operator one-shot TEST boot has no
// LastTargetSHA; blessing it would make a deliberate trial permanent and defeat
// try-once-then-revert — the property the boot counter exists to provide.
func TestConfirmBoot_DoesNotBlessASlotWeNeverTargeted(t *testing.T) {
	r, linux := blessEnv(t,
		bootslots.State{Active: "a"}, // no LastTargetSHA
		"powernode-b+1-2.efi",
		"powernode-a.efi", "powernode-b+1-2.efi")

	if err := ConfirmBoot(context.Background(), r, "deadbeef"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(linux, "powernode-b.efi")); err == nil {
		t.Fatal("blessed a slot that was never an upgrade target — a one-shot trial just became permanent")
	}
	if r.ran("set-default") {
		t.Fatalf("promoted an untargeted slot: %v", r.calls)
	}
	if got := bootslots.Load(); got.Active != "a" {
		t.Fatalf("Active advanced onto an untargeted slot: %+v", got)
	}
}

// Running a DIFFERENT image than the one we were installing proves nothing about
// the target, so it must not bless. This is the reconciliation twin of the
// Pending path's sha-mismatch refusal.
func TestConfirmBoot_ReconcileDoesNotBlessOnShaMismatch(t *testing.T) {
	r, linux := blessEnv(t,
		bootslots.State{Active: "a", LastTargetSHA: "deadbeef"},
		"powernode-b+1-2.efi",
		"powernode-a.efi", "powernode-b+1-2.efi")

	if err := ConfirmBoot(context.Background(), r, "cafebabe"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(linux, "powernode-b.efi")); err == nil {
		t.Fatal("blessed while running a sha that is not the recorded target")
	}
	if r.ran("set-default") {
		t.Fatalf("promoted on a sha mismatch: %v", r.calls)
	}
}

// An empty booted sha is the "cannot tell" case, and matches nothing — including
// an empty LastTargetSHA, which the first guard already excludes.
func TestConfirmBoot_ReconcileIgnoresUnknownBootedSHA(t *testing.T) {
	r, linux := blessEnv(t,
		bootslots.State{Active: "a", LastTargetSHA: "deadbeef"},
		"powernode-b+1-2.efi",
		"powernode-a.efi", "powernode-b+1-2.efi")

	if err := ConfirmBoot(context.Background(), r, ""); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(linux, "powernode-b.efi")); err == nil {
		t.Fatal("blessed without being able to identify the running image")
	}
}

// Steady state, which runs on every healthy heartbeat of every node that ever
// upgraded: already on the active slot. Must not touch the ESP at all.
func TestConfirmBoot_ReconcileIsANoOpOnTheActiveSlot(t *testing.T) {
	r, _ := blessEnv(t,
		bootslots.State{Active: "b", LastTargetSHA: "deadbeef"},
		"powernode-b.efi",
		"powernode-a.efi", "powernode-b.efi")

	if err := ConfirmBoot(context.Background(), r, "deadbeef"); err != nil {
		t.Fatal(err)
	}
	if len(r.calls) != 0 {
		t.Fatalf("touched the ESP in steady state: %v", r.calls)
	}
}

// systemd-boot did not say which entry it selected, so the running slot is
// unknown. Guessing here would promote the wrong slot.
func TestConfirmBoot_ReconcileIgnoresUndeterminableSlot(t *testing.T) {
	r, linux := blessEnv(t,
		bootslots.State{Active: "a", LastTargetSHA: "deadbeef"},
		"", // no LoaderEntrySelected
		"powernode-a.efi", "powernode-b+1-2.efi")

	if err := ConfirmBoot(context.Background(), r, "deadbeef"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(linux, "powernode-b.efi")); err == nil {
		t.Fatal("blessed a slot without knowing which one booted")
	}
}

// Already blessed, state file merely stale: catch the state up and do NOT
// re-promote. Re-running set-default every heartbeat for the rest of the boot is
// the exact per-tick churn the Pending path is careful to avoid.
func TestConfirmBoot_AlreadyBlessedOnlyReconcilesState(t *testing.T) {
	r, _ := blessEnv(t,
		bootslots.State{Active: "a", LastTargetSHA: "deadbeef"},
		"powernode-b.efi",
		"powernode-a.efi", "powernode-b.efi")

	if err := ConfirmBoot(context.Background(), r, "deadbeef"); err != nil {
		t.Fatal(err)
	}
	if got := bootslots.Load(); got.Active != "b" || got.LastTargetSHA != "" {
		t.Fatalf("state did not catch up to the blessed slot: %+v", got)
	}
	if r.ran("set-default") {
		t.Fatalf("re-promoted an already-blessed slot: %v", r.calls)
	}
}

// The property the whole fix rests on: LastTargetSHA must OUTLIVE Pending.
// Every branch that clears Pending — here, the routine fallback — has to leave
// LastTargetSHA behind, or a later healthy boot has nothing to reconcile from
// and the defect returns.
func TestConfirmBoot_LastTargetSHASurvivesTheFallbackClear(t *testing.T) {
	spy := confirmEnvWithEntry(t,
		bootslots.State{Active: "a", Pending: "b", PendingSHA: "deadbeef", LastTargetSHA: "deadbeef"},
		"powernode-a.efi") // sd-boot fell back to A

	if err := ConfirmBoot(context.Background(), spy, "old-sha"); err != nil {
		t.Fatalf("a fallback is routine, not an error: %v", err)
	}
	st := bootslots.Load()
	if st.Pending != "" {
		t.Fatalf("Pending must clear on a proven fallback, got %+v", st)
	}
	if st.LastTargetSHA != "deadbeef" {
		t.Fatalf("LastTargetSHA was discarded with Pending — a later healthy boot onto slot b "+
			"could never be blessed, which is the defect this exists to prevent; got %+v", st)
	}
}

// The pre-check that decides to reconcile runs UNLOCKED, so its snapshot can be
// stale by the time the lock is held. An Apply that won the race has already
// cleared this slot's family, written a brand-new UKI into it, and recorded a new
// target — blessing on the stale snapshot would strip the boot counter from an
// image that has never booted.
//
// Driven directly rather than through ConfirmBoot: the whole point is a snapshot
// that disagrees with what is on disk, which ConfirmBoot's own Load cannot produce.
func TestReconcile_RereadsStateUnderTheLock(t *testing.T) {
	// On disk: an upgrade Apply started while we were deciding.
	r, linux := blessEnv(t,
		bootslots.State{Active: "a", Pending: "b", PendingSHA: "newsha", LastTargetSHA: "newsha"},
		"powernode-b+1-2.efi",
		"powernode-a.efi", "powernode-b+1-2.efi")

	// In hand: the snapshot taken before Apply ran.
	stale := bootslots.State{Active: "a", LastTargetSHA: "deadbeef"}
	if err := reconcileUnblessedBootedSlot(context.Background(), r, "deadbeef", stale); err != nil {
		t.Fatal(err)
	}

	if _, err := os.Stat(filepath.Join(linux, "powernode-b.efi")); err == nil {
		t.Fatal("blessed a slot an in-flight upgrade had just overwritten — that UKI has never booted")
	}
	if r.ran("set-default") {
		t.Fatalf("promoted a never-booted image: %v", r.calls)
	}
	if st := bootslots.Load(); st.Pending != "b" {
		t.Fatalf("clobbered the in-flight upgrade's state: %+v", st)
	}
}

// ...and Apply is what records it in the first place.
func TestApply_RecordsLastTargetSHA(t *testing.T) {
	o, d, _ := stagedOpts(t)
	var recorded bootslots.State
	defer withApplyDeps(func(dep *applyDepSet) {
		happyDeps(dep)
		dep.updateState = func(fn func(*bootslots.State) error) error {
			return fn(&recorded)
		}
	})()

	if _, err := Apply(context.Background(), *d, o); err != nil {
		t.Fatalf("Apply: %v", err)
	}
	if recorded.LastTargetSHA != o.TargetGitSHA {
		t.Fatalf("Apply did not record the target sha for later reconciliation: %+v", recorded)
	}
}

// The boot-identity guard in ResolveFallback/ConfirmBoot is only worth anything
// if Apply actually stamps the field. Without this assertion the whole guard
// degrades silently to its legacy branch — PendingBootID stays "", every record
// reads as unprovable, and the protection is inert while all its own tests still
// pass. That is precisely the shape of dead-code fix this package has shipped
// before, so the stamp gets its own test rather than being assumed.
func TestApply_StampsTheArmingBootID(t *testing.T) {
	p := filepath.Join(t.TempDir(), "boot_id")
	if err := os.WriteFile(p, []byte("33333333-3333-3333-3333-333333333333\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	defer bootslots.SetBootIDPathForTest(p)()

	o, d, _ := stagedOpts(t)
	var recorded bootslots.State
	defer withApplyDeps(func(dep *applyDepSet) {
		happyDeps(dep)
		dep.updateState = func(fn func(*bootslots.State) error) error { return fn(&recorded) }
	})()

	if _, err := Apply(context.Background(), *d, o); err != nil {
		t.Fatalf("Apply: %v", err)
	}
	if recorded.PendingBootID != "33333333-3333-3333-3333-333333333333" {
		t.Fatalf("Apply did not stamp the arming boot id (%+v) — an agent restart before the "+
			"reboot would then read this armed upgrade as a rollback and erase it", recorded)
	}
}
