package bootupgrade

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/bootslots"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// recRunner records every command so a test can assert what did NOT run.
type recRunner struct {
	mu    sync.Mutex
	calls []string
}

func (r *recRunner) Run(_ context.Context, name string, args ...string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.calls = append(r.calls, strings.TrimSpace(name+" "+strings.Join(args, " ")))
	return nil
}

func (r *recRunner) Output(_ context.Context, name string, args ...string) ([]byte, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.calls = append(r.calls, "out:"+name+" "+strings.Join(args, " "))
	return nil, nil
}

func (r *recRunner) ran(substr string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, c := range r.calls {
		if strings.Contains(c, substr) {
			return true
		}
	}
	return false
}

// stagedOpts writes a UKI whose sha matches, so Apply skips the download and
// reaches the interesting part without a network or a real client.
func stagedOpts(t *testing.T) (Options, *Deps, *recRunner) {
	t.Helper()
	stage := t.TempDir()
	body := []byte("fake-uki-bytes")
	h := sha256.Sum256(body)
	sum := hex.EncodeToString(h[:])
	if err := os.WriteFile(filepath.Join(stage, sum+".uki"), body, 0o600); err != nil {
		t.Fatal(err)
	}
	r := &recRunner{}
	return Options{
		DownloadPath:    "/dl",
		UkiSha256:       sum,
		CosignBundleB64: base64.StdEncoding.EncodeToString([]byte("bundle")),
		CosignPublicKey: "key",
		TargetGitSHA:    strings.Repeat("a", 40),
	}, &Deps{Runner: r, StageDir: stage}, r
}

// happyDeps makes every guard pass, so a test only has to break the one thing
// it is about.
func happyDeps(d *applyDepSet) {
	d.verifyBlob = func(context.Context, mount.Runner, string, string, string) error { return nil }
	d.bootedViaSystemdBoot = func() bool { return true }
	d.efivarsAvailable = func() bool { return true }
	d.loadState = func() bootslots.State { return bootslots.State{Active: "a"} }
	d.updateState = func(fn func(*bootslots.State) error) error { return fn(&bootslots.State{}) }
	d.slotGoodExists = func(context.Context, mount.Runner, string) (bool, error) { return true, nil }
	d.writeUKISlot = func(context.Context, mount.Runner, string, string, string) error { return nil }
	d.lookPath = func(string) (string, error) { return "/usr/bin/bootctl", nil }
}

// THE crash-window property: the pending upgrade is RECORDED before the
// one-shot is ARMED.
//
// A crash between those two steps must fail toward "no upgrade", never toward
// "unprovable upgrade":
//
//	recorded-but-unarmed -> next boot is the OLD slot; ConfirmBoot sees Pending
//	                        set and a different slot booted, and clears it as a
//	                        proven rollback. Clean.
//	armed-but-unrecorded -> the node boots the NEW slot with nothing marking it
//	                        pending, so ConfirmBoot never blesses it and the boot
//	                        counter silently reverts the upgrade three boots
//	                        later, with no operator signal.
//
// Proving the ORDER requires failing the RECORD step and asserting set-oneshot
// never ran. Asserting merely that both happened passes against BOTH orderings
// — an earlier attempt did exactly that, was caught by mutation, and deleted.
func TestPendingRecordedBeforeOneShotArmed(t *testing.T) {
	o, d, r := stagedOpts(t)
	defer withApplyDeps(func(dep *applyDepSet) {
		happyDeps(dep)
		dep.updateState = func(func(*bootslots.State) error) error {
			return errors.New("persist is read-only")
		}
	})()

	_, err := Apply(context.Background(), *d, o)
	if err == nil {
		t.Fatal("expected Apply to fail when the pending record cannot be written")
	}
	// Assert the SPECIFIC failure. Accepting any error let this pass on an
	// unrelated validation failure (a short target sha) while proving nothing
	// about ordering — caught exactly that way while writing these.
	if !strings.Contains(err.Error(), "record pending slot") {
		t.Fatalf("failed for the wrong reason, so ordering is unproven: %v", err)
	}
	if r.ran("set-oneshot") {
		t.Fatal("set-oneshot ran even though recording the pending slot failed — the node " +
			"would boot an unprovable image with nothing marking it pending")
	}
}

