package storage

import (
	"fmt"

	"github.com/nodealchemy/powernode-system/agent/internal/taskguard"
)

// Validation for every storage.* task payload lives HERE and nowhere else.
//
// Each payload type carries one Validate method, and each of the SEVEN task
// entry points — Apply, Unapply, ApplyExports, ApplySambaUser,
// ProvisionGateway, DeprovisionGateway, ApplyChown — calls it once, first,
// before any side effect. Those seven are exactly the branches of
// handlers.StorageHandler.Execute, and handlers is this package's only
// importer.
//
// Everything else the drivers reach — mountNFS, mountCIFS, mountObject,
// setupEncryption, writeMountUnit, startMountUnit, stopAndRemoveMountUnit —
// is UNEXPORTED, so "the exported surface is exactly the validated entry
// points" is enforced by the compiler rather than asserted by this comment. It
// used to be asserted, and it was wrong: mountNFS and friends take a full
// *MountTask and do not validate, and were only safe because Apply happened to
// run first.
//
// The unexported primitives deliberately do NOT re-check: a second guard on
// the same field would make it impossible to tell, from a failing test, which
// rule is actually doing the work.
//
// See package taskguard for why this is enforced at the agent rather than only
// at the control plane. In short: the agent performs the privileged operation,
// so the agent is where the field has to be true.
//
// mountUnitSuffix — the platform's only producer of a storage unit name,
// System::Storage::TaskPayloadBuilder, emits "powernode-storage-<path>.mount"
// and "powernode-storage-gw-<id>.mount". Nothing legitimate produces a
// ".service", and the suffix restriction is what keeps a unit body the caller
// influenced from being started as one.
const mountUnitSuffix = ".mount"

// mountUnitPrefix mirrors System::Storage::TaskPayloadBuilder::MOUNT_UNIT_PREFIX.
// Both producers stamp it — systemd_unit_for and the two gateway payloads —
// so requiring it costs nothing and closes the case the suffix rule alone
// leaves open: `persist.mount` and `sysroot.mount` are real units on these
// nodes, they end in ".mount", and stopping or deleting one takes out the
// agent's own durable state.
const mountUnitPrefix = "powernode-storage-"

// Validate checks every MountTask field that reaches a root actuator: the unit
// filename, the mount target, and every value interpolated into the rendered
// unit body.
func (t *MountTask) Validate() error {
	if t == nil {
		return fmt.Errorf("storage.mount: %w: nil task", taskguard.ErrRefused)
	}
	if err := taskguard.Identifier("assignment_id", t.AssignmentID); err != nil {
		return err
	}
	if err := taskguard.UnitName("unit_name", t.UnitName, mountUnitSuffix); err != nil {
		return err
	}
	if err := taskguard.NamePrefix("unit_name", t.UnitName, mountUnitPrefix); err != nil {
		return err
	}
	if err := taskguard.TargetPath("mount_path", t.MountPath); err != nil {
		return err
	}
	// Options and the recipe's own options are joined with "," straight into
	// the unit body's Options= line.
	if err := taskguard.ConfigTokens("options", t.Options); err != nil {
		return err
	}
	if err := taskguard.ConfigTokens("recipe.options", t.Recipe.Options); err != nil {
		return err
	}
	// Type= and What= — interpolated with the same unescaped fmt.Sprintf.
	if err := taskguard.ConfigToken("recipe.type", t.Recipe.Type); err != nil {
		return err
	}
	if err := taskguard.ConfigToken("recipe.source", t.Recipe.Source); err != nil {
		return err
	}
	// Requires=/After= are only rendered when the flag is set, but validate
	// the hint whenever it is present so a later render cannot pick up an
	// unchecked value.
	//
	// An EMPTY hint with requires_wg_interface set is legal and must stay
	// legal. TaskPayloadBuilder#requires_wg? returns true for every non-object
	// recipe while #wg_interface_hint returns nil whenever sdwan_network_id is
	// nil — which is the supported LAN-fallback shape, and the association is
	// optional with on_delete: :nullify. renderMountUnit already omits the
	// dependency in that case. An earlier revision of this file refused the
	// combination on the theory that a mount needing the tunnel should not
	// fire without it; that is a mount-ordering opinion, not a trust-boundary
	// rule, and it would have put every LAN-fallback assignment into permanent
	// reconcile backoff.
	if t.WGInterfaceHint != "" {
		if err := taskguard.ConfigToken("wg_interface_hint", t.WGInterfaceHint); err != nil {
			return err
		}
	}
	// Credential.ID becomes a filename under /run/sdwan/mount-creds and, via
	// credentials=/passwd_file=, a value inside the unit body. For the recipes
	// that stage a credential file it must be PRESENT, not merely well-formed:
	// an empty id collapses every assignment onto the same predictable
	// ".cred" / ".passwd-s3fs" / ".gcs.json" / ".rclone.conf" name, so one
	// tenant's secret overwrites another's and the unit then mounts with it.
	if credentialFileRecipes[t.Recipe.Type] || t.Credential.ID != "" {
		if err := taskguard.Identifier("credential.id", t.Credential.ID); err != nil {
			return err
		}
	}
	if t.Credential.URL != "" {
		if err := taskguard.PlatformPath("credential.url", t.Credential.URL); err != nil {
			return err
		}
	}
	if t.Encryption.KeyURL != "" {
		if err := taskguard.PlatformPath("encryption.key_url", t.Encryption.KeyURL); err != nil {
			return err
		}
	}
	return nil
}

