package runtime

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/bootslots"
	"github.com/nodealchemy/powernode-system/agent/internal/espwrite"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// flakyProber returns a scripted sequence of (healthy, err); the last entry
// repeats. The shared scriptedProber cannot express probe ERRORS, which is the
// distinction this file needs: an error is not evidence of health.
type flakyProber struct {
	mu     sync.Mutex
	script []struct {
		healthy bool
		err     error
	}
	calls int
}

func (p *flakyProber) Healthy(_ context.Context) (bool, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	i := p.calls
	p.calls++
	if i >= len(p.script) {
		i = len(p.script) - 1
	}
	return p.script[i].healthy, p.script[i].err
}

type errRecorder struct {
	mu     sync.Mutex
	stages []string
}

func (e *errRecorder) record(stage string, _ error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.stages = append(e.stages, stage)
}

func (e *errRecorder) count(stage string) int {
	e.mu.Lock()
	defer e.mu.Unlock()
	n := 0
	for _, s := range e.stages {
		if s == stage {
			n++
		}
	}
	return n
}

// pendingUpgrade points bootslots at a temp state file with an upgrade in flight.
func pendingUpgrade(t *testing.T) {
	t.Helper()
	restore := bootslots.SetStatePathForTest(filepath.Join(t.TempDir(), "boot-slot.json"))
	t.Cleanup(restore)
	if err := bootslots.Update(func(st *bootslots.State) error {
		st.Active = "a"
		st.Pending = "b"
		st.PendingSHA = "1111111111111111111111111111111111111111"
		return nil
	}); err != nil {
		t.Fatal(err)
	}
}

// INV-4's whole point: an unhealthy node must NOT have its rollback disarmed,
// however reachable the platform is. Under the old heartbeat gate this blessed
// on the first successful heartbeat regardless of whether the image came up.
func TestBootConfirmer_NeverConfirmsWhileUnhealthy(t *testing.T) {
	pendingUpgrade(t)
	prober := &scriptedProber{results: []bool{false}}
	rec := &errRecorder{}

	ctx, cancel := context.WithTimeout(context.Background(), 250*time.Millisecond)
	defer cancel()
	c := &BootConfirmer{
		Prober:       prober,
		PollInterval: 5 * time.Millisecond,
		Runner:       mount.ExecRunner{},
		OnError:      rec.record,
	}
	if err := c.Run(ctx); err != nil {
		t.Fatalf("Run: %v", err)
	}

	if prober.probes() < 3 {
		t.Fatalf("gate gave up probing (%d probes) — it must keep watching", prober.probes())
	}
	if n := rec.count("boot_confirm"); n != 0 {
		t.Errorf("attempted to confirm an UNHEALTHY node (%d boot_confirm errors)", n)
	}
}

// A probe error is not evidence of health, so it must reset the run — "3
// consecutive" has to mean three consecutive PROVEN-healthy probes.
func TestBootConfirmer_ProbeErrorResetsTheConsecutiveRun(t *testing.T) {
	pendingUpgrade(t)
	// healthy, healthy, ERROR, healthy, healthy — never three in a row.
	prober := &flakyProber{script: []struct {
		healthy bool
		err     error
	}{
		{true, nil}, {true, nil}, {false, errors.New("probe failed")}, {true, nil}, {true, nil},
		{false, errors.New("probe failed")},
	}}
	rec := &errRecorder{}

	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Millisecond)
	defer cancel()
	c := &BootConfirmer{
		Prober:       prober,
		PollInterval: 5 * time.Millisecond,
		Runner:       mount.ExecRunner{},
		OnError:      rec.record,
	}
	_ = c.Run(ctx)

	if n := rec.count("boot_confirm"); n != 0 {
		t.Errorf("confirmed despite never reaching 3 consecutive healthy probes (%d attempts)", n)
	}
}

// The common case — nothing in flight — must not probe at all.
func TestBootConfirmer_NoPendingUpgradeDoesNotProbe(t *testing.T) {
	restore := bootslots.SetStatePathForTest(filepath.Join(t.TempDir(), "boot-slot.json"))
	defer restore()

	prober := &scriptedProber{results: []bool{true}}
	c := &BootConfirmer{Prober: prober, PollInterval: time.Millisecond, Runner: mount.ExecRunner{}}
	if err := c.Run(context.Background()); err != nil {
		t.Fatalf("Run: %v", err)
	}
	if prober.probes() != 0 {
		t.Errorf("probed %d times with no upgrade in flight", prober.probes())
	}
}

// The gate that kept the reconciliation path from EVER running.
//
// A boot onto a slot whose earlier attempt fell back arrives with Pending
// already cleared, so a `Pending == ""` test here returns before probing and
// ConfirmBoot is never called — the bless logic downstream is unreachable dead
// code, and the healthy slot silently reverts on the next reboot. This asserts
// the gate lets such a boot through by watching for probes, which is the only
// externally visible evidence that Run entered the loop at all.
func TestBootConfirmer_ReconciliationOnlyBootStillProbes(t *testing.T) {
	restore := bootslots.SetStatePathForTest(filepath.Join(t.TempDir(), "boot-slot.json"))
	defer restore()
	if err := bootslots.Update(func(st *bootslots.State) error {
		st.Active = "a"
		st.LastTargetSHA = "1111111111111111111111111111111111111111"
		return nil // note: NO Pending — an earlier attempt already cleared it
	}); err != nil {
		t.Fatal(err)
	}
	// systemd-boot says we are running slot b, i.e. the slot we were installing.
	ev := t.TempDir()
	if err := os.WriteFile(
		filepath.Join(ev, "LoaderEntrySelected-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f"),
		utf16leEFIVar("powernode-b+1-2.efi"), 0o644); err != nil {
		t.Fatal(err)
	}
	defer bootslots.SetEfivarsDirForTest(ev)()
	// Keep every ESP operation inside a temp dir: this host may well be UEFI, and
	// a confirm reaching the real ESP would rewrite this machine's boot entries.
	defer espwrite.SetESPMountForTest(t.TempDir())()

	prober := &scriptedProber{results: []bool{true}}
	ctx, cancel := context.WithTimeout(context.Background(), 150*time.Millisecond)
	defer cancel()
	c := &BootConfirmer{
		Prober:       prober,
		PollInterval: 5 * time.Millisecond,
		Runner:       &recordingRunner{},
		BootedGitSHA: "1111111111111111111111111111111111111111",
	}
	if err := c.Run(ctx); err != nil {
		t.Fatalf("Run: %v", err)
	}
	if prober.probes() == 0 {
		t.Fatal("returned without probing — a boot needing reconciliation never reaches ConfirmBoot, " +
			"so the bless can never happen and the node reverts on its next reboot")
	}
}

// utf16leEFIVar renders an EFI variable body: 4-byte attribute prefix + UTF-16LE.
func utf16leEFIVar(sv string) []byte {
	b := []byte{7, 0, 0, 0}
	for _, r := range sv {
		b = append(b, byte(r), byte(r>>8))
	}
	return append(b, 0, 0)
}

// Default gate is 3 consecutive, matching the LKG capturer's.
func TestBootConfirmer_DefaultsToThreeConsecutive(t *testing.T) {
	c := &BootConfirmer{Prober: &scriptedProber{results: []bool{true}}}
	_, required, interval := c.resolveGate()
	if required != 3 {
		t.Errorf("required = %d, want 3", required)
	}
	if interval != 15*time.Second {
		t.Errorf("interval = %v, want 15s", interval)
	}
}
