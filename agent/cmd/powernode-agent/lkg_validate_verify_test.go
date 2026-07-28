package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/runtime"
)

// digestOf returns the "sha256:<hex>" form the LKG stores.
func digestOf(b []byte) string {
	sum := sha256.Sum256(b)
	return "sha256:" + hex.EncodeToString(sum[:])
}

// writeLKGFixture builds a one-module frozen LKG plus its blob cache, and
// returns (lkgPath, cacheDir). blobContent is what actually lands on disk —
// pass something other than `declared` to simulate a corrupt or truncated blob.
func writeLKGFixture(t *testing.T, declared, blobContent []byte) (string, string) {
	t.Helper()
	dir := t.TempDir()
	cacheDir := filepath.Join(dir, "cache")
	if err := os.MkdirAll(cacheDir, 0o755); err != nil {
		t.Fatal(err)
	}

	digest := digestOf(declared)
	blobPath := filepath.Join(cacheDir, strings.Replace(digest, "sha256:", "sha256_", 1)+".erofs")
	if err := os.WriteFile(blobPath, blobContent, 0o644); err != nil {
		t.Fatal(err)
	}

	lkg := &runtime.BootLKG{
		Source:   "https://example.invalid",
		Hostname: "fixture",
		Modules: []runtime.LKGModule{{
			ID:          "019e5975-cb4e-70c9-acf9-e47c82cdc6ce",
			Name:        "powernode-system-base",
			HasDataFile: true,
			Digest:      digest,
			Manifest:    json.RawMessage(`{"name":"powernode-system-base"}`),
		}},
	}
	lkgPath := filepath.Join(dir, "assignment-lkg.json")
	if err := runtime.WriteBootLKG(lkgPath, lkg); err != nil {
		t.Fatalf("WriteBootLKG: %v", err)
	}
	return lkgPath, cacheDir
}

func runValidate(t *testing.T, lkgPath, cacheDir string, verify bool) (string, error) {
	t.Helper()
	cmd := lkgValidateCmd()
	var out bytes.Buffer
	cmd.SetOut(&out)
	cmd.SetErr(&out)
	args := []string{"--path", lkgPath, "--cache-dir", cacheDir}
	if verify {
		args = append(args, "--verify")
	}
	cmd.SetArgs(args)
	err := cmd.Execute()
	return out.String(), err
}

// THE incident, reproduced. On 2026-07-27 a blob seeded into ops-hub's cache
// while the guest also had /persist mounted landed as a ZERO-BYTE file in the
// guest's view. Every structural check passed — the file existed, the LKG
// checksum was intact — and the node would have failed to compose on some later
// boot, because the boot path re-hashes and treats a mismatch as a cache miss,
// then tries to pull from a platform that is down pre-pivot.
//
// This asserts the gap FIRST (presence-only validation is happy) and then that
// --verify closes it. If the first half ever starts failing, presence checking
// grew teeth and this test's premise needs revisiting.
func TestLKGValidate_TruncatedBlobPassesPresenceButFailsVerify(t *testing.T) {
	declared := []byte("the real erofs bytes")
	lkgPath, cacheDir := writeLKGFixture(t, declared, []byte{}) // 0 bytes on disk

	out, err := runValidate(t, lkgPath, cacheDir, false)
	if err != nil {
		t.Fatalf("presence-only validate rejected a present-but-empty blob (%v)\n%s", err, out)
	}
	if !strings.Contains(out, "VALID") {
		t.Fatalf("expected presence-only validate to report VALID:\n%s", out)
	}
	if !strings.Contains(out, "--verify") {
		t.Errorf("a presence-only PASS must say what it did not check:\n%s", out)
	}

	out, err = runValidate(t, lkgPath, cacheDir, true)
	if err == nil {
		t.Fatalf("--verify accepted a truncated blob — the latent brick is undetected:\n%s", out)
	}
	if !strings.Contains(out, "CORRUPT") {
		t.Errorf("expected the offending module named as CORRUPT:\n%s", out)
	}
}

// Content that differs at the same length must fail too — length is not a proxy
// for integrity.
func TestLKGValidate_CorruptSameLengthBlobFailsVerify(t *testing.T) {
	declared := []byte("AAAAAAAAAAAAAAAA")
	lkgPath, cacheDir := writeLKGFixture(t, declared, []byte("BBBBBBBBBBBBBBBB"))

	out, err := runValidate(t, lkgPath, cacheDir, true)
	if err == nil {
		t.Fatalf("--verify accepted a same-length corrupt blob:\n%s", out)
	}
}

// The healthy path must stay green, or --verify is unusable in practice.
func TestLKGValidate_IntactBlobPassesVerify(t *testing.T) {
	declared := []byte("the real erofs bytes")
	lkgPath, cacheDir := writeLKGFixture(t, declared, declared)

	out, err := runValidate(t, lkgPath, cacheDir, true)
	if err != nil {
		t.Fatalf("--verify rejected an intact blob: %v\n%s", err, out)
	}
	for _, want := range []string{"all blob contents match", "VALID"} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in output:\n%s", want, out)
		}
	}
}

// A missing blob must still be caught, with or without --verify.
func TestLKGValidate_MissingBlobFailsEitherWay(t *testing.T) {
	declared := []byte("the real erofs bytes")
	lkgPath, cacheDir := writeLKGFixture(t, declared, declared)

	entries, err := os.ReadDir(cacheDir)
	if err != nil || len(entries) == 0 {
		t.Fatalf("fixture cache unexpectedly empty: %v", err)
	}
	if err := os.Remove(filepath.Join(cacheDir, entries[0].Name())); err != nil {
		t.Fatal(err)
	}

	for _, verify := range []bool{false, true} {
		if _, err := runValidate(t, lkgPath, cacheDir, verify); err == nil {
			t.Fatalf("a missing blob was accepted (verify=%v)", verify)
		}
	}
}

// The default path must come from the source constant, not a plausible-looking
// literal. A stale, extremely convincing copy of this file lives at
// /persist/boot-upgrade-stage/assignment-lkg.json that NOTHING reads; hours were
// lost editing it. Anything resolving the LKG must agree with the boot path.
func TestLKGValidate_DefaultPathIsTheSourceConstant(t *testing.T) {
	got, err := lkgValidateCmd().Flags().GetString("path")
	if err != nil {
		t.Fatal(err)
	}
	if got != runtime.BootLKGPath {
		t.Fatalf("default --path is %q, want runtime.BootLKGPath (%q)", got, runtime.BootLKGPath)
	}
	if strings.Contains(got, "boot-upgrade-stage") {
		t.Fatal("default --path points at the staging decoy, which nothing reads")
	}
}
