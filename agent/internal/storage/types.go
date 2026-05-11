// Package storage implements the on-node agent's storage assignment
// applier: mount/unmount filesystem assignments, render NFS exports.d
// on backend peers, provision Samba users, configure gateway re-exports
// for Shape 2 (gateway_proxy) deployments, and set up fscrypt/LUKS
// encryption.
//
// Mirrors the server-side payload schemas in
// extensions/system/server/app/services/system/storage/task_payload_builder.rb.
// Schemas MUST stay in sync — drift surfaces as silent NoOps or panics
// in production.
package storage

// MountTask is the payload for command `storage.mount`. Dispatched to
// client nodes when a StorageAssignment becomes mounted.
type MountTask struct {
	AssignmentID        string         `json:"assignment_id"`
	UnitName            string         `json:"unit_name"`
	MountPath           string         `json:"mount_path"`
	Recipe              MountRecipe    `json:"recipe"`
	Options             []string       `json:"options"`
	Credential          CredentialRef  `json:"credential"`
	Encryption          EncryptionSpec `json:"encryption"`
	RequiresWGInterface bool           `json:"requires_wg_interface"`
	WGInterfaceHint     string         `json:"wg_interface_hint"`
}

// MountRecipe is the per-mount-type instruction set built by the
// platform provider's node_mount_recipe(context:).
type MountRecipe struct {
	Type           string   `json:"type"`
	Source         string   `json:"source"`
	Options        []string `json:"options"`
	CredentialKind string   `json:"credential_kind"`
}

// CredentialRef points the agent at /node_api/.../credential where it
// can fetch the actual material via Vault round-trip. The kind tells
// the agent how to materialize the file (e.g. peer_ip_acl needs no
// client-side file; cifs_user_pass needs /run/sdwan/mount-creds/<id>.cred).
type CredentialRef struct {
	ID   string `json:"id"`
	Kind string `json:"kind"`
	URL  string `json:"url"`
}

// EncryptionSpec describes whether and how to encrypt the mount.
type EncryptionSpec struct {
	Mode      string `json:"mode"`
	KeyID     string `json:"key_id,omitempty"`
	KeyURL    string `json:"key_url,omitempty"`
	Algorithm string `json:"algorithm,omitempty"`
}

// UnmountTask is the payload for command `storage.unmount`.
type UnmountTask struct {
	AssignmentID string `json:"assignment_id"`
	UnitName     string `json:"unit_name"`
	MountPath    string `json:"mount_path"`
}

// ExportsApplyTask is dispatched to the backend peer (Shape 1: storage
// host; Shape 2: gateway) to write /etc/exports.d/<account>.exports.
type ExportsApplyTask struct {
	StorageID       string          `json:"storage_id"`
	AccountID       string          `json:"account_id"`
	ExportPath      string          `json:"export_path"`
	DeploymentShape string          `json:"deployment_shape"`
	Action          string          `json:"action,omitempty"` // "grant" (default), "revoke", "reconcile"
	Entries         []ExportsEntry  `json:"entries"`
}

// ExportsEntry is one client peer's grant line in the exports file.
type ExportsEntry struct {
	PeerIP  string   `json:"peer_ip"`
	UID     int      `json:"uid"`
	GID     int      `json:"gid"`
	Options []string `json:"options"`
}

// SmbUserApplyTask drives samba-tool user create/delete/set_password
// on the backend peer.
type SmbUserApplyTask struct {
	StorageID       string `json:"storage_id"`
	AccountID       string `json:"account_id"`
	Action          string `json:"action"` // create | delete | set_password
	Username        string `json:"username"`
	Password        string `json:"password,omitempty"`
	NewPassword     string `json:"new_password,omitempty"`
	DeploymentShape string `json:"deployment_shape"`
	ReShareName     string `json:"re_share_name,omitempty"`
}

// GatewayProvisionTask configures a gateway powernode (Shape 2) to
// mount the upstream NFS once and re-export it on the SDWAN interface.
type GatewayProvisionTask struct {
	StorageID            string   `json:"storage_id"`
	AccountID            string   `json:"account_id"`
	UpstreamSourceHost   string   `json:"upstream_source_host"`
	UpstreamExportPath   string   `json:"upstream_export_path"`
	UpstreamMountOptions []string `json:"upstream_mount_options"`
	ReExportPath         string   `json:"re_export_path"`
	FSID                 string   `json:"fsid"`
	GatewayUnitName      string   `json:"gateway_unit_name"`
}

// GatewayDeprovisionTask tears down a Shape 2 gateway re-export.
type GatewayDeprovisionTask struct {
	StorageID       string `json:"storage_id"`
	ReExportPath    string `json:"re_export_path"`
	GatewayUnitName string `json:"gateway_unit_name"`
}

// CredentialPayload is what the agent fetches from the
// /node_api/storage_assignments/:id/credential endpoint after parsing
// the response envelope.
type CredentialPayload struct {
	Kind     string         `json:"kind"`
	Username string         `json:"username,omitempty"`
	Password string         `json:"password,omitempty"`
	PeerIP   string         `json:"peer_ip,omitempty"`
	UID      int            `json:"uid,omitempty"`
	GID      int            `json:"gid,omitempty"`
	Extra    map[string]any `json:"extra,omitempty"`
}
