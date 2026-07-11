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
	"runtime"

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

// Apply runs the full upgrade: download → sha256 + cosign verify → write ESP.
// Idempotent — safe for the loop's crash-recovery re-dispatch (a matching cached
// download is reused; the ESP write re-writes the same bytes).
func Apply(ctx context.Context, d Deps, o Options) error {
	if err := o.validate(); err != nil {
		return err
	}
	stage := d.StageDir
	if stage == "" {
		stage = DefaultStageDir
	}
	if err := os.MkdirAll(stage, 0o700); err != nil {
		return fmt.Errorf("stage dir: %w", err)
	}
	ukiPath := filepath.Join(stage, o.UkiSha256+".uki")

	// 1. Download — skipped when a prior attempt already staged the right bytes
	//    (crash-recovery re-dispatch reuses a verified download, no client needed).
	if !fileHasSHA(ukiPath, o.UkiSha256) {
		if d.Client == nil {
			return errors.New("bootupgrade: nil transport client")
		}
		if err := download(ctx, d.Client, o.DownloadPath, ukiPath); err != nil {
			return fmt.Errorf("download UKI: %w", err)
		}
		if !fileHasSHA(ukiPath, o.UkiSha256) {
			_ = os.Remove(ukiPath)
			return fmt.Errorf("UKI sha256 mismatch (want %s)", o.UkiSha256)
		}
	}

	// 2. cosign-verify the exact bytes we will write. NEVER skipped — an
	//    unverified boot image is full node compromise.
	bundlePath := filepath.Join(stage, o.UkiSha256+".cosign-bundle")
	bundle, err := base64.StdEncoding.DecodeString(o.CosignBundleB64)
	if err != nil {
		return fmt.Errorf("decode cosign bundle: %w", err)
	}
	if err := os.WriteFile(bundlePath, bundle, 0o600); err != nil {
		return fmt.Errorf("write cosign bundle: %w", err)
	}
	keyPath := filepath.Join(stage, "cosign.pub")
	if err := os.WriteFile(keyPath, []byte(o.CosignPublicKey), 0o600); err != nil {
		return fmt.Errorf("write cosign public key: %w", err)
	}
	verifier := &verify.CosignVerifier{Runner: d.Runner, KeyPath: keyPath}
	if err := verifier.VerifyBlob(ctx, ukiPath, bundlePath); err != nil {
		_ = os.Remove(ukiPath) // don't leave an unverified blob staged
		return fmt.Errorf("cosign verify UKI: %w", err)
	}

	// 3. Write the ESP (backup + atomic replace of the arch's removable boot).
	arch := d.Arch
	if arch == "" {
		arch = runtime.GOARCH
	}
	if err := espwrite.WriteUKI(ctx, d.Runner, ukiPath, espwrite.RemovableBootName(arch)); err != nil {
		return fmt.Errorf("write ESP: %w", err)
	}
	return nil
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
