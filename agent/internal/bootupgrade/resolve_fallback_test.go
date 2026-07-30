package bootupgrade

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/bootslots"
)

// The headline behaviour: a provable rollback resolves with NO health input at
// all. Before the split this verdict sat behind N consecutive healthy probes,
// which inverted the logic — a node that fell back is the one least able to
// look healthy, so the cleanup could never reach the case it exists for.
func TestResolveFallback_ClearsAProvableRollbackWithoutAnyHealthGate(t *testing.T) {
	// Pending is slot b; systemd-boot says we actually booted a; and the attempt
	// was armed by an EARLIER boot, which is what makes this a rollback rather
	// than an upgrade that has not been tried yet. Slot letters alone describe
	// both situations identically — see DoesNotClearAnUpgradeArmedThisBoot.
	seedBootID(t, "22222222-2222-2222-2222-222222222222")
	spy := confirmEnvWithEntry(t, bootslots.State{
		Active:        "a",
		Pending:       "b",
		PendingSHA:    "1111111111111111111111111111111111111111",
		PendingBootID: "11111111-1111-1111-1111-111111111111",
	}, "powernode-a.efi")

	cleared, err := ResolveFallback("2222222222222222222222222222222222222222")
	if err != nil {
		t.Fatalf("ResolveFallback: %v", err)
	}
	if !cleared {
		t.Fatal("did not clear a PROVABLE rollback — the attempt stays Pending for the rest of the " +
			"boot and every later Apply has to reason around a record for a dead upgrade")
	}
	st := bootslots.Load()
	if st.Pending != "" || st.PendingSHA != "" {
		t.Errorf("Pending=%q PendingSHA=%q, want both cleared", st.Pending, st.PendingSHA)
	}
	// Blessing is the half of the verdict that genuinely needs proof of health.
	// This path must never do it, and must never touch the ESP at all.
	if spy.touchedESP() {
		t.Errorf("touched the ESP while resolving a rollback: %v", spy.cmds)
	}
	if st.Active != "a" {
		t.Errorf("Active = %q, want a — a rollback promotes nothing", st.Active)
	}
}

// Running the slot we were installing is NOT a rollback. Clearing here would
// throw away the record of an upgrade that is still owed a bless, and the
// healthy new image would silently revert on its next reboot.
func TestResolveFallback_DoesNotClearWhenRunningThePendingSlot(t *testing.T) {
	confirmEnvWithEntry(t, bootslots.State{
		Active:     "a",
		Pending:    "b",
		PendingSHA: "1111111111111111111111111111111111111111",
	}, "powernode-b+2-1.efi")

	cleared, err := ResolveFallback("1111111111111111111111111111111111111111")
	if err != nil {
		t.Fatalf("ResolveFallback: %v", err)
	}
	if cleared {
		t.Fatal("cleared the attempt while RUNNING the pending slot — that is the success case, " +
			"and discarding it loses the bless the node is still owed")
	}
	if got := bootslots.Load().Pending; got != "b" {
		t.Errorf("Pending = %q, want b", got)
	}
}

// Unprovable must mean untouched. With no LoaderEntrySelected there is no
// evidence either way, and this path's entire licence to run ungated is that it
// acts only on evidence — guessing here would clear live upgrades on any node
// whose firmware does not publish the variable.
func TestResolveFallback_NoOpWhenTheBootedSlotIsUndeterminable(t *testing.T) {
	confirmEnv(t, bootslots.State{ // no entry → no LoaderEntrySelected
		Active:     "a",
		Pending:    "b",
		PendingSHA: "1111111111111111111111111111111111111111",
	})

	cleared, err := ResolveFallback("1111111111111111111111111111111111111111")
	if err != nil {
		t.Fatalf("ResolveFallback: %v", err)
	}
	if cleared {
		t.Fatal("cleared an attempt with NO evidence of which slot booted")
	}
	if got := bootslots.Load().Pending; got != "b" {
		t.Errorf("Pending = %q, want b left untouched", got)
	}
}

