// Package bootupgrade performs an in-place boot-image (UKI) upgrade on the node
// (campaign 019f505f increment 2): pull the target UKI from the platform, verify
// its sha256 + cosign signature over exactly the bytes it will boot, then write
// it to the ESP. It never reboots — the caller reboots after a nil return. The
// /persist-backed PKI survives an ESP-only write, so the rebooted node re-attaches
// with its existing cert (no re-enroll).
package bootupgrade

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"sync"

	"github.com/nodealchemy/powernode-system/agent/internal/bootslots"
	"github.com/nodealchemy/powernode-system/agent/internal/espwrite"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/transport"
	"github.com/nodealchemy/powernode-system/agent/internal/verify"
)

// DefaultStageDir stages the pulled UKI + cosign bundle for verification before
// the ESP write. Under /persist so it survives switch_root and a crash-recovery
// re-dispatch can reuse an already-verified download.
// DefaultStageDir stages the pulled UKI + cosign bundle for verification before
// the ESP write. A var, not a const, so tests can sandbox it: every current Apply
// test passes an explicit StageDir, but one that forgets would write cosign.pub
// and the bundle under /persist/cache/boot-image on the host running `go test`.
// Same class as the PendingComposePath const that let the suite delete live boot
// state.
var DefaultStageDir = "/persist/cache/boot-image"

// SetDefaultStageDirForTest points the staging dir at path, returning a restore
// func.
func SetDefaultStageDirForTest(path string) (restore func()) {
	prev := DefaultStageDir
	DefaultStageDir = path
	return func() { DefaultStageDir = prev }
}

// Options is the decoded upgrade_boot_image task payload.
type Options struct {
	TargetGitSHA string
	UkiSha256    string
	// CosignPublicKey is the platform's static cosign PUBLIC key (PEM), sourced
	// platform-side (not from the artifact/webhook). The agent verifies the UKI's
	// static-key signature against it. Public, not secret — safe to carry inline.
	CosignPublicKey string
	CosignBundleB64 string
	DownloadPath    string
}

func (o Options) validate() error {
	switch {
	case o.TargetGitSHA == "":
		return errors.New("target_git_sha required")
	case !isFullGitSHA(o.TargetGitSHA):
		// Checked HERE, not in the CLI, because this is the shared path. The
		// platform-dispatched handler is the unattended, fleet-wide one: a
		// malformed target sha there silently fails the confirm on every node it
		// reaches with nobody watching, whereas a CLI operator sees the error and
		// retries. Validating only the attended path protected the one that needed
		// it least. Shape is not correctness — a well-formed but WRONG sha still
		// fails the confirm — but it removes the whole malformed class.
		return fmt.Errorf("target_git_sha %q is not a 40-character hex git sha", o.TargetGitSHA)
	case o.UkiSha256 == "":
		return errors.New("uki_sha256 required")
	case o.DownloadPath == "":
		return errors.New("download_path required")
	case o.CosignBundleB64 == "":
		return errors.New("cosign_bundle_b64 required")
	case o.CosignPublicKey == "":
		return errors.New("cosign_public_key required")
	}
	return nil
}

// Deps are the collaborators Apply needs.
type Deps struct {
	Runner   mount.Runner
	Client   *transport.Client
	StageDir string // "" → DefaultStageDir
}

// bootMu serializes ALL boot-image mutation. bootslots.Update only guards the
// state file; the ESP is the other shared resource, and Apply (task-lease
// goroutine) writes slot files while ConfirmBoot (heartbeat goroutine) renames
// and stats them. Unguarded, Apply's removeSlotFiles can delete the very file
// ConfirmBoot just blessed — leaving `bootctl set-default` pointing at an entry
// that no longer exists. Both hold this for their whole body.
var bootMu sync.Mutex

// BootTries is the systemd-boot boot-counter a newly-written slot starts with.
// The upgrade also `bootctl set-oneshot`s the new slot, so in practice the new
// UKI gets exactly ONE forced attempt: if that boot doesn't reach a healthy
// heartbeat (which blesses it), the one-shot is consumed and the next boot falls
// through to the still-old default slot — immediate rollback. The counter is the
// margin that keeps the entry from being flagged bad during that single attempt.
const BootTries = 3

