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
// (identity/issuer regexp pins) has no signing pipeline behind it here — the
// platform's CI cannot produce a Fulcio-issued signature — but it is not dead
// code: `powernode-agent verify` constructs a keyless verifier from operator
// flags (and, in fact, offers no --key flag, so it cannot check a
// statically-signed artifact at all), and the server's ingest keeps a keyless
// verification fallback for artifacts signed on a genuinely Fulcio-trusted CI.
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
// There is no compensating control upstream: the promote gate,
// System::Fleet::PromotionCriteria.evaluate,
// gates promotion on oci_digest presence, running-instance count and dwell
// time, and never consults signature state.
//
// # Why enforcement cannot simply be switched on
//
// Swapping AlwaysOK for a real CosignVerifier at those three sites would not
// tighten a control. It would refuse every module mount on every node. There
// are two independent reasons, and the second is the deeper one.
//
// FIRST, no transport delivers signature material to the node:
//
//   - oci.Puller.Pull returns a bundlePath that it constructs as a filename and
//     never fetches. Its only network read is the erofs blob. Nothing in this
//     binary writes a module cosign bundle.
//   - The platform's /node_api/modules/:id/download envelope carries no
//     signature field, and oci.ModuleArtifactRef has no field that could
//     receive one.
//   - No trust anchor reaches the node for modules. The static public key the
//     platform signs with is server-side configuration
//     (system.module_signing.trusted_public_keys); no node_api endpoint serves
//     it, and no reconciler construction site sets KeyPath.
//   - This binary has no OCI registry client.
//
// SECOND — and this is why "just plumb the bundle through" is not the fix —
// THE SIGNATURE THIS PLATFORM PRODUCES IS THE WRONG SUBJECT AND THE WRONG
// FORMAT for the Verifier interface:
//
//   - Modules are signed with `cosign sign --key <k> <ref@digest>`, an OCI
//     IMAGE signature over a manifest digest, pushed to the registry as a .sig
//     tag (ModuleSigningService#cosign_sign!, and the platform-modules CI
//     workflow). There is no `cosign sign-blob` over the erofs bytes anywhere
//     in the module pipeline. Disk images and UKIs DO get blob bundles, which
//     is exactly why the boot path works and this one cannot.
//   - Verifier.VerifyBlob is `cosign verify-blob --bundle` over a LOCAL FILE.
//     An image signature cannot satisfy it, no matter how it is transported.
//   - The `cosign_bundle` column that the webhook ingest path does populate is
//     not a signature bundle either: it is the stdout of
//     `cosign verify --output json`, i.e. a verification REPORT
//     (ModuleOciIngestService, OrasOciAdapter#verify_signature). Serving that
//     to a node would still fail verify-blob. So ModuleArtifact's `scope
//     :signed` selects rows whose column content is not usable as a signature.
//
// So enforcement is blocked on a missing SIGNING SUBJECT plus a missing
// transport — not on a configuration flag, and not on the population of signed
// artifacts. See oci.TestPullFetchesNoCosignBundle, which pins the transport
// half and is written to fail once a transport lands.
//
// fs-verity is a smaller gap in mechanism but is NOT merely a config flip
// either, and an earlier revision of this file overstated it. The channel is
// complete only on the native (module-forge) publish path, where the build
// handler's fsverity_root reaches ModuleArtifact via ingest_native!. The other
// path — ingest!, taken whenever the processor is called without native_build,
// which includes the Gitea CI publish — reads the root hash from an OCI
// annotation io.powernode.fsverity_root_hash that only the module-repo TEMPLATE
// workflow emits. Neither scripts/module-build/push.sh nor the platform-modules
// CI workflow sets it, and the latter computes the root and sends it in its
// notify payload where the processor then discards it. Those modules therefore
// carry a nil root hash, and enabling Fsverity would hit the fail-closed branch
// below and refuse exactly those mounts.
//
// Note also what fs-verity is worth here even when populated: VerifyDigest
// compares a hash that arrives over the SAME control-plane channel as
// oci_digest, over the SAME bytes Pull already sha256'd. Its only incremental
// value is FsVerifier.Enable turning on kernel open-time enforcement — and that
// call tolerates EOPNOTSUPP, which is what a filesystem without the verity
// feature returns. On such a filesystem the check degrades to a redundant
// second content hash.
//
// # Prerequisites, in order
//
// Each step is a prerequisite for the next; none is optional, and no step
// should be taken as license to flip enforcement before the last one.
//
//  1. DECIDE THE SUBJECT. Either add a `cosign sign-blob --bundle` step over
//     the erofs bytes to the module pipeline — the disk-image workflow already
//     does this and is the model — or keep the image signature and give the
//     node an image-signature verifier plus a registry client, which is a much
//     larger change and grants every node registry egress. Until this is
//     settled, nothing downstream can be built, and the existing cosign_bundle
//     column cannot be reused because it holds a verify report.
//  2. PERSIST the resulting bundle on the artifact row. Note that
//     ingest_native! currently writes cosign_bundle: nil even when its R6 gate
//     verified a signature, so the native path records nothing at all.
//  3. SERVE it: a signature field on the node_api download envelope or a
//     sibling endpoint, plus a field on oci.ModuleArtifactRef to carry it.
//  4. FETCH it: have oci.Puller.Pull retrieve and write the bundle it names.
//  5. DELIVER a trust anchor. Modules need the boot path's equivalent of an
//     inline cosign_public_key, or an on-disk pinned key the reconciler can
//     point KeyPath at. Sourcing it from the same channel as the blob bounds
//     what the control is worth — say so explicitly when choosing. (The boot
//     path has this property too: its key rides the task record, so anyone who
//     can write the task supplies both halves.)
//  6. MEASURE. Report, per node and per module, what a real verifier WOULD
//     have refused, and only then decide.
//  7. FLIP, per path, with an operator decision on each — the three sites have
//     different blast radii. compose.go runs at boot on nodes that typically
//     cannot be re-provisioned; a fail-closed verifier there turns an unsigned
//     module into an unbootable node.
//
// Steps 1-5 are pipeline, platform and transport work. Do NOT introduce a
// second verifier or a parallel mount path to work around their absence.
//
// References: cosign (sigstore/cosign),
// fs-verity (kernel.org/doc/html/latest/filesystems/fsverity.html).
package verify
