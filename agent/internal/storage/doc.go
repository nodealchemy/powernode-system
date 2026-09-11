// Package storage materializes storage assignments on the agent: network
// mounts (NFS, CIFS / SMB, s3fs object storage), the NFS exports a backend
// peer serves, Samba users, gateway re-exports, ownership fixes, and the
// credential and encryption plumbing each needs.
//
// # How work arrives
//
// The platform dispatches it as agent tasks. runtime/tasks/handlers/storage.go
// decodes each payload and calls one entry point here:
//
//	storage.mount               → Apply
//	storage.unmount             → Unapply
//	storage.exports.apply       → ApplyExports
//	storage.smb_user.apply      → ApplySambaUser
//	storage.gateway.provision   → ProvisionGateway
//	storage.gateway.deprovision → DeprovisionGateway
//	storage.chown               → ApplyChown
//
// The payloads are built server-side by
// extensions/system/server/app/services/system/storage/task_payload_builder.rb;
// types.go mirrors them and validate.go is the one place each is validated.
//
// # Files
//
//   - applier.go — Apply / Unapply: one assignment's mount lifecycle
//   - nfs.go, cifs.go, s3fs.go — the per-filesystem mount steps
//   - exports.go — NFS export table management on a backend peer
//   - smb_user.go — Samba user provisioning
//   - gateway.go — gateway re-exports, for storage that sits behind another peer
//   - credentials.go — fetches a mount's credential from the node API and
//     stages it under MountCredsDir (tmpfs, 0600, never persisted)
//   - encryption.go — fscrypt on a local mount target; LUKS is not
//     implemented and fails the task
//   - systemd.go — .mount unit materialization
//   - chown.go — ownership fixes for an assignment's owner
//
// # Reference
//
// docs/STORAGE_SUBSYSTEM.md in this extension describes the storage data plane.
package storage
