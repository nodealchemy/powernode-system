package storage

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// keyDir is a tmpfs-backed scratch location for the transient raw-key file
// handed to `fscrypt`. It never touches persistent storage and is removed
// immediately after the protector is created. A var (not const) so tests can
// redirect it to a temp dir.
var keyDir = "/run/powernode/storage/keys"

// SetupEncryption configures the encryption layer for a mount. It runs
// AFTER the filesystem is mounted (see applier.Apply) because fscrypt
// operates on a directory of an already-mounted, encryption-capable
// filesystem.
//
// Modes:
//   - none: no-op
//   - fscrypt: apply an fscrypt-v2 policy to the mount target using a raw-key
//     protector derived from the platform-provided key material
//   - luks: block-device encryption (only valid for block-backed sources)
//   - client_side_aes: app-level AES-GCM for object storage
//
// IMPORTANT (audit 2026-06-09 finding F6-02): this function FAILS CLOSED.
// Every path either verifiably applies encryption or returns an error — it
// MUST NOT return nil while leaving the target unencrypted. A returned error
// fails the mount task, which surfaces on the assignment status so an
// operator sees that encryption did not take, rather than the platform
// silently serving plaintext under an "encrypted" label.
//
// NOTE on network mounts: kernel fscrypt is a LOCAL-filesystem feature
// (ext4/f2fs/ubifs). It cannot encrypt an NFS/CIFS mount client-side — on
// such a target `fscrypt encrypt` errors, and that error correctly fails the
// mount here. Transparent client-side encryption of network storage needs a
// stacked mechanism (e.g. gocryptfs) or server-side at-rest encryption; until
// one is wired, network assignments must NOT default to fscrypt (the server
// default was corrected to "none" so honest plaintext mounts keep working).
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
		// fscrypt locks happen automatically when the directory is no longer
		// in use after unmount; nothing to do here.
		return nil
	default:
		return nil
	}
}

func setupFscrypt(ctx context.Context, runner mount.Runner, client httpGetter, task *MountTask) error {
	if task.Encryption.KeyURL == "" {
		return fmt.Errorf("fscrypt: missing key_url in task payload")
	}
	if task.MountPath == "" {
		return fmt.Errorf("fscrypt: missing mount_path in task payload")
	}

	// Idempotency: if the target already carries an fscrypt policy, the
	// previous run succeeded — re-applying would error. Treat as done.
	if encrypted, err := IsFscryptEncrypted(ctx, runner, task.MountPath); err == nil && encrypted {
		return nil
	}

	rawKey, err := fetchKeyMaterial(client, task.Encryption.KeyURL)
	if err != nil {
		return fmt.Errorf("fscrypt: fetch key: %w", err)
	}
	if len(rawKey) == 0 {
		return fmt.Errorf("fscrypt: empty key material")
	}

	keyFile, err := writeTransientKey(task.AssignmentID, rawKey)
	if err != nil {
		return fmt.Errorf("fscrypt: stage key: %w", err)
	}
	defer os.Remove(keyFile)

	// `fscrypt setup` initialises the per-filesystem metadata directory. It is
	// idempotent across runs but errors if the filesystem doesn't support
	// encryption (e.g. an NFS/CIFS mount) — that error is intentional and
	// fails the mount closed.
	if err := runner.Run(ctx, "fscrypt", "setup", "--quiet", task.MountPath); err != nil {
		// "already setup" is success; anything else is a hard failure.
		if !isAlreadyDone(err) {
			return fmt.Errorf("fscrypt setup on %s: %w", task.MountPath, err)
		}
	}

	protector := "powernode-" + shortID(task.AssignmentID)
	if err := runner.Run(ctx, "fscrypt", "encrypt", task.MountPath,
		"--source=raw_key", "--key="+keyFile, "--name="+protector,
		"--quiet", "--no-recovery"); err != nil {
		return fmt.Errorf("fscrypt encrypt %s: %w", task.MountPath, err)
	}
	return nil
}

// IsFscryptEncrypted reports whether the target directory already has an
// fscrypt policy applied. A non-nil error means the status could not be
// determined (treated as "not encrypted" by callers so setup is attempted).
func IsFscryptEncrypted(ctx context.Context, runner mount.Runner, path string) (bool, error) {
	out, err := runner.Output(ctx, "fscrypt", "status", path)
	if err != nil {
		return false, err
	}
	s := string(out)
	return strings.Contains(s, "Encrypted: Yes") || strings.Contains(s, `"Encrypted":true`), nil
}

// fetchKeyMaterial pulls the raw key bytes from the platform key endpoint.
// The endpoint returns {"success":true,"data":{...key fields...,"algorithm":...}}.
// The key bytes live under one of the conventional fields, base64-encoded.
func fetchKeyMaterial(client httpGetter, keyURL string) ([]byte, error) {
	resp, err := client.GetJSON(keyURL)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}

	var env struct {
		Data map[string]any `json:"data"`
	}
	if err := json.Unmarshal(body, &env); err != nil {
		return nil, fmt.Errorf("decode key envelope: %w", err)
	}
	for _, field := range []string{"key_material", "key", "raw_key", "material"} {
		if v, ok := env.Data[field].(string); ok && v != "" {
			if dec, derr := base64.StdEncoding.DecodeString(v); derr == nil {
				return dec, nil
			}
			// Not base64 — use the raw string bytes (passphrase-style key).
			return []byte(v), nil
		}
	}
	return nil, fmt.Errorf("key endpoint returned no recognised key field")
}

func writeTransientKey(assignmentID string, key []byte) (string, error) {
	if err := os.MkdirAll(keyDir, 0o700); err != nil {
		return "", err
	}
	f := filepath.Join(keyDir, shortID(assignmentID)+".key")
	if err := os.WriteFile(f, key, 0o600); err != nil {
		return "", err
	}
	return f, nil
}

func shortID(id string) string {
	id = strings.ReplaceAll(id, "/", "")
	if len(id) > 16 {
		return id[:16]
	}
	if id == "" {
		return "anon"
	}
	return id
}

func isAlreadyDone(err error) bool {
	msg := strings.ToLower(err.Error())
	return strings.Contains(msg, "already setup") ||
		strings.Contains(msg, "already exists") ||
		strings.Contains(msg, "metadata directory already")
}