// Apply runs the full upgrade: download → sha256 + cosign verify → write the
// INACTIVE A/B slot → arm it as the one-shot next boot. It returns the slot it
// wrote ("a"/"b") so the caller can record the pending upgrade. It does NOT
// reboot. Idempotent — a crash-recovery re-dispatch reuses the cached download
// and re-writes the same slot.
func Apply(ctx context.Context, d Deps, o Options) (writtenSlot string, err error) {
	if err := o.validate(); err != nil {
		return "", err
	}

	// Fail fast on an in-flight upgrade, BEFORE staging and pulling ~80MB. With
	// Pending set the node is running a slot that is NOT yet blessed, so its
	// counter-suffixed file is its only boot file — and the "inactive" slot this
	// upgrade would clear is the one we booted from. Advisory only: the state can
	// change while the download runs (the heartbeat's ConfirmBoot may bless or
	// roll back mid-pull), so the authoritative check is repeated under bootMu.
	if p := bootslots.Load().Pending; p != "" {
		// NOT self-clearing in every case. ConfirmBoot reaches a verdict and clears
		// Pending when it can prove bless-or-rollback, but three branches retain it
		// deliberately: no systemd-boot, no booted sha, and "running the pending
		// slot but its image reports a different sha than requested". The last one
		// is what a WRONG target sha produces, it survives reboots (Pending lives on
		// /persist), and the operator's remedy for it is to dispatch a CORRECTED
		// upgrade — which this guard would otherwise refuse forever. Name the escape
		// in the error so a stuck node is a documented state, not a dead end.
		return "", fmt.Errorf("refusing boot-image upgrade: slot %s is pending confirmation — "+
			"the running slot is not yet blessed, so overwriting the inactive slot now would "+
			"clear the image this node booted from. If the pending upgrade can never confirm "+
			"(e.g. it was dispatched with the wrong target sha), run "+
			"`powernode-agent abandon-boot-image --yes` to clear it, then re-dispatch", p)
	}

	stage := d.StageDir
	if stage == "" {
		stage = DefaultStageDir
	}
	if err := os.MkdirAll(stage, 0o700); err != nil {
		return "", fmt.Errorf("stage dir: %w", err)
	}
	ukiPath := filepath.Join(stage, o.UkiSha256+".uki")

	// 1. Download — skipped when a prior attempt already staged the right bytes
	//    (crash-recovery re-dispatch reuses a verified download, no client needed).
	if !fileHasSHA(ukiPath, o.UkiSha256) {
		if d.Client == nil {
			return "", errors.New("bootupgrade: nil transport client")
		}
		if err := download(ctx, d.Client, o.DownloadPath, ukiPath); err != nil {
			return "", fmt.Errorf("download UKI: %w", err)
		}
		if !fileHasSHA(ukiPath, o.UkiSha256) {
			_ = os.Remove(ukiPath)
			return "", fmt.Errorf("UKI sha256 mismatch (want %s)", o.UkiSha256)
		}
	}

	// 2. cosign-verify the exact bytes we will write. NEVER skipped — an
	//    unverified boot image is full node compromise.
	bundlePath := filepath.Join(stage, o.UkiSha256+".cosign-bundle")
	bundle, err := base64.StdEncoding.DecodeString(o.CosignBundleB64)
	if err != nil {
		return "", fmt.Errorf("decode cosign bundle: %w", err)
	}
	if err := os.WriteFile(bundlePath, bundle, 0o600); err != nil {
		return "", fmt.Errorf("write cosign bundle: %w", err)
	}
	keyPath := filepath.Join(stage, "cosign.pub")
	if err := os.WriteFile(keyPath, []byte(o.CosignPublicKey), 0o600); err != nil {
		return "", fmt.Errorf("write cosign public key: %w", err)
	}
	verifier := &verify.CosignVerifier{Runner: d.Runner, KeyPath: keyPath}
	if err := verifier.VerifyBlob(ctx, ukiPath, bundlePath); err != nil {
		_ = os.Remove(ukiPath) // don't leave an unverified blob staged
		return "", fmt.Errorf("cosign verify UKI: %w", err)
	}

	// 3. Install the boot image.
	//    - A/B (booted via systemd-boot): write the INACTIVE slot boot-counted
	//      and arm it as the one-shot next boot. The active slot stays as the
	//      rollback target; a UKI that fails to boot falls back to it.
	//    - Otherwise: REFUSE. This used to fall back to the single-slot writer,
	//      which overwrites /EFI/BOOT/<removable> — i.e. systemd-boot itself —
	//      with the new UKI. Its comment claimed "no A/B, but no brick either";
	//      that was empirically false. On 2026-07-25 (RCP v2 P0-b, VM 9002) a
	//      broken-but-validly-signed UKI took this path and produced an
	//      UNRECOVERABLE panic-reboot loop: 48 boots of the bad image, 24 kernel
	//      panics, zero automatic recovery, fixed only by host-side offline
	//      surgery on the stopped VM. Replacing the firmware's only bootloader
	//      with an unverified payload leaves nothing to roll back TO, so INV-3
	//      ("rollback lives below the payload") cannot hold. Failing closed
	//      means such a node simply does not upgrade — a stuck node beats a
	//      bricked one.
	if !bootslots.BootedViaSystemdBoot() {
		// Distinguish the two causes — they need different remedies, and reporting
		// "no A/B layout" for an unmounted efivarfs would misdirect an operator
		// into reimaging a node that is actually fine.
		if !bootslots.EfivarsAvailable() {
			return "", errors.New("refusing boot-image upgrade: the EFI variable store is not " +
				"readable (efivarfs not mounted in this namespace?), so the boot method cannot be " +
				"determined. Refusing rather than guessing — mount efivarfs and retry")
		}
		return "", errors.New("refusing boot-image upgrade: this node did not boot via " +
			"systemd-boot (no LoaderInfo EFI variable), so it has no A/B slot layout and " +
			"no below-payload rollback. The former single-slot fallback overwrote the " +
			"firmware's own bootloader with the payload and bricked the node; it was " +
			"removed deliberately. To migrate an existing node onto the A/B layout in place, " +
			"see docs/runbooks/ops-hub-boot-image-reprovision.md (offline ESP copy from the " +
			"hypervisor) — do NOT reprovision a node whose /persist must survive")
	}
	// Take the boot lock ONLY now. Everything above (download, sha check, cosign
	// verify) touches just the staging dir, which ConfirmBoot never reads. Holding
	// it across a full UKI pull would stall the heartbeat goroutine — ConfirmBoot
	// runs synchronously in PostSend alongside authorized_keys, SDWAN and docker
	// reconcile — and make the platform see the node as silent, on exactly the
	// nodes that have an upgrade in flight.
	bootMu.Lock()
	defer bootMu.Unlock()

	state := bootslots.Load()
	active := state.Active

	// Refuse while a previous upgrade is still unproven. With Pending set, the
	// node is running a slot that has NOT yet been blessed, so its counter-suffixed
	// file is its only boot file. A second upgrade targets the inactive slot —
	// which, mid-confirmation, is the one we are currently running from — and
	// WriteUKISlot clears the whole slot family before writing. That destroys the
	// running image and leaves an unproven replacement in its place. The pending
	// upgrade must reach a verdict (bless or roll back) first; both outcomes clear
	// Pending, so this unblocks by itself on the next heartbeat or reboot.
	if state.Pending != "" {
		return "", fmt.Errorf("refusing boot-image upgrade: slot %s is pending confirmation "+
			"(target %s) — the running slot is not yet blessed, so overwriting the inactive slot "+
			"now would clear the image this node booted from. Wait for the in-flight upgrade to "+
			"bless or roll back", state.Pending, state.PendingSHA)
	}

	// Verify the ROLLBACK TARGET actually exists before touching anything. The
	// active slot is read from /persist, which can be lost or reset (a documented
	// event class) — after which Active reads "a" while the node is really running
	// b. WriteUKISlot would then clear slot b's files, destroying the good image
	// of record, and a failed upgrade would fall back to whatever stale UKI sits
	// in slot a. Refusing here costs one stat and keeps a known-good rollback
	// target as a precondition of every upgrade (INV-3).
	activeOK, err := espwrite.SlotGoodExists(ctx, d.Runner, bootslots.EntryBase(active))
	if err != nil {
		return "", fmt.Errorf("check rollback target %s: %w", active, err)
	}
	if !activeOK {
		return "", fmt.Errorf("refusing boot-image upgrade: rollback target slot %s has no blessed "+
			"UKI on the ESP, so a failed upgrade would have nothing to fall back to. This usually "+
			"means /persist slot state diverged from the ESP; reconcile before upgrading", active)
	}

	// bootctl is required for set-oneshot below. Probe it BEFORE writing the slot
	// so a node without it fails cleanly instead of leaving a written-but-unarmed
	// slot behind (it ships via the base-os module, not the minimal initramfs).
	if _, lookErr := exec.LookPath("bootctl"); lookErr != nil {
		return "", fmt.Errorf("refusing boot-image upgrade: bootctl not found, cannot arm the "+
			"one-shot boot entry: %w", lookErr)
	}

	inactive := bootslots.Other(active)
	base := bootslots.EntryBase(inactive)
	entry := bootslots.EntryName(inactive, BootTries) // e.g. powernode-b+3.efi
	if err := espwrite.WriteUKISlot(ctx, d.Runner, ukiPath, base, entry); err != nil {
		return "", fmt.Errorf("write ESP slot: %w", err)
	}

	// Record the pending upgrade BEFORE arming the one-shot, and record it HERE
	// rather than leaving it to the caller.
	//
	// Ordering: a crash between these two steps must fail toward "no upgrade",
	// never toward "unprovable upgrade". Recorded-but-unarmed means the next boot
	// is the OLD slot, where ConfirmBoot sees Pending set, sees a different slot
	// booted, and clears it as a proven rollback — clean. Armed-but-unrecorded
	// (the previous order) means the node boots the NEW slot with nothing marking
	// it pending, so ConfirmBoot never blesses it and the boot counter silently
	// reverts the upgrade three boots later, with no operator signal.
	//
	// Single writer: both callers — the task handler and the CLI — used to do this
	// themselves after Apply returned, which is what created the window and let
	// the two paths drift (4b13c961 fixed one such drift already). Apply holds
	// bootMu here and bootslots.Update takes stateMu, matching the documented
	// bootMu→stateMu lock order.
	if err := bootslots.Update(func(st *bootslots.State) error {
		st.Pending = inactive
		st.PendingSHA = o.TargetGitSHA
		return nil
	}); err != nil {
		return "", fmt.Errorf("record pending slot %s: %w", inactive, err)
	}

	if err := d.Runner.Run(ctx, "bootctl", "set-oneshot", entry); err != nil {
		return "", fmt.Errorf("bootctl set-oneshot %s: %w", entry, err)
	}
	return inactive, nil
}

