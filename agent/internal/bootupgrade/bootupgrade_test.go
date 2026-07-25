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
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/bootslots"
)

// fakeRunner fails on cosign and records whether the ESP was ever touched, so a
// test can prove an unverified UKI never reaches the ESP write.
type fakeRunner struct {
	cosignErr error
	sawBlkid  bool
	sawMount  bool
}

func (f *fakeRunner) Run(_ context.Context, name string, _ ...string) error {
	if name == "cosign" {
		return f.cosignErr
	}
	if name == "mount" {
		f.sawMount = true
	}
	return nil
}

func (f *fakeRunner) Output(_ context.Context, name string, _ ...string) ([]byte, error) {
	if name == "blkid" || name == "lsblk" {
		f.sawBlkid = true
	}
	return nil, errors.New("no device")
}

func TestApply_ValidateRejectsMissingFields(t *testing.T) {
	if _, err := Apply(context.Background(), Deps{}, Options{}); err == nil {
		t.Fatal("expected a validation error for empty options")
	}
	// A payload missing only the cosign bundle must still be rejected — we never
	// dispatch an unverifiable image.
	_, err := Apply(context.Background(), Deps{}, Options{
		TargetGitSHA: "a", UkiSha256: "b", DownloadPath: "/d",
		CosignPublicKey: "key",
	})
	if err == nil || !strings.Contains(err.Error(), "cosign_bundle_b64") {
		t.Fatalf("want cosign_bundle_b64 required, got %v", err)
	}
	// And missing the public key must be rejected.
	_, err = Apply(context.Background(), Deps{}, Options{
		TargetGitSHA: "a", UkiSha256: "b", DownloadPath: "/d",
		CosignBundleB64: "eA==",
	})
	if err == nil || !strings.Contains(err.Error(), "cosign_public_key") {
		t.Fatalf("want cosign_public_key required, got %v", err)
	}
}

func TestApply_CosignFailureRefusesESPWrite(t *testing.T) {
	stage := t.TempDir()
	payload := []byte("candidate-uki-bytes")
	sum := sha256.Sum256(payload)
	sha := hex.EncodeToString(sum[:])
	// Pre-stage the UKI so the download is skipped and no client is needed.
	if err := os.WriteFile(filepath.Join(stage, sha+".uki"), payload, 0o600); err != nil {
		t.Fatal(err)
	}

	fr := &fakeRunner{cosignErr: errors.New("certificate identity mismatch")}
	_, err := Apply(context.Background(), Deps{Runner: fr, StageDir: stage}, Options{
		TargetGitSHA:    "deadbeef",
		UkiSha256:       sha,
		CosignPublicKey: "-----BEGIN PUBLIC KEY-----\ntest\n-----END PUBLIC KEY-----",
		CosignBundleB64: base64.StdEncoding.EncodeToString([]byte("bundle")),
		DownloadPath:    "/download",
	})

	if err == nil || !strings.Contains(err.Error(), "cosign verify") {
		t.Fatalf("want a cosign verify error, got %v", err)
	}
	// SECURITY: the unverified UKI must be removed and the ESP never touched.
	if _, statErr := os.Stat(filepath.Join(stage, sha+".uki")); !os.IsNotExist(statErr) {
		t.Error("an unverified UKI must be removed from staging")
	}
	if fr.sawBlkid || fr.sawMount {
		t.Error("the ESP must not be located/mounted when cosign verification fails")
	}
}

