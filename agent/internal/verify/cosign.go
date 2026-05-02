// Package verify performs the cryptographic checks the agent runs against
// each pulled module artifact before mounting it: cosign signature
// verification (against the platform's pinned Sigstore identity policy)
// and fs-verity root-hash verification (against the digest the platform's
// ModuleArtifact row recorded at build time).
//
// Reference: Golden Eclipse plan Security Architecture (Supply Chain).
package verify

import (
	"context"
	"errors"
	"fmt"

	"github.com/powernode/platform/extensions/system/agent/internal/mount"
)

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
	if blobPath == "" || bundlePath == "" {
		return errors.New("VerifyBlob: blobPath and bundlePath required")
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
