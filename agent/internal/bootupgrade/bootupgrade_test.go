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
	if err := Apply(context.Background(), Deps{}, Options{}); err == nil {
		t.Fatal("expected a validation error for empty options")
	}
	// A payload missing only the cosign bundle must still be rejected — we never
	// dispatch an unverifiable image.
	err := Apply(context.Background(), Deps{}, Options{
		TargetGitSHA: "a", UkiSha256: "b", DownloadPath: "/d",
		CosignIdentityRegexp: "id", CosignIssuerRegexp: "iss",
	})
	if err == nil || !strings.Contains(err.Error(), "cosign_bundle_b64") {
		t.Fatalf("want cosign_bundle_b64 required, got %v", err)
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
	err := Apply(context.Background(), Deps{Runner: fr, StageDir: stage}, Options{
		TargetGitSHA:         "deadbeef",
		UkiSha256:            sha,
		CosignIdentityRegexp: "id",
		CosignIssuerRegexp:   "iss",
		CosignBundleB64:      base64.StdEncoding.EncodeToString([]byte("bundle")),
		DownloadPath:         "/download",
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
	err := Apply(context.Background(), Deps{Runner: fr, StageDir: stage}, Options{
		TargetGitSHA: "x", UkiSha256: sha, DownloadPath: "/d",
		CosignIdentityRegexp: "id", CosignIssuerRegexp: "iss",
		CosignBundleB64: base64.StdEncoding.EncodeToString([]byte("b")),
	})
	// It reached cosign (not a "nil transport client" download error).
	if err == nil || !strings.Contains(err.Error(), "cosign verify") {
		t.Fatalf("cached bytes should skip download and reach cosign; got %v", err)
	}
}
