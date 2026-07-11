package verify

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// TestCosignVerifier_StaticKey_RealBinary exercises the REAL cosign binary
// against a REAL static-key signature — the exact shape the platform CI produces
// (cosign sign-blob --key <priv> --bundle). This is the end-to-end proof the
// static-key verification path actually works (the fakeRunner unit tests only
// prove the fail-closed wiring). Skipped when cosign isn't installed.
func TestCosignVerifier_StaticKey_RealBinary(t *testing.T) {
	if _, err := exec.LookPath("cosign"); err != nil {
		t.Skip("cosign not installed; skipping real static-key verification")
	}
	dir := t.TempDir()
	t.Setenv("COSIGN_PASSWORD", "") // empty passphrase for the ephemeral key

	// 1. Generate an ephemeral static cosign key pair (cosign.key + cosign.pub).
	gen := exec.Command("cosign", "generate-key-pair")
	gen.Dir = dir
	if out, err := gen.CombinedOutput(); err != nil {
		t.Skipf("cosign generate-key-pair failed (%v): %s", err, out)
	}
	priv := filepath.Join(dir, "cosign.key")
	pub := filepath.Join(dir, "cosign.pub")

	// 2. Sign a blob with the private key, producing a bundle — mirrors CI's
	//    `cosign sign-blob --key env://COSIGN_PRIVATE_KEY --bundle …`.
	blob := filepath.Join(dir, "uki.bin")
	if err := os.WriteFile(blob, []byte("pretend-this-is-a-UKI"), 0o644); err != nil {
		t.Fatal(err)
	}
	bundle := filepath.Join(dir, "uki.cosign-bundle")
	sign := exec.Command("cosign", "sign-blob", "--yes", "--key", priv, "--bundle", bundle, blob)
	sign.Dir = dir
	if out, err := sign.CombinedOutput(); err != nil {
		t.Fatalf("cosign sign-blob: %v: %s", err, out)
	}

	v := &CosignVerifier{Runner: mount.ExecRunner{}, KeyPath: pub}

	// 3. A valid signature over the real bytes must verify.
	if err := v.VerifyBlob(context.Background(), blob, bundle); err != nil {
		t.Fatalf("static-key VerifyBlob should succeed for a valid signature: %v", err)
	}

	// 4. A tampered blob must FAIL closed (signature no longer covers the bytes).
	tampered := filepath.Join(dir, "uki-tampered.bin")
	if err := os.WriteFile(tampered, []byte("pretend-this-is-a-MALICIOUS-UKI"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := v.VerifyBlob(context.Background(), tampered, bundle); err == nil {
		t.Fatal("static-key VerifyBlob MUST fail for bytes the bundle didn't sign")
	}
}

// TestCosignVerifier_NoTrustAnchor_Refuses proves the verifier refuses to run
// with neither a key nor identity/issuer pins (no fail-open via empty config).
func TestCosignVerifier_NoTrustAnchor_Refuses(t *testing.T) {
	v := &CosignVerifier{Runner: mount.ExecRunner{}}
	if err := v.VerifyBlob(context.Background(), "/tmp/blob", "/tmp/bundle"); err == nil {
		t.Fatal("expected refusal when no KeyPath and no identity/issuer pins are set")
	}
}
