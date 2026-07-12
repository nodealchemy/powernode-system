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

// CosignVerifier wraps the cosign CLI for blob signature verification. It runs
// in one of two modes:
//
//   - Static-key (KeyPath set): `cosign verify-blob --key <KeyPath> --bundle …`.
//     This is what the platform CI uses — Gitea is not on Sigstore Fulcio's
//     trusted-issuer list, so artifacts are signed with a static cosign key
//     (COSIGN_PRIVATE_KEY) and verified against its public half. See the
//     platform's module_oci_ingest_service static-key branch. Used for the
//     boot-image (UKI) upgrade path.
//   - Keyless (KeyPath empty): identity/issuer regexp pins against a Fulcio
//     certificate. Reserved for a future Fulcio-issued signing flow.
type CosignVerifier struct {
	Runner mount.Runner
	// KeyPath, when set, selects static-key verification against the cosign
	// public key at this path (`--key <KeyPath>`). Takes precedence over the
	// keyless identity/issuer pins.
	KeyPath string
	// IdentityRegexp pins the Sigstore Fulcio identity (keyless mode only).
	IdentityRegexp string
	// IssuerRegexp pins the Sigstore Fulcio issuer (keyless mode only).
	IssuerRegexp string
}

// VerifyBlob runs `cosign verify-blob` over blobPath using bundlePath. Returns
// nil only on a valid signature (static-key: signed by KeyPath's private half;
// keyless: signer matches the identity/issuer pins). Any error — bad signature,
// wrong identity, or a MISSING cosign binary — means the caller MUST refuse to
// use the blob (fail closed).
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
	var args []string
	if v.KeyPath != "" {
		// Static-key verification. --insecure-ignore-tlog=true skips the Sigstore
		// transparency-log (Rekor) check, which cosign v3 otherwise performs
		// ONLINE against tuf-repo-cdn.sigstore.dev — unreachable from offline
		// fleet nodes, so verify fails with a hard i/o timeout on every node.
		// With a static --key the signature IS the trust anchor; the tlog is
		// supplementary provenance, not required for trust. (Pair with the CI
		// signing `--tlog-upload=false` so future bundles carry no Rekor entry.)
		args = []string{"verify-blob", "--key", v.KeyPath, "--bundle", bundlePath,
			"--insecure-ignore-tlog=true", blobPath}
	} else {
		if v.IdentityRegexp == "" || v.IssuerRegexp == "" {
			return errors.New("CosignVerifier: no KeyPath and no identity/issuer pins — refusing to verify without a trust anchor")
		}
		args = []string{"verify-blob",
			"--bundle", bundlePath,
			"--certificate-identity-regexp", v.IdentityRegexp,
			"--certificate-oidc-issuer-regexp", v.IssuerRegexp,
			blobPath,
		}
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
