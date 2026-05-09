package verify

import (
	"context"
	"errors"
	"testing"

	"github.com/powernode/platform/extensions/system/agent/internal/mount"
)

func TestCosignVerifierShellsOutWithCorrectArgs(t *testing.T) {
	runner := &mount.RecorderRunner{}
	v := &CosignVerifier{
		Runner:         runner,
		IdentityRegexp: `https://gitea.example/.+`,
		IssuerRegexp:   `https://token.actions.example/`,
	}
	err := v.VerifyBlob(context.Background(),
		"/cache/abc.cfs", "/cache/abc.cosign-bundle")
	if err != nil {
		t.Fatalf("VerifyBlob: %v", err)
	}

	if len(runner.Invocations) != 1 {
		t.Fatalf("expected 1 invocation, got %d", len(runner.Invocations))
	}
	inv := runner.Invocations[0]
	if inv.Name != "cosign" || inv.Op != "Run" {
		t.Errorf("expected cosign Run, got %+v", inv)
	}

	wantArgs := []string{
		"verify-blob",
		"--bundle", "/cache/abc.cosign-bundle",
		"--certificate-identity-regexp", `https://gitea.example/.+`,
		"--certificate-oidc-issuer-regexp", `https://token.actions.example/`,
		"/cache/abc.cfs",
	}
	if len(inv.Args) != len(wantArgs) {
		t.Fatalf("args length: got %d want %d (%v)", len(inv.Args), len(wantArgs), inv.Args)
	}
	for i := range wantArgs {
		if inv.Args[i] != wantArgs[i] {
			t.Errorf("args[%d]: got %q want %q", i, inv.Args[i], wantArgs[i])
		}
	}
}

func TestCosignVerifierPropagatesError(t *testing.T) {
	runner := &mount.RecorderRunner{
		StubErr: map[string]error{
			"cosign verify-blob --bundle /b --certificate-identity-regexp  --certificate-oidc-issuer-regexp  /a": errors.New("untrusted"),
		},
	}
	v := &CosignVerifier{Runner: runner}
	err := v.VerifyBlob(context.Background(), "/a", "/b")
	if err == nil {
		t.Errorf("expected error from runner")
	}
}

func TestCosignVerifierEmptyPathsRejected(t *testing.T) {
	v := &CosignVerifier{Runner: &mount.RecorderRunner{}}

	if err := v.VerifyBlob(context.Background(), "", "/b"); err == nil {
		t.Errorf("expected error for empty blobPath")
	}
	if err := v.VerifyBlob(context.Background(), "/a", ""); err == nil {
		t.Errorf("expected error for empty bundlePath")
	}
}

func TestCosignVerifierNilReceiver(t *testing.T) {
	var v *CosignVerifier
	if err := v.VerifyBlob(context.Background(), "/a", "/b"); err == nil {
		t.Errorf("expected error for nil receiver")
	}
}

func TestCosignVerifierNilRunner(t *testing.T) {
	v := &CosignVerifier{}
	if err := v.VerifyBlob(context.Background(), "/a", "/b"); err == nil {
		t.Errorf("expected error for nil Runner")
	}
}

func TestAlwaysOKApproves(t *testing.T) {
	var v Verifier = AlwaysOK{}
	if err := v.VerifyBlob(context.Background(), "/a", "/b"); err != nil {
		t.Errorf("AlwaysOK should approve: %v", err)
	}
}

// Compile-time check: CosignVerifier and AlwaysOK satisfy Verifier.
var _ Verifier = (*CosignVerifier)(nil)
var _ Verifier = AlwaysOK{}
