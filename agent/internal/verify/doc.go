// Package verify supplies the agent's artifact-integrity primitives: cosign
// blob-signature verification and fs-verity Merkle-root verification.
//
// This file documents WHERE THOSE PRIMITIVES ARE ACTUALLY WIRED, because the
// answer differs per path and the difference is a security property. The API
// itself is documented on the declarations in cosign.go, module.go and
// fsverity.go.
//
// A previous revision of this file described a `Cosign(ctx, ref, identity,
// issuer)` / `FsVerity(path, digest)` / `ModuleArtifact(path, manifest)` API
// and four `ErrCosign*`/`ErrFsVerity*` sentinel error types, and stated "All
// failures abort mount." None of those identifiers has ever existed in this
// package, and the closing claim was false for every module mount. A later
// revision correctly recorded that module mounts were NOT ENFORCED anywhere
// and enumerated why enforcement could not simply be switched on: no signing
// subject a blob verifier could check, no transport, no trust anchor. Those
// prerequisites are now BUILT (below). What has NOT changed — deliberately —
// is the default: enforcement is an operator opt-in, DEFAULT OFF.
//
// # What this package provides
//
//	Verifier               interface — VerifyBlob(ctx, blobPath, bundlePath) error
//	CosignVerifier         real implementation; shells out to `cosign verify-blob`
//	                       static-key mode takes a LIST of trusted keys (KeyPath +
//	                       KeyPaths) and succeeds on the first that verifies
//	AuditVerifier          runs an inner Verifier, REPORTS failures, never refuses
//	AlwaysOK               no-op implementation; VerifyBlob always returns nil
//	NewModuleVerifier      THE constructor: ModuleSigningConfig + Site -> Verifier
//	ModuleSigningConfig    the operator's policy: Mode (off|audit|runtime|all) + KeyPaths
//	FsVerifier             Enable / Digest / VerifyDigest over a local file
//
// CosignVerifier has two modes. Static-key (any key path set) is the one this
// platform uses: its Gitea OIDC issuer is not on Sigstore Fulcio's trusted-
// issuer list, so artifacts are signed with static keys (a Vault-transit key
// or an on-box local key, server-side). Keyless (identity/issuer regexp pins)
// has no signing pipeline behind it here, but is not dead code: `powernode-agent
// verify` still constructs a keyless verifier from operator flags, and the
// server's ingest keeps a keyless fallback for artifacts signed on a genuinely
// Fulcio-trusted CI.
//
// # The chain, end to end
//
// SIGNING SUBJECT. The platform signs the erofs BLOB BYTES with
// `cosign sign-blob --bundle` SERVER-SIDE at publish time
// (System::ModuleSigningService#sign_blob!, via System::ModuleBlobSigner),
// alongside the pre-existing OCI IMAGE signature it pushes to the registry as
// a .sig tag. It does this on every publish path — the Gitea-webhook ingest!,
// the native module-forge ingest_native!, and the platform-CI notify
// (ModulePublicationsController) — after the platform's own ingest-time
// verification of the image signature, so the blob bundle attests "the
// platform verified and re-signed exactly these bytes". A backfill
// (System::ModuleBlobSigner.backfill! / rake system:modules:sign_blobs) signs
// already-published artifacts the same way. The signing key never leaves
// Vault (or the 0600 local key file); this agent never sees it.
//
// PERSISTENCE. The bundle lives on NodeModuleVersion.artifacts JSONB as
// erofs.cosign_blob_bundle_b64 — the same row and the same hop the fs-verity
// root takes, and the store the node-facing serializer reads. (The older
// ModuleArtifact.cosign_bundle COLUMN is untouched and still holds, on the
// ingest! path, the stdout of `cosign verify --output json` — a verification
// REPORT, not a bundle; `scope :signed` therefore still counts reports.)
//
// TRANSPORT. The bundle rides the module manifest (modules#show,
// cosign_bundle_b64) exactly as fsverity_root_hash does — manifest.Manifest ->
// mount.Module -> the oci.ModuleArtifactRef handed to Puller.Pull, which
// writes it beside the blob as <digest>.cosign-bundle. No second fetch; the
// boot-LKG snapshot stores the manifest verbatim, so a fallback boot carries
// its signatures. The download envelope (modules#download) carries the same
// field plus the platform's trusted public keys, for FetchManifest consumers.
// oci.TestPullMaterialisesInlineCosignBundle pins the bytes.
//
// TRUST ANCHOR. The platform serves its trusted module-signing PUBLIC keys
// (System::ModuleSigningTrust.public_keys — the list ingest verifies against:
// the Vault/local signing key plus any legacy static key) at
// /node_api/modules/signing_keys. runtime.ResolveModuleVerifier fetches and
// caches them under /persist (content-addressed .pub files), or uses the
// operator's PINNED key paths instead when KEYS= is set. Pinned is stronger:
// a key that arrives over the same channel as the blob bounds the control to
// "the platform I can reach is the platform I enrolled with" — the same bound
// the boot path's inline cosign_public_key has. Say so when choosing.
//
// # Where verification is enforced
//
// Boot images (UKI), via the upgrade_boot_image task — ENFORCED, unconditionally.
// bootupgrade.Apply constructs a real CosignVerifier in static-key mode and
// refuses the upgrade on any error; the task payload carries cosign_bundle_b64
// and cosign_public_key inline and the platform refuses to dispatch without
// either.
//
// Module mounts — ENFORCEABLE, DEFAULT OFF. Reconciler.mountModuleArtifact
// calls cfg.Verifier.VerifyBlob before mounting and fails closed on error. All
// three production construction sites obtain that Verifier from
// runtime.ResolveModuleVerifier for their own Site:
//
//	runtime/service.go            SiteService — the long-lived 60s reconcile loop
//	runtime/compose.go            SiteBoot    — NewPivotComposerAt, the direct_kernel boot composer
//	cli/reconciler_factory.go     SiteCLI     — BuildReconciler, for attach/update/sync/detach
//
// and the resolver returns AlwaysOK unless the operator has set a mode. The
// mode ladder, by blast radius (each rung adds a site whose refusal is worse):
//
//	off      AlwaysOK everywhere; no trust anchor, no fetch. THE DEFAULT.
//	audit    verify everywhere, refuse nowhere; each would-be refusal is
//	         reported as "verify:module_signature_audit". The MEASURE step.
//	runtime  enforce on SiteService and SiteCLI (recoverable: the mount is
//	         refused, reported, and retried next tick or next command);
//	         audit on SiteBoot.
//	all      enforce on SiteBoot too. A module without a valid bundle then
//	         makes the node UNBOOTABLE, on nodes that typically cannot be
//	         re-provisioned. Only after audit is clean fleet-wide.
//
// Policy source: /persist/etc/powernode/module-signing.conf (MODE=, KEYS=),
// overridden by POWERNODE_MODULE_SIGNING_MODE / POWERNODE_MODULE_SIGNING_KEYS,
// overridden for the service by --module-signing-mode / --module-signing-key.
// An unknown mode is an error at construction, never coerced to off or all.
// An enforcing site with no trust anchor refuses to construct (the service
// does not start; an `all` boot refuses to compose) — loudly, once — while a
// non-enforcing site degrades to AlwaysOK and reports. Operator runbook:
// docs/runbooks/module-signature-verification.md.
//
// `powernode-agent verify --key <pub>` constructs its verifier through the
// same NewModuleVerifier the sites use (enforcing, SiteCLI), so what the CLI
// green-lights is what an enforcing node would accept; the keyless flags keep
// their own construction.
//
// # Where verification is NOT enforced
//
// Every module mount on a node whose operator has not opted in — i.e. every
// node today. The only integrity control on such a mount is the sha256 blob
// digest checked in oci.Puller.streamToFile, supplied by the control plane
// over the same channel as the blob: it detects corruption and a substituted
// blob from a compromised artifact store; it does not establish provenance
// and does not survive a compromised or impersonated control plane.
//
// The promote gate, System::Fleet::PromotionCriteria.evaluate, consults
// signature state only when module_promotion_require_signature is set (the
// same module -> account -> site cascade as its other thresholds); by default
// it gates promotion on oci_digest presence, running-instance count, liveness
// and dwell time only.
//
// ReconcilerConfig.Fsverity is nil by default at every site, so the fs-verity
// arm of the same gate is skipped. The fsverity_root_hash channel is complete
// on the native (module-forge) path, on the ingest! path since push.sh stamps
// io.powernode.fsverity_root_hash (IMP-e2c2da99b4b5), and on the platform-CI
// notify path; any publisher that ships neither leaves a nil root, and
// enabling Fsverity refuses exactly those mounts (fail closed). Note what
// fs-verity is worth here even when populated: VerifyDigest compares a hash
// that arrives over the SAME channel as oci_digest, over the SAME bytes Pull
// already sha256'd; its incremental value is FsVerifier.Enable turning on
// kernel open-time enforcement, and that call tolerates EOPNOTSUPP.
//
// # What a signed mount does and does not prove
//
// A verified bundle proves the erofs bytes about to be mounted were signed by
// a holder of one of the trusted keys — the platform's Vault-transit or local
// signing key — after that platform verified the builder's image signature.
// It does NOT prove the manifest the bytes were mounted under (services,
// users, policy) is what the platform intended: the manifest is unsigned and
// travels the same channel. It does NOT bind the bundle to a module identity:
// a bundle over module A's bytes verifies module A's bytes wherever they are
// presented. Both are known, unbuilt extensions.
//
// Do NOT introduce a second verifier or a parallel mount path: every mount
// funnels through Reconciler.mountModuleArtifact, and every site's verifier
// through ResolveModuleVerifier. runtime.TestModuleMountVerifierWiringIsConfigDriven
// and TestConcreteVerifierSitesAreEnumerated pin both.
//
// References: cosign (sigstore/cosign),
// fs-verity (kernel.org/doc/html/latest/filesystems/fsverity.html).
package verify
