// Package storage materializes storage assignments on the agent —
// volumes, NFS / SMB / CIFS exports, S3FS mounts, gateway proxies, and
// the encrypted-volume + credential plumbing each needs.
//
// # Materialization flow
//
//	platform → /node_api/storage_assignments → applier.Apply(ctx, assignments)
//	  ↓
//	per-assignment: resolve type → invoke matching driver
//	  - nfs.go        — NFS server export + client mount
//	  - cifs.go       — CIFS / SMB client mount
//	  - smb_user.go   — per-user SMB credential provisioning
//	  - s3fs.go       — s3fs FUSE mount with credentials
//	  - exports.go    — NFS export table management
//	  - gateway.go    — gateway-proxied storage (when storage host
//	                    sits behind another peer)
//	  - encryption.go — LUKS / dm-crypt setup for volume-backed mounts
//	  - credentials.go — per-mount credential retrieval + cache
//	  - systemd.go    — .mount unit materialization
//
// Each driver is a separate file because they have completely
// different external dependencies + tooling. The applier file glues
// them together; types.go defines the shared assignment shapes.
//
// # Reference
//
// Plan S7a/S7b — self-hosted storage via SDWAN + gateway-proxied
// external storage. See:
//
//	docs/USE_CASE_MATRIX.md  use case 9 (storage)
//	docs/runbooks/sdwan-network-setup.md §"Storage attachments"
package storage