func TestApply_SkipsDownloadForCachedVerifiedBytes(t *testing.T) {
	// With a nil client, Apply must not attempt a download when the staged file
	// already matches the target digest — it should proceed to (failing) cosign.
	stage := t.TempDir()
	payload := []byte("already-cached")
	sum := sha256.Sum256(payload)
	sha := hex.EncodeToString(sum[:])
	if err := os.WriteFile(filepath.Join(stage, sha+".uki"), payload, 0o600); err != nil {
		t.Fatal(err)
	}
	fr := &fakeRunner{cosignErr: errors.New("stop here")}
	_, err := Apply(context.Background(), Deps{Runner: fr, StageDir: stage}, Options{
		TargetGitSHA: "x", UkiSha256: sha, DownloadPath: "/d",
		CosignPublicKey: "-----BEGIN PUBLIC KEY-----\ntest\n-----END PUBLIC KEY-----",
		CosignBundleB64: base64.StdEncoding.EncodeToString([]byte("b")),
	})
	// It reached cosign (not a "nil transport client" download error).
	if err == nil || !strings.Contains(err.Error(), "cosign verify") {
		t.Fatalf("cached bytes should skip download and reach cosign; got %v", err)
	}
}

// stageVerifiedUKI writes a UKI whose sha matches its name so Apply skips the
// download, and returns that sha.
func stageVerifiedUKI(t *testing.T, stage string) string {
	t.Helper()
	body := []byte("fake-uki-bytes")
	sum := sha256.Sum256(body)
	sha := hex.EncodeToString(sum[:])
	if err := os.WriteFile(filepath.Join(stage, sha+".uki"), body, 0o600); err != nil {
		t.Fatal(err)
	}
	return sha
}

func applyOpts(sha string) Options {
	return Options{
		TargetGitSHA:    "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
		UkiSha256:       sha,
		DownloadPath:    "/api/v1/system/node_api/boot_image/download",
		CosignBundleB64: base64.StdEncoding.EncodeToString([]byte("bundle")),
		CosignPublicKey: "-----BEGIN PUBLIC KEY-----\nx\n-----END PUBLIC KEY-----\n",
	}
}

// TestApply_RefusesWhenNotBootedViaSystemdBoot covers the behavioural change made
// on 2026-07-25. The old code fell through here to a single-slot writer that
// replaced /EFI/BOOT/<removable> — systemd-boot itself — with the payload, which
// bricked VM 9002 unrecoverably. Apply must now refuse, and must not touch the
// ESP at all. Without this test a regression re-adding the fallback passes every
// other test in the repo.
func TestApply_RefusesWhenNotBootedViaSystemdBoot(t *testing.T) {
	restore := bootslots.SetEfivarsDirForTest(t.TempDir()) // empty → no LoaderInfo
	defer restore()

	stage := t.TempDir()
	sha := stageVerifiedUKI(t, stage)
	fr := &fakeRunner{} // cosign succeeds, so we reach the A/B precondition

	slot, err := Apply(context.Background(), Deps{Runner: fr, StageDir: stage}, applyOpts(sha))
	if err == nil {
		t.Fatal("expected Apply to refuse on a node with no A/B layout, got nil error")
	}
	if !strings.Contains(err.Error(), "refusing boot-image upgrade") {
		t.Fatalf("error should explain the refusal, got: %v", err)
	}
	if slot != "" {
		t.Errorf("refusal must not report a written slot, got %q", slot)
	}
	if fr.sawMount {
		t.Error("refusal must not mount or write the ESP")
	}
}

// TestApply_ProceedsPastPreconditionWhenLoaderInfoPresent is the negative control
// for the test above: with LoaderInfo present the refusal must NOT be the failure
// reason, proving the guard keys off the real variable rather than always
// refusing.
func TestApply_ProceedsPastPreconditionWhenLoaderInfoPresent(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(
		filepath.Join(dir, "LoaderInfo-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f"),
		[]byte("systemd-boot 255.4"), 0o644); err != nil {
		t.Fatal(err)
	}
	restore := bootslots.SetEfivarsDirForTest(dir)
	defer restore()

	stage := t.TempDir()
	sha := stageVerifiedUKI(t, stage)
	fr := &fakeRunner{}

	// Fails later (no real ESP in a temp dir) — the point is only that it is no
	// longer the no-A/B-layout refusal.
	_, err := Apply(context.Background(), Deps{Runner: fr, StageDir: stage}, applyOpts(sha))
	if err != nil && strings.Contains(err.Error(), "did not boot via systemd-boot") {
		t.Fatalf("must not refuse when LoaderInfo is present, got: %v", err)
	}
}
