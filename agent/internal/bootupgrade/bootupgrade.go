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
	Arch     string // "" → runtime.GOARCH
}

// BootTries is the systemd-boot boot-counter a newly-written slot starts with:
// the new UKI gets this many boot attempts before systemd-boot marks it bad and
// falls back to the other (good) slot.
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

	// 3. Write the INACTIVE A/B slot (systemd-boot boot-counted) and arm it as
	//    the one-shot next boot. The active slot stays untouched as the rollback
	//    target; if the new UKI fails to boot BootTries times, systemd-boot marks
	//    it bad and falls back to the good slot (no brick).
	inactive := bootslots.Other(bootslots.Load().Active)
	entry := bootslots.EntryName(inactive, BootTries) // e.g. powernode-b+3.efi
	if err := espwrite.WriteUKISlot(ctx, d.Runner, ukiPath, entry); err != nil {
		return "", fmt.Errorf("write ESP slot: %w", err)
	}
	if err := d.Runner.Run(ctx, "bootctl", "set-oneshot", entry); err != nil {
		return "", fmt.Errorf("bootctl set-oneshot %s: %w", entry, err)
	}
	return inactive, nil
}

// ConfirmBoot is called once per boot after the FIRST successful heartbeat
// (agent-health-gated). It blesses the current boot — `systemd-bless-boot good`
// strips the boot-counter from the running entry so systemd-boot stops counting
// it down toward rollback — and, when a pending upgrade's target matches the
// image that actually booted, promotes the pending slot to the persistent
// default (so subsequent boots use the new image, not the old one). If the node
// instead rolled back to the previous slot, the pending upgrade is cleared
// without promotion. Best-effort + idempotent; safe to call once per boot.
func ConfirmBoot(ctx context.Context, r mount.Runner, bootedGitSHA string) error {
	// Bless the running entry (no-op if not booted with counting / already good).
	_ = r.Run(ctx, "systemd-bless-boot", "good")

	st := bootslots.Load()
	if st.Pending == "" {
		return nil
	}
	if bootedGitSHA != "" && bootedGitSHA == st.PendingSHA {
		// The new slot booted healthy — make it the persistent default.
		good := bootslots.EntryName(st.Pending, 0) // powernode-<slot>.efi
		if err := r.Run(ctx, "bootctl", "set-default", good); err != nil {
			return fmt.Errorf("bootctl set-default %s: %w", good, err)
		}
		st.Active = st.Pending
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