// The overwhelmingly common case must cost nothing.
func TestResolveFallback_NoOpWithNoUpgradeInFlight(t *testing.T) {
	spy := confirmEnvWithEntry(t, bootslots.State{Active: "a"}, "powernode-a.efi")

	cleared, err := ResolveFallback("1111111111111111111111111111111111111111")
	if err != nil {
		t.Fatalf("ResolveFallback: %v", err)
	}
	if cleared || spy.touchedESP() {
		t.Errorf("did work with no upgrade in flight (cleared=%v, esp=%v)", cleared, spy.cmds)
	}
}

// A node that did not boot via systemd-boot cannot have "fallen back" in the
// sd-boot sense, and BootedSlot is meaningless there. Leave the verdict — and
// its specific, actionable error message — to the gated ConfirmBoot path.
func TestResolveFallback_NoOpWithoutSystemdBoot(t *testing.T) {
	confirmEnvWithEntry(t, bootslots.State{
		Active:     "a",
		Pending:    "b",
		PendingSHA: "1111111111111111111111111111111111111111",
	}, "powernode-a.efi")
	// Drop LoaderInfo → BootedViaSystemdBoot() is false.
	defer bootslots.SetEfivarsDirForTest(t.TempDir())()

	cleared, err := ResolveFallback("1111111111111111111111111111111111111111")
	if err != nil {
		t.Fatalf("ResolveFallback: %v", err)
	}
	if cleared {
		t.Fatal("cleared an attempt on a node that never went through systemd-boot")
	}
}

