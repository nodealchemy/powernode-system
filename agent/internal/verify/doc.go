// Package verify supplies the agent's artifact-integrity primitives: cosign
// blob-signature verification and fs-verity Merkle-root verification.
//
// This file documents WHERE THOSE PRIMITIVES ARE ACTUALLY WIRED, because the
// answer differs per path and the difference is a security property. The API
// itself is documented on the declarations in cosign.go and fsverity.go.
//
// A previous revision of this file described a `Cosign(ctx, ref, identity,
// issuer)` / `FsVerity(path, digest)` / `ModuleArtifact(path, manifest)` API
// and four `ErrCosign*`/`ErrFsVerity*` sentinel error types, and stated "All
// failures abort mount." None of those identifiers has ever existed in this
// package, and the closing claim was false for every module mount. It is
// recorded here so the correction is not silently re-lost.
//
// # What this package provides
//
//	Verifier               interface — VerifyBlob(ctx, blobPath, bundlePath) error
//	CosignVerifier         real implementation; shells out to `cosign verify-blob`
//	AlwaysOK               no-op implementation; VerifyBlob always returns nil
//	FsVerifier             Enable / Digest / VerifyDigest over a local file
//
// CosignVerifier has two modes. Static-key (KeyPath set) is the one this
// platform uses: its Gitea OIDC issuer is not on Sigstore Fulcio's trusted-
// issuer list, so artifacts are signed with a static cosign key. Keyless
// (identity/issuer regexp pins) is reserved for a future Fulcio-issued flow
// and is not reachable from any signing pipeline that exists today.
//
// # Where verification is enforced
//
// Boot images (UKI), via the upgrade_boot_image task — ENFORCED.
// bootupgrade.Apply constructs a real CosignVerifier in static-key mode and
// refuses the upgrade on any error. It can do so because the task payload
// carries both halves of the trust decision inline: cosign_bundle_b64 and
// cosign_public_key, written to the stage dir before the verify. The platform
// side refuses to dispatch the task at all when either is absent. That inline
// push IS the boot path's trust-material transport, and it is the seam the
// module path lacks.
//
// # Where verification is NOT enforced
//
// Module mounts — NOT ENFORCED, on every path. Reconciler.mountModuleArtifact
// calls cfg.Verifier.VerifyBlob before mounting and fails closed on error, so
// the gate itself is correct. It is handed a no-op. All three production
// construction sites pass AlwaysOK, independently:
//
//	runtime/service.go            the long-lived 60s reconcile loop
//	runtime/compose.go            NewPivotComposerAt, the direct_kernel boot composer
//	cli/reconciler_factory.go     BuildReconciler, for attach/update/sync/detach
//
// ReconcilerConfig.Fsverity is additionally nil by default, so the fs-verity
// arm of the same gate is skipped too. The only integrity control on a module
// mount today is the sha256 blob digest checked in oci.Puller.streamToFile.
// That digest is supplied by the control plane over the same channel as the
// blob, so it detects corruption and a substituted blob from a compromised
// artifact store; it does not establish provenance and does not survive a
// compromised or impersonated control plane.
//
// There is no compensating control upstream: Fleet::PromotionCriteria.evaluate
// gates promotion on oci_digest presence, running-instance count and dwell
// time, and never consults signature state.
//
// # Why enforcement cannot simply be switched on
//
// Swapping AlwaysOK for a real CosignVerifier at those three sites would not
// tighten a control. It would refuse every module mount on every node, because
// THE AGENT NEVER OBTAINS A MODULE SIGNATURE BUNDLE AT ALL:
//
//   - oci.Puller.Pull returns a bundlePath that it constructs as a filename and
//     never fetches. Its only network read is the erofs blob. Nothing in this
//     binary writes a module cosign bundle.
//   - The platform's /node_api/modules/:id/download envelope carries no
//     signature field for one to come from, and oci.ModuleArtifactRef has no
//     field that could receive one. (The action's own comment describes its
//     `oci` block as supplying "cosign material"; the block it renders is
//     ref / digest / fsverity_root_hash / size_bytes.)
//   - No trust anchor reaches the node for modules. The static public key the
//     platform signs with is server-side configuration
//     (system.module_signing.trusted_public_keys); no node_api endpoint serves
//     it, and no reconciler construction site sets KeyPath.
//   - This binary has no OCI registry client, so the signature that DOES exist
//     in the registry for natively-built modules is unreachable from here.
//
// So module signature enforcement is blocked on a missing TRANSPORT, not on a
// configuration flag and not on the population of signed artifacts. See
// oci.TestPullFetchesNoCosignBundle, which pins that gap and is written to fail
// once a transport lands.
//
// fs-verity is a different and much smaller gap: fsverity_root_hash has a
// working wire channel end to end (published by the module build handler,
// carried on the manifest, read into mount.Module.FsverityRoot), and the gate
// already fails closed when it is configured but a module publishes no root
// hash. Enabling it is a configuration decision gated on population, which is
// exactly the kind of decision the cosign arm cannot yet be reduced to.
//
// # Prerequisites, in order
//
// Each step is a prerequisite for the next; none is optional, and no step
// should be taken as license to flip enforcement before the last one.
//
//  1. PERSIST the bundle. The native build path signs upstream
//     (ModuleSigningService.sign!) and re-verifies it (the R6 gate) but then
//     stores cosign_bundle: nil on the artifact row, so the signature it just
//     made anchors nothing durable. Persist what R6 verified.
//  2. SERVE it. Add a signature field to the node_api download envelope, or a
//     sibling bundle endpoint, and a field on oci.ModuleArtifactRef to carry it.
//  3. FETCH it. Have oci.Puller.Pull retrieve and write the bundle it already
//     names, alongside the blob.
//  4. DELIVER a trust anchor. Modules need the boot path's equivalent of an
//     inline cosign_public_key, or an on-disk pinned key the reconciler can
//     point KeyPath at. Sourcing it from the same channel as the blob bounds
//     what the control is worth — say so explicitly when choosing.
//  5. MEASURE. Report, per node and per module, what a real verifier WOULD
//     have refused, and only then decide.
//  6. FLIP, per path, with an operator decision on each — the three sites have
//     different blast radii. compose.go runs at boot on nodes that typically
//     cannot be re-provisioned; a fail-closed verifier there turns an unsigned
//     module into an unbootable node.
//
// Steps 1-4 are platform and transport work. Do NOT introduce a second
// verifier or a parallel mount path to work around their absence.
//
// References: cosign (sigstore/cosign),
// fs-verity (kernel.org/doc/html/latest/filesystems/fsverity.html).
package verify
