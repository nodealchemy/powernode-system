// Package verify validates module artifacts before mount: cosign keyless
// signatures (Sigstore Fulcio) + fs-verity digests of composefs lower layers.
//
// Splits into two sub-flows:
//
//   - Cosign: checks the artifact's signature against the per-module trust
//     pin (cosign_identity_regexp + cosign_issuer_regexp from the manifest).
//     Keyless verification — no long-lived signing keys; certs are ephemeral
//     OIDC-bound.
//
//   - fs-verity: verifies the composefs lower layer's hash matches the
//     digest committed at publication time (NodeModuleVersion.composefs_digest).
//     This is the runtime-tamper-evident layer — kernel checks every read.
//
// # Key functions
//
//   Cosign(ctx, ref, identityRegexp, issuerRegexp) error
//   FsVerity(path string, expectedDigest string) error
//   ModuleArtifact(path string, manifest ModuleManifest) error  // both at once
//
// # Failure modes
//
// Returns specific error types:
//
//   ErrCosignIdentityMismatch   — signed by an unexpected publisher
//   ErrCosignSignatureMissing   — artifact unsigned
//   ErrFsVerityDigestMismatch   — kernel-computed digest != committed digest
//   ErrFsVeritySupportMissing   — kernel doesn't support fs-verity (rare; pre-5.4 kernels)
//
// All failures abort mount; the agent reports phase=error to the platform.
//
// References: cosign (sigstore/cosign), fs-verity (kernel.org/doc/html/latest/filesystems/fsverity.html).
package verify
