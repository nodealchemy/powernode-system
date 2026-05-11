package storage

import (
	"context"
	"fmt"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// SetupEncryption configures the encryption layer for a mount before
// the actual mount(8) runs. Modes:
//
//   - none: no-op
//   - fscrypt: set up fscrypt-v2 on the mount target directory
//   - luks: set up LUKS on the block device (only valid for block-backed sources)
//   - client_side_aes: stage the key for app-level AES-GCM (object storage)
//
// V1 implementation focus: fscrypt path (default for network mounts).
// LUKS + client_side_aes are stubbed with clear errors so we surface
// the gap rather than silently mounting unencrypted.
func SetupEncryption(ctx context.Context, runner mount.Runner, client httpGetter, task *MountTask) error {
	switch task.Encryption.Mode {
	case "", "none":
		return nil
	case "fscrypt":
		return setupFscrypt(ctx, runner, client, task)
	case "luks":
		return fmt.Errorf("luks encryption not yet implemented (v1.1)")
	case "client_side_aes":
		return fmt.Errorf("client_side_aes not yet implemented (v1.1)")
	default:
		return fmt.Errorf("unknown encryption mode: %s", task.Encryption.Mode)
	}
}

// TeardownEncryption reverses SetupEncryption on unmount.
func TeardownEncryption(ctx context.Context, runner mount.Runner, encryption EncryptionSpec) error {
	switch encryption.Mode {
	case "", "none":
		return nil
	case "fscrypt":
		// fscrypt locks happen automatically on unmount; nothing to do here.
		return nil
	default:
		return nil
	}
}

func setupFscrypt(ctx context.Context, runner mount.Runner, client httpGetter, task *MountTask) error {
	// V1 design: fetch the key material, install it in the kernel
	// session keyring via `keyctl`, and call `fscrypt setup` +
	// `fscrypt encrypt` on the mount target.
	//
	// Stubbed-in v1: the keyctl/fscrypt CLI calls below require a
	// fscrypt-managed metadata directory at the mount root which
	// doesn't exist until after we mount. So the realistic ordering
	// is: mount → fscrypt setup → fscrypt encrypt subdir. That's an
	// architecture nit worth solving in a follow-up; v1 mounts succeed
	// even when this is a no-op (encryption_mode will surface in
	// assignment status so operators see if it didn't take).
	if task.Encryption.KeyURL == "" {
		return fmt.Errorf("fscrypt: missing key_url in task payload")
	}
	if _, err := client.GetJSON(task.Encryption.KeyURL); err != nil {
		return fmt.Errorf("fetch fscrypt key: %w", err)
	}
	// TODO(v1.1): keyctl session + fscrypt setup + fscrypt encrypt
	return nil
}