// credentialFileRecipes are the recipe types whose driver stages a credential
// or config file named after Credential.ID (cifs.go, s3fs.go). nfs4/nfs use a
// peer-IP ACL and legitimately carry no credential id.
var credentialFileRecipes = map[string]bool{
	"cifs": true, "s3fs": true, "gcsfuse": true, "rclone": true,
}

// Validate checks the fields stopAndRemoveMountUnit acts on. mount_path is not
// used by the unmount path today; it is validated anyway so the payload cannot
// carry an unchecked value into a future consumer.
func (t *UnmountTask) Validate() error {
	if t == nil {
		return fmt.Errorf("storage.unmount: %w: nil task", taskguard.ErrRefused)
	}
	if err := taskguard.Identifier("assignment_id", t.AssignmentID); err != nil {
		return err
	}
	if err := taskguard.UnitName("unit_name", t.UnitName, mountUnitSuffix); err != nil {
		return err
	}
	if err := taskguard.NamePrefix("unit_name", t.UnitName, mountUnitPrefix); err != nil {
		return err
	}
	if t.MountPath != "" {
		if err := taskguard.TargetPath("mount_path", t.MountPath); err != nil {
			return err
		}
	}
	return nil
}

// exportsActions is the set ApplyExports understands; "" means grant.
var exportsActions = map[string]bool{"": true, "grant": true, "revoke": true, "reconcile": true}

// Validate checks the exports payload. Both the FILENAME (built from
// account_id and storage_id) and the CONTENT (export path, peer address,
// options, and the values spliced into the header comments) are attacker-
// reachable, so both are covered here.
func (t *ExportsApplyTask) Validate() error {
	if t == nil {
		return fmt.Errorf("storage.exports.apply: %w: nil task", taskguard.ErrRefused)
	}
	// These two are formatted into the exports FILENAME under /etc/exports.d.
	if err := taskguard.Identifier("storage_id", t.StorageID); err != nil {
		return err
	}
	if err := taskguard.Identifier("account_id", t.AccountID); err != nil {
		return err
	}
	if err := taskguard.TargetPath("export_path", t.ExportPath); err != nil {
		return err
	}
	// Only rendered into the file's header comment, so an absent value is
	// harmless; a value carrying a newline is not.
	if t.DeploymentShape != "" {
		if err := taskguard.Identifier("deployment_shape", t.DeploymentShape); err != nil {
			return err
		}
	}
	if !exportsActions[t.Action] {
		return fmt.Errorf("storage.exports.apply: %w: action: unknown action %q", taskguard.ErrRefused, t.Action)
	}
	for i, e := range t.Entries {
		if err := taskguard.PeerAddress(fmt.Sprintf("entries[%d].peer_ip", i), e.PeerIP); err != nil {
			return err
		}
		if err := taskguard.ConfigTokens(fmt.Sprintf("entries[%d].options", i), e.Options); err != nil {
			return err
		}
		if e.UID < 0 || e.GID < 0 {
			return fmt.Errorf("storage.exports.apply: %w: entries[%d]: uid/gid must not be negative", taskguard.ErrRefused, i)
		}
	}
	return nil
}