// seedBootID points bootslots at a fake boot_id file and returns its value.
func seedBootID(t *testing.T, id string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "boot_id")
	if err := os.WriteFile(p, []byte(id+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(bootslots.SetBootIDPathForTest(p))
	return id
}

// THE case that makes "we are running a slot other than Pending" insufficient
// on its own. Apply arms slot b and the node has NOT rebooted yet, so it is
// still running a — state indistinguishable from a rollback by slot letters.
//
// upgrade_boot_image.go does Apply → markAttempted → reboot, and that window
// stays open indefinitely whenever the reboot call fails. Restarting the agent
// is standing practice on this fleet (the build-once mTLS client), so a fresh
// BootConfirmer.Run in that window would clear a live upgrade's record within
// milliseconds and strand its armed UKI on the ESP.
func TestResolveFallback_DoesNotClearAnUpgradeArmedThisBoot(t *testing.T) {
	id := seedBootID(t, "11111111-1111-1111-1111-111111111111")
	confirmEnvWithEntry(t, bootslots.State{
		Active:        "a",
		Pending:       "b",
		PendingSHA:    "1111111111111111111111111111111111111111",
		LastTargetSHA: "1111111111111111111111111111111111111111",
		PendingBootID: id, // armed by the boot we are still running
	}, "powernode-a.efi")

	cleared, err := ResolveFallback("2222222222222222222222222222222222222222")
	if err != nil {
		t.Fatalf("ResolveFallback: %v", err)
	}
	if cleared {
		t.Fatal("erased an upgrade armed by THIS boot — the trial has not run, so there is no " +
			"rollback to record; its UKI is now on the ESP armed and unremembered")
	}
	if got := bootslots.Load().Pending; got != "b" {
		t.Errorf("Pending = %q, want b preserved", got)
	}
}

// ConfirmBoot must reach the same conclusion, or the ungated fix merely delays
// the erasure by the length of the health gate instead of preventing it.
func TestConfirmBoot_DoesNotClearAnUpgradeArmedThisBoot(t *testing.T) {
	id := seedBootID(t, "11111111-1111-1111-1111-111111111111")
	spy := confirmEnvWithEntry(t, bootslots.State{
		Active:        "a",
		Pending:       "b",
		PendingSHA:    "1111111111111111111111111111111111111111",
		PendingBootID: id,
	}, "powernode-a.efi")

	if err := ConfirmBoot(context.Background(), spy, "2222222222222222222222222222222222222222"); err != nil {
		t.Fatalf("ConfirmBoot: %v", err)
	}
	if got := bootslots.Load().Pending; got != "b" {
		t.Errorf("Pending = %q, want b — the health gate only delays this erasure, it cannot stop it", got)
	}
	if spy.touchedESP() {
		t.Errorf("touched the ESP for an upgrade that has not been tried: %v", spy.cmds)
	}
}

// State written before PendingBootID existed is UNPROVABLE here. The ungated
// path must decline it rather than guess, leaving the verdict to ConfirmBoot
// exactly as before — an agent upgrade must not change what happens to an
// upgrade that was already in flight.
func TestResolveFallback_DeclinesLegacyStateWithNoBootID(t *testing.T) {
	seedBootID(t, "22222222-2222-2222-2222-222222222222")
	confirmEnvWithEntry(t, bootslots.State{
		Active:     "a",
		Pending:    "b",
		PendingSHA: "1111111111111111111111111111111111111111",
		// PendingBootID deliberately absent
	}, "powernode-a.efi")

	cleared, err := ResolveFallback("2222222222222222222222222222222222222222")
	if err != nil {
		t.Fatalf("ResolveFallback: %v", err)
	}
	if cleared {
		t.Fatal("acted on a record with no boot identity — unprovable must mean untouched")
	}
}

// An unreadable boot_id is also unprovable, and must fail closed the same way.
func TestResolveFallback_DeclinesWhenTheBootIDCannotBeRead(t *testing.T) {
	t.Cleanup(bootslots.SetBootIDPathForTest(filepath.Join(t.TempDir(), "absent")))
	confirmEnvWithEntry(t, bootslots.State{
		Active:        "a",
		Pending:       "b",
		PendingSHA:    "1111111111111111111111111111111111111111",
		PendingBootID: "11111111-1111-1111-1111-111111111111",
	}, "powernode-a.efi")

	cleared, err := ResolveFallback("2222222222222222222222222222222222222222")
	if err != nil {
		t.Fatalf("ResolveFallback: %v", err)
	}
	if cleared {
		t.Fatal("acted while the current boot identity was unknown — CurrentBootID() returning \"\" " +
			"must never be treated as 'a different boot'")
	}
}

// Finding A: the guard in ConfirmBoot must decline on an UNREADABLE boot id,
// exactly as ResolveFallback does. Testing only `PendingBootID == cur` fails
// open — the equality is false when cur is "", the guard does not fire, and the
// fallback branch erases a live armed upgrade. Same fail-open shape, same
// mechanism, one function away from where it was already fixed.
func TestConfirmBoot_DeclinesWhenTheBootIDCannotBeRead(t *testing.T) {
	t.Cleanup(bootslots.SetBootIDPathForTest(filepath.Join(t.TempDir(), "absent")))
	spy := confirmEnvWithEntry(t, bootslots.State{
		Active:        "a",
		Pending:       "b",
		PendingSHA:    "1111111111111111111111111111111111111111",
		PendingBootID: "11111111-1111-1111-1111-111111111111",
	}, "powernode-a.efi")

	if err := ConfirmBoot(context.Background(), spy, "2222222222222222222222222222222222222222"); err != nil {
		t.Fatalf("ConfirmBoot: %v", err)
	}
	if got := bootslots.Load().Pending; got != "b" {
		t.Fatalf("Pending = %q — an unreadable boot_id is UNPROVABLE, not 'a different boot'; "+
			"erasing here strands an armed UKI on the ESP with nothing remembering it", got)
	}
}

// Finding B: a fresh record that could not be stamped is NOT a legacy record,
// and must not lose its protection silently.
func TestApply_ReportsWhenTheBootIDCannotBeStamped(t *testing.T) {
	t.Cleanup(bootslots.SetBootIDPathForTest(filepath.Join(t.TempDir(), "absent")))
	warned := false
	prev := reportStampFailure
	reportStampFailure = func() { warned = true }
	t.Cleanup(func() { reportStampFailure = prev })

	o, d, _ := stagedOpts(t)
	var recorded bootslots.State
	defer withApplyDeps(func(dep *applyDepSet) {
		happyDeps(dep)
		dep.updateState = func(fn func(*bootslots.State) error) error { return fn(&recorded) }
	})()

	if _, err := Apply(context.Background(), *d, o); err != nil {
		t.Fatalf("Apply: %v", err)
	}
	if recorded.PendingBootID != "" {
		t.Fatalf("expected an unstamped record, got %q", recorded.PendingBootID)
	}
	if !warned {
		t.Error("armed a slot with an unstamped record and said nothing — that record is " +
			"indistinguishable from a legacy one, so it silently inherits the unprotected path")
	}
}
