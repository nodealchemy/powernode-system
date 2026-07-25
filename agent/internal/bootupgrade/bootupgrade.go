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

	"github.com/nodealchemy/powernode-system/agent/internal/bootslots"
	"github.com/nodealchemy/powernode-system/agent/internal/espwrite"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/transport"
	"github.com/nodealchemy/powernode-system/agent/internal/verify"
)

// DefaultStageDir stages the pulled UKI + cosign bundle for verification before
// the ESP write. Under /persist so it survives switch_root and a crash-recovery
// re-dispatch can reuse an already-verified download.
const DefaultStageDir = "/persist/cache/boot-image"

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
		return "", errors.New("refusing boot-image upgrade: this node did not boot via " +
			"systemd-boot (no LoaderInfo EFI variable), so it has no A/B slot layout and " +
			"no below-payload rollback. The former single-slot fallback overwrote the " +
			"firmware's own bootloader with the payload and bricked the node; it was " +
			"removed deliberately. Reimage this node onto the A/B layout instead")
	}
	active := bootslots.Load().Active

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
// the node instead rolled back to the previous slot, it cleans the failed
// attempt's counter files and leaves the active slot unchanged. Idempotent: on a
// retry (e.g. set-default failed), the already-blessed slot re-blesses as a
// no-op. Returns an error (leaving Pending set for a retry) if any step fails, so
// a healthy upgrade is never left un-promoted while state claims success.
func ConfirmBoot(ctx context.Context, r mount.Runner, bootedGitSHA string) error {
	// Only meaningful when we actually booted through systemd-boot's counted
	// entries — old-layout nodes have nothing to bless.
	if !bootslots.BootedViaSystemdBoot() {
		return nil
	}
	st := bootslots.Load()
	if st.Pending == "" {
		return nil // no upgrade in flight this boot
	}
	base := bootslots.EntryBase(st.Pending)

	// An empty booted sha means "unknown", NOT "rolled back". Treating it as a
	// rollback is actively destructive: if the pending slot DID boot but the
	// cmdline marker is missing or unparsed, the rollback branch below would
	// CleanSlot() the boot file of the slot we are RUNNING FROM, then clear
	// Pending so nothing ever retries. The node keeps running from RAM, looks
	// healthy, and silently reverts to the old image at the next reboot — the
	// same class of defect as the 2026-07-25 incident, where state logic
	// diverged from boot reality. Return an error and leave Pending set so the
	// next heartbeat tick re-evaluates once the sha is readable.
	if bootedGitSHA == "" {
		return fmt.Errorf("confirm boot: booted image git_sha unknown while slot %s is pending "+
			"(refusing to treat unknown as rollback — that would delete the running slot's boot file)",
			st.Pending)
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
		st.Active = st.Pending
	} else {
		// Rolled back to the previous slot — drop the failed attempt's counter
		// files; the active slot is unchanged.
		_ = espwrite.CleanSlot(ctx, r, base)
	}
	st.Pending = ""
	st.PendingSHA = ""
	return st.Save()
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