// INV-3: an upgrade may never proceed without a known-good rollback target
// below the payload. This is the guard whose absence bricked VM 9002.
func TestRefusesWithoutRollbackTarget(t *testing.T) {
	o, d, r := stagedOpts(t)
	defer withApplyDeps(func(dep *applyDepSet) {
		happyDeps(dep)
		dep.slotGoodExists = func(context.Context, mount.Runner, string) (bool, error) {
			return false, nil // active slot has no blessed UKI
		}
	})()

	_, err := Apply(context.Background(), *d, o)
	if err == nil || !strings.Contains(err.Error(), "rollback target") {
		t.Fatalf("expected a rollback-target refusal, got %v", err)
	}
	if r.ran("set-oneshot") {
		t.Fatal("armed a one-shot despite having no rollback target")
	}
}

// Writing a slot while a previous upgrade is unproven clears the family the
// running image belongs to.
func TestRefusesWhileAnUpgradeIsPending(t *testing.T) {
	o, d, r := stagedOpts(t)
	defer withApplyDeps(func(dep *applyDepSet) {
		happyDeps(dep)
		dep.loadState = func() bootslots.State {
			return bootslots.State{Active: "a", Pending: "b", PendingSHA: "cafe"}
		}
	})()

	_, err := Apply(context.Background(), *d, o)
	if err == nil || !strings.Contains(err.Error(), "pending confirmation") {
		t.Fatalf("expected a pending-confirmation refusal, got %v", err)
	}
	if r.ran("set-oneshot") {
		t.Fatal("armed a one-shot while an upgrade was still unproven")
	}
}

// No systemd-boot means no A/B layout and nothing below the payload to roll
// back to. The removed single-slot fallback overwrote the bootloader itself.
func TestRefusesWithoutSystemdBoot(t *testing.T) {
	o, d, _ := stagedOpts(t)
	defer withApplyDeps(func(dep *applyDepSet) {
		happyDeps(dep)
		dep.bootedViaSystemdBoot = func() bool { return false }
		dep.efivarsAvailable = func() bool { return true }
	})()

	_, err := Apply(context.Background(), *d, o)
	if err == nil || !strings.Contains(err.Error(), "did not boot via") {
		t.Fatalf("expected a no-systemd-boot refusal, got %v", err)
	}
}

// An unreadable efivarfs must be reported as its own cause: telling an operator
// "no A/B layout" would send them to reimage a node that is actually fine.
func TestUnreadableEfivarsReportsItsOwnCause(t *testing.T) {
	o, d, _ := stagedOpts(t)
	defer withApplyDeps(func(dep *applyDepSet) {
		happyDeps(dep)
		dep.bootedViaSystemdBoot = func() bool { return false }
		dep.efivarsAvailable = func() bool { return false }
	})()

	_, err := Apply(context.Background(), *d, o)
	if err == nil || !strings.Contains(err.Error(), "EFI variable store") {
		t.Fatalf("expected an efivarfs-specific refusal, got %v", err)
	}
}

// A cosign failure must leave nothing staged: an unverified boot image on disk
// is what a later "already staged, skip the download" path would happily reuse.
func TestCosignFailureRemovesTheStagedUKI(t *testing.T) {
	o, d, _ := stagedOpts(t)
	uki := filepath.Join(d.StageDir, o.UkiSha256+".uki")
	defer withApplyDeps(func(dep *applyDepSet) {
		happyDeps(dep)
		dep.verifyBlob = func(context.Context, mount.Runner, string, string, string) error {
			return errors.New("signature does not verify")
		}
	})()

	if _, err := Apply(context.Background(), *d, o); err == nil {
		t.Fatal("expected Apply to fail cosign verification")
	}
	if _, statErr := os.Stat(uki); statErr == nil {
		t.Fatal("an unverified UKI was left staged — a later run would reuse it as already-downloaded")
	}
}

// bootctl is probed BEFORE the slot is written, so a node without it fails
// cleanly instead of leaving a written-but-unarmed slot behind.
func TestMissingBootctlRefusesBeforeWritingTheSlot(t *testing.T) {
	o, d, _ := stagedOpts(t)
	wrote := false
	defer withApplyDeps(func(dep *applyDepSet) {
		happyDeps(dep)
		dep.lookPath = func(string) (string, error) { return "", errors.New("not found") }
		dep.writeUKISlot = func(context.Context, mount.Runner, string, string, string) error {
			wrote = true
			return nil
		}
	})()

	_, err := Apply(context.Background(), *d, o)
	if err == nil || !strings.Contains(err.Error(), "bootctl not found") {
		t.Fatalf("expected a bootctl refusal, got %v", err)
	}
	if wrote {
		t.Fatal("wrote the slot before probing bootctl — leaves a written-but-unarmed slot")
	}
}
