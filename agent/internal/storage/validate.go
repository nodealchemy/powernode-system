package storage

import (
	"fmt"

	"github.com/nodealchemy/powernode-system/agent/internal/taskguard"
)

// Validation for every storage.* task payload lives HERE and nowhere else.
//
// Each payload type carries one Validate method, and each exported entry point
// in this package (Apply, Unapply, ApplyExports, ApplySambaUser,
// ProvisionGateway, DeprovisionGateway, ApplyChown, UnmountNFS, UnmountCIFS)
// calls it once, first, before any side effect. The lower-level primitives
// (WriteMountUnit, StartMountUnit, StopAndRemoveMountUnit,
// writeGatewayMountUnit, writeReExportLine) deliberately do NOT re-check: a
// second guard on the same field would make it impossible to tell, from a
// failing test, which rule is actually doing the work.
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
	if t.WGInterfaceHint != "" {
		if err := taskguard.ConfigToken("wg_interface_hint", t.WGInterfaceHint); err != nil {
			return err
		}
	} else if t.RequiresWGInterface {
		// Absent-field case, pinned deliberately: renderMountUnit silently
		// drops the dependency when the hint is empty, so a mount that
		// declares it needs the tunnel would fire before the tunnel exists.
		return fmt.Errorf("storage.mount: %w: wg_interface_hint: required when requires_wg_interface is set", taskguard.ErrRefused)
	}
	// Credential.ID becomes a filename under /run/sdwan/mount-creds and, via
	// credentials=/passwd_file=, a value inside the unit body.
	if t.Credential.ID != "" {
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

// Validate checks the fields StopAndRemoveMountUnit acts on. mount_path is not
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
		if err := taskguard.IPAddress(fmt.Sprintf("entries[%d].peer_ip", i), e.PeerIP); err != nil {
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
	if t.Password != "" {
		if err := taskguard.Secret("password", t.Password); err != nil {
			return err
		}
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
	return taskguard.UnitName("gateway_unit_name", t.GatewayUnitName, mountUnitSuffix)
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
	return taskguard.UnitName("gateway_unit_name", t.GatewayUnitName, mountUnitSuffix)
}

// Validate checks the chown payload.
//
// This SUPERSEDES the two-value guard that used to live in ApplyChown, which
// refused exactly "" and "/". "/etc" with old_uid 0 passed it and handed the
// node's configuration tree to an unprivileged uid, as root, recursively.
//
// callback_path is included because the handler POSTs to it over the agent's
// mTLS connection: see taskguard.PlatformPath for why a value that does not
// start with "/" leaves the platform origin. An ABSENT callback_path is legal
// — the handler substitutes the platform default — so it is only checked when
// present.
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
	if t.CallbackPath != "" {
		if err := taskguard.PlatformPath("callback_path", t.CallbackPath); err != nil {
			return err
		}
	}
	return nil
}