// ConfirmBoot is called once per boot after the FIRST successful heartbeat
// (agent-health-gated). When a pending upgrade's target matches the image that
// actually booted, it blesses the new slot — strips the systemd-boot boot-counter
// from its UKI filename so it stops counting toward rollback — and, only after
// confirming the blessed file exists, promotes it to the persistent default. If
// the node instead rolled back to the previous slot, it clears the attempt from
// state and leaves the ESP ALONE — deliberately (see the tail comment): it does
// NOT remove the failed attempt's counter files, because on the branches where
// the booted slot is unprovable those files may belong to the slot currently
// running. Stale counter files are harmless — WriteUKISlot clears a slot family
// before every write — and `powernode-agent abandon-boot-image` removes them on
// demand. Idempotent: on a
// retry (e.g. set-default failed), the already-blessed slot re-blesses as a
// no-op. Returns an error (leaving Pending set for a retry) if any step fails, so
// a healthy upgrade is never left un-promoted while state claims success.
func ConfirmBoot(ctx context.Context, r mount.Runner, bootedGitSHA string) error {
	// Cheap pre-check OUTSIDE any write path: the overwhelmingly common case is
	// "no upgrade in flight", and that must touch nothing at all — no lock, no
	// state file creation, no ESP access.
	if bootslots.Load().Pending == "" {
		return nil
	}

	bootMu.Lock()
	defer bootMu.Unlock()

	return bootslots.Update(func(st *bootslots.State) error {
		if st.Pending == "" {
			return nil // raced with another confirm; nothing to do
		}

		// A slot is pending, so we MUST reach a verdict. Returning nil here would
		// mark the boot confirmed (the caller latches bootBlessed) and never retry,
		// silently abandoning a healthy upgrade. Distinguish the two causes the way
		// Apply does, because they need different operator remedies.
		if !bootslots.BootedViaSystemdBoot() {
			if !bootslots.EfivarsAvailable() {
				return fmt.Errorf("confirm boot: slot %s is pending but the EFI variable store is "+
					"unreadable (efivarfs not mounted?), so the booted entry cannot be determined", st.Pending)
			}
			return fmt.Errorf("confirm boot: slot %s is pending but this boot did not go through "+
				"systemd-boot (no LoaderInfo), so there is nothing to bless", st.Pending)
		}

		base := bootslots.EntryBase(st.Pending)

		// Ask systemd-boot which slot actually booted BEFORE reasoning about the
		// sha. LoaderEntrySelected settles the question outright, and it must be
		// consulted first: a node that genuinely rolled back to an image carrying
		// no powernode.image_git_sha marker (netboot, rpi4, pre-campaign images)
		// is fully provable here, yet checking the sha first would error on it
		// every heartbeat tick for the rest of the boot — the sha cannot change
		// within a boot. That is the same permanent-per-tick error this code
		// deliberately refuses to inflict on the mismatch path.
		booted := bootslots.BootedSlot() // "" when undeterminable

		if booted != "" && booted != st.Pending {
			// Provably running the OTHER slot: sd-boot fell back. Routine, expected
			// rollback — clear the attempt and report success, regardless of whether
			// the booted image reports a sha at all.
			st.Pending = ""
			st.PendingSHA = ""
			return nil
		}

		// Past here we are either ON the pending slot or cannot tell — both
		// unprovable. Never latch success and never touch the ESP: the pending
		// slot is unblessed, so its counter-suffixed file is its ONLY boot file.
		if bootedGitSHA == "" {
			return fmt.Errorf("confirm boot: slot %s is pending and the booted image reports no "+
				"git_sha, and systemd-boot does not identify a different slot — cannot prove the "+
				"upgrade succeeded or rolled back, so refusing to record either", st.Pending)
		}

		if booted == st.Pending && bootedGitSHA != st.PendingSHA {
			return fmt.Errorf("confirm boot: running slot %s but its image reports git_sha %q, "+
				"not the requested %q — refusing to bless or to clean; check the target sha",
				st.Pending, bootedGitSHA, st.PendingSHA)
		}

		if bootedGitSHA == st.PendingSHA {
			// New slot booted healthy: bless it, confirm the good file exists, then
			// promote it to default. Order matters — never set-default a name that
			// doesn't resolve to a file (bootctl doesn't validate existence).
			if err := espwrite.BlessSlot(ctx, r, base); err != nil {
				return fmt.Errorf("bless slot %s: %w", st.Pending, err)
			}
			ok, err := espwrite.SlotGoodExists(ctx, r, base)
			if err != nil {
				return err
			}
			if !ok {
				return fmt.Errorf("bless slot %s: good file missing after bless", st.Pending)
			}
			if err := r.Run(ctx, "bootctl", "set-default", base+".efi"); err != nil {
				return fmt.Errorf("bootctl set-default %s.efi: %w", base, err)
			}
			// Record the promotion on the ESP as well. set-default writes only the
			// LoaderEntryDefault EFI variable, which on a VM lives in the efidisk
			// varstore; loader.conf otherwise keeps naming the OLD slot forever, so
			// losing or recreating that varstore silently reverts the node to the
			// previous image with nothing on disk disagreeing. Best-effort: a
			// healthy, blessed, NVRAM-promoted slot must not be failed back over
			// this belt-and-braces write.
			// Deliberately ignored: the slot is already blessed and promoted in
			// NVRAM, so the upgrade HAS succeeded. Returning here would leave
			// Pending set and re-run the whole confirm every heartbeat over a
			// convenience file. The cost of the miss is the pre-existing
			// behaviour (NVRAM-only), not a regression.
			_ = espwrite.SetLoaderDefault(ctx, r, base)
			st.Active = st.Pending
		}
		// Reached when the authoritative slot signal is unavailable (no
		// LoaderEntrySelected) and the sha did not match. Clear the attempt but
		// leave the ESP ALONE: stale counter files are harmless (WriteUKISlot
		// clears the whole slot family before every write) whereas deleting a slot
		// we might be running from is not recoverable in place.
		st.Pending = ""
		st.PendingSHA = ""
		return nil
	})
}

func download(ctx context.Context, c *transport.Client, path, dst string) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.PlatformURL+path, nil)
	if err != nil {
		return err
	}
	resp, err := c.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("unexpected status %d", resp.StatusCode)
	}
	tmp := dst + ".part"
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	if _, err := io.Copy(f, resp.Body); err != nil {
		f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	return os.Rename(tmp, dst)
}

func fileHasSHA(path, want string) bool {
	if want == "" {
		return false
	}
	f, err := os.Open(path)
	if err != nil {
		return false
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return false
	}
	return hex.EncodeToString(h.Sum(nil)) == want
}

// isFullGitSHA reports whether s is a 40-character lowercase hex git sha.
func isFullGitSHA(s string) bool {
	if len(s) != 40 {
		return false
	}
	for _, c := range s {
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return false
		}
	}
	return true
}
