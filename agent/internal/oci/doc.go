// Package oci pulls module artifacts from the OCI registry (registry.example.com by
// default) and verifies them before handoff to internal/mount.
//
// Each module artifact is a tar of the composefs lower layer + manifest.json.
// The pull flow:
//
//   1. Resolve the artifact reference from the platform's module manifest
//      (e.g., "registry.example.com/<account>/modules/nginx@sha256:...")
//   2. oras pull — uses the agent's mTLS cert as registry credentials
//   3. Cosign signature verification (see internal/verify) — checks identity
//      regexp + issuer regexp from the module's NodeModuleVersion record
//   4. fs-verity digest verification on the unpacked composefs file
//   5. Return path to the verified artifact for mount.Composefs.Layer to use
//
// # Key types
//
//   Puller        — orchestrates the pull + verify + cache pipeline
//   ArtifactRef   — parsed registry coordinates (registry, repo, digest, tag)
//   Cache         — content-addressed local cache at /var/lib/powernode-agent/oci/
//
// Server-side counterpart: extensions/system/server/app/services/system/
// module_oci_ingest_service.rb handles platform-side ingestion.
package oci
