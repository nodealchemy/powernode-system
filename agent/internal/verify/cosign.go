// Package verify performs the cryptographic checks the agent runs against
// each pulled module artifact before mounting it: cosign signature
// verification (against the platform's pinned Sigstore identity policy)
// and fs-verity root-hash verification (against the digest the platform's
// ModuleArtifact row recorded at build time).
//
// Phase 1 adds the Verifier interface so the reconciler + CLI consumers
// can be unit-tested with stub implementations. The default
// CosignVerifier still shells out to the cosign binary; the embedded
// sigstore-go path is reserved for a follow-up that bundles the
// transitive dep tree carefully.
//
// Reference: Golden Eclipse plan Security Architecture (Supply Chain).
package verify

import (
	"context"
	"errors"
	"fmt"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// Verifier is the interface the reconciler + CLI commands depend on
// for cosign signature verification. Phase 1 ships CosignVerifier as
// the only implementation; the embedded sigstore-go variant lands
// behind a build tag in a follow-up.
type Verifier interface {
	// VerifyBlob returns nil iff the cosign bundle at bundlePath is a
	// valid signature over the contents of blobPath, AND the signing
	// identity matches the verifier's pinned identity/issuer policy.
	VerifyBlob(ctx context.Context, blobPath, bundlePath string) error
}

// CosignVerifier wraps the cosign CLI for blob signature verification.
type CosignVerifier struct {
	Runner mount.Runner
	// IdentityRegexp pins the Sigstore Fulcio identity that signed the
	// module. Production modules built by the M1 CI workflow ship with
	// signatures whose identity is the GitHub/Gitea Actions OIDC token
	// — the regexp typically matches "https://gitea.example.com/.../+ref(.*)".
	IdentityRegexp string
	// IssuerRegexp pins the Sigstore Fulcio issuer (e.g.,
	// "https://token.actions.githubusercontent.com" for GitHub or the
	// Gitea Actions OIDC issuer URL).
	IssuerRegexp string
}

// VerifyBlob runs `cosign verify-blob --bundle <bundlePath> <blobPath>`
// with the configured identity pins. Returns nil on success; non-nil
// error means the signature did not verify or the identity didn't match
// — in either case, the mount package MUST refuse to mount the blob.
func (v *CosignVerifier) VerifyBlob(ctx context.Context, blobPath, bundlePath string) error {
	if v == nil {
		return errors.New("CosignVerifier: nil receiver")
	}
	if blobPath == "" || bundlePath == "" {
		return errors.New("VerifyBlob: blobPath and bundlePath required")
	}
	if v.Runner == nil {
		return errors.New("CosignVerifier: nil Runner")
	}
	args := []string{"verify-blob",
		"--bundle", bundlePath,
		"--certificate-identity-regexp", v.IdentityRegexp,
		"--certificate-oidc-issuer-regexp", v.IssuerRegexp,
		blobPath,
	}
	if err := v.Runner.Run(ctx, "cosign", args...); err != nil {
		return fmt.Errorf("cosign verify-blob: %w", err)
	}
	return nil
}

// AlwaysOK is a Verifier implementation that approves every blob. It
// exists for tests and dev builds where a real signing key isn't
// available. NEVER use in production — the reconciler should always
// be wired with a real CosignVerifier or its embedded equivalent.
type AlwaysOK struct{}

// VerifyBlob always returns nil.
func (AlwaysOK) VerifyBlob(_ context.Context, _, _ string) error { return nil }

