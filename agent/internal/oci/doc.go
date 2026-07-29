// Package oci fetches module artifacts from the PLATFORM and verifies them
// before handoff to internal/mount.
//
// Despite the package name, this code does not speak the OCI registry
// protocol. There is no registry client in the agent — no /v2/ manifest or
// blob calls anywhere in the binary. The name is historical.
//
// # This file used to describe a completely different design
//
// Until 2026-07-29 this doc described the pre-Phase-1 flow: resolve
// "registry.example.com/<account>/modules/<name>@sha256:..." and shell out to
// `oras pull` using the agent's mTLS cert as registry credentials. None of it
// is true any more — pull.go's own doc even states "No `oras` shell
// dependency" — so the package carried two contradictory package comments and
// this was the stale one.
//
// It was not harmless. Read together with a stale "when set, prefer the OCI
// registry path" note on ModuleArtifactRef.OCIRef, it led a 2026-07-29
// investigation to conclude that every fleet node needed egress to the
// registry and that module delivery did not benefit from the platform's blob
// cache. Both were false. If a registry path is ever reintroduced, change the
// code and these comments in the same commit.
//
// # Actual flow
//
//  1. GET /api/v1/system/node_api/modules/:id/download over the agent's mTLS
//     transport — returns the artifact envelope (digest, size, download_url,
//     and an informational oci_ref).
//  2. Stream the bytes from download_url, which points at the platform's
//     digest-addressed proxy (Api::V1::System::NodeApi::FilesController ->
//     System::OciBlobProxyService). sha256 is computed inline; a mismatch
//     deletes the temp file and fails the pull, so proxying grants the
//     platform no ability to substitute bytes.
//  3. Cosign signature verification (internal/verify) against the identity +
//     issuer regexps from the module's NodeModuleVersion record.
//  4. fs-verity root verification on the erofs file.
//  5. Return the verified path for mount.MountModule to loop-mount.
//
// Fetching through the platform rather than the registry is deliberate: one
// egress path per node, one fleet-wide cache (the first node to want a digest
// pays the upstream fetch, the rest are served from the platform's disk), and
// a registry outage degrades instead of blocking whenever the platform already
// holds the blob.
//
// # Key types
//
//	Puller             — orchestrates fetch + verify + cache
//	ModuleArtifactRef  — the platform's artifact envelope (see pull.go)
//
// Server-side counterparts: FilesController + OciBlobProxyService serve the
// bytes; module_oci_ingest_service.rb handles platform-side ingestion from the
// registry.
package oci