// Validate checks the samba payload. samba-tool is invoked without a shell, so
// the exposure is argv rather than metacharacters: a username or password that
// begins with a dash becomes an OPTION to samba-tool. Passwords are checked
// with the value-free rule so a refusal never lands the secret in a task's
// error_message.
func (t *SmbUserApplyTask) Validate() error {
	if t == nil {
		return fmt.Errorf("storage.smb_user.apply: %w: nil task", taskguard.ErrRefused)
	}
	if err := taskguard.Identifier("storage_id", t.StorageID); err != nil {
		return err
	}
	if err := taskguard.Identifier("account_id", t.AccountID); err != nil {
		return err
	}
	if err := taskguard.Identifier("username", t.Username); err != nil {
		return err
	}
	// An empty password is not merely unvalidated, it is a live weak
	// credential: smb_user.go passes it positionally, so `samba-tool user
	// create <user> ""` provisions a share principal with no password.
	if t.Action == "create" || t.Password != "" {
		if err := taskguard.Secret("password", t.Password); err != nil {
			return err
		}
	}
	if t.Action == "set_password" && t.NewPassword == "" && t.Password == "" {
		return fmt.Errorf("storage.smb_user.apply: %w: new_password: required for set_password", taskguard.ErrRefused)
	}
	if t.NewPassword != "" {
		if err := taskguard.Secret("new_password", t.NewPassword); err != nil {
			return err
		}
	}
	if t.ReShareName != "" {
		if err := taskguard.Identifier("re_share_name", t.ReShareName); err != nil {
			return err
		}
	}
	return nil
}

// Validate checks the gateway provision payload.
//
// upstream_export_path uses AbsPath rather than TargetPath on purpose: it names
// a path on the REMOTE NFS server, so the local critical-root denylist does not
// apply to it. re_export_path is local — it is mkdir'd, mounted over and
// exported — so it gets the full TargetPath rule.
func (t *GatewayProvisionTask) Validate() error {
	if t == nil {
		return fmt.Errorf("storage.gateway.provision: %w: nil task", taskguard.ErrRefused)
	}
	if err := taskguard.Identifier("storage_id", t.StorageID); err != nil {
		return err
	}
	if err := taskguard.Identifier("account_id", t.AccountID); err != nil {
		return err
	}
	if err := taskguard.Host("upstream_source_host", t.UpstreamSourceHost); err != nil {
		return err
	}
	if err := taskguard.AbsPath("upstream_export_path", t.UpstreamExportPath); err != nil {
		return err
	}
	if err := taskguard.ConfigTokens("upstream_mount_options", t.UpstreamMountOptions); err != nil {
		return err
	}
	if err := taskguard.TargetPath("re_export_path", t.ReExportPath); err != nil {
		return err
	}
	// FSID is spliced into the /etc/exports re-export line.
	if err := taskguard.Identifier("fsid", t.FSID); err != nil {
		return err
	}
	if err := taskguard.UnitName("gateway_unit_name", t.GatewayUnitName, mountUnitSuffix); err != nil {
		return err
	}
	return taskguard.NamePrefix("gateway_unit_name", t.GatewayUnitName, mountUnitPrefix)
}

// Validate checks the gateway deprovision payload — the same unit-name and
// path exposure as provision, on the teardown side.
func (t *GatewayDeprovisionTask) Validate() error {
	if t == nil {
		return fmt.Errorf("storage.gateway.deprovision: %w: nil task", taskguard.ErrRefused)
	}
	if err := taskguard.Identifier("storage_id", t.StorageID); err != nil {
		return err
	}
	if err := taskguard.TargetPath("re_export_path", t.ReExportPath); err != nil {
		return err
	}
	if err := taskguard.UnitName("gateway_unit_name", t.GatewayUnitName, mountUnitSuffix); err != nil {
		return err
	}
	return taskguard.NamePrefix("gateway_unit_name", t.GatewayUnitName, mountUnitPrefix)
}

// Validate checks the chown payload.
//
// This SUPERSEDES the two-value guard that used to live in ApplyChown, which
// refused exactly "" and "/". "/etc" with old_uid 0 passed it and handed the
// node's configuration tree to an unprivileged uid, as root, recursively.
//
// callback_path is deliberately NOT checked here. ApplyChown cannot bind it:
// the handler POSTs to it whether or not this function refuses (see
// postChownCompletion), so a guard placed here would render a refusal and the
// callback would still go out — to the caller-named host, carrying the
// refusal text. The rule therefore lives at the function that performs the
// POST, which is the only place that can actually withhold it.
func (t *ChownTask) Validate() error {
	if t == nil {
		return fmt.Errorf("storage.chown: %w: nil task", taskguard.ErrRefused)
	}
	// Correlation only — it rides the callback body, never an actuator — so
	// an absent value is legal. A value carrying control characters is not.
	if t.StorageAssignmentID != "" {
		if err := taskguard.Identifier("storage_assignment_id", t.StorageAssignmentID); err != nil {
			return err
		}
	}
	if err := taskguard.TargetPath("mount_path", t.MountPath); err != nil {
		return err
	}
	if t.OldUID < 0 || t.OldGID < 0 || t.NewUID < 0 || t.NewGID < 0 {
		return fmt.Errorf("storage.chown: %w: uid/gid must not be negative", taskguard.ErrRefused)
	}
	return nil
}
