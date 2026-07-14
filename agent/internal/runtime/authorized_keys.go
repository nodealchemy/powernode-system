package runtime

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/user"
	"path/filepath"
	"strconv"

	"github.com/nodealchemy/powernode-system/agent/internal/etcidentity"
	"github.com/nodealchemy/powernode-system/agent/internal/transport"
)

// AuthorizedKeysOptions parameterizes FetchAuthorizedKeys. OnWarn is
// invoked for non-fatal sub-failures (chown errors that don't break
// the file write but matter for sshd StrictModes); pass nil to drop
// warnings silently.
type AuthorizedKeysOptions struct {
	Client *transport.Client
	OnWarn func(stage string, err error)
}

// FetchAuthorizedKeys retrieves operator-supplied SSH keys from the
// platform's /node_api/config/authorized_keys endpoint and writes
// them to the configured target user's ~/.ssh/authorized_keys with
// the correct mode (0600 file, 0700 dir) and ownership.
//
// The target user is taken from the response's `target_user` field
// (instance.config["admin_user"] → node.config["admin_user"] →
// "pnadmin" on the platform side). When absent, defaults to
// "pnadmin" — the platform's standardized human-login account at
// UID 1000 (see etcidentity.Baseline). Per-instance overrides
// (admin_user: "ubuntu" on cloud-image-derived nodes) still apply.
//
// Idempotent: writes only when the on-disk content differs from the
// platform response. Safe to call on every heartbeat tick — propagates
// key rotation without requiring an agent restart.
//
// Extracted from Service.fetchAuthorizedKeys in Phase 0 so the sync
// CLI command can reuse this without instantiating Service.
func FetchAuthorizedKeys(ctx context.Context, opts AuthorizedKeysOptions) error {
	if opts.Client == nil {
		return fmt.Errorf("FetchAuthorizedKeys: nil client")
	}
	resp, err := opts.Client.GetJSON("/api/v1/system/node_api/config/authorized_keys")
	if err != nil {
		return fmt.Errorf("GET authorized_keys: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 64*1024))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("authorized_keys status %d: %s", resp.StatusCode, string(body))
	}

	var ak struct {
		Success bool `json:"success"`
		Data    struct {
			AuthorizedKeys string `json:"authorized_keys"`
			KeysCount      int    `json:"keys_count"`
			TargetUser     string `json:"target_user"`
		} `json:"data"`
	}
	if err := json.Unmarshal(body, &ak); err != nil {
		return fmt.Errorf("decode authorized_keys: %w", err)
	}

	targetUser := ak.Data.TargetUser
	if targetUser == "" {
		// Platform-standardized human-login account; always present
		// in the agent's etcidentity baseline at UID 1000.
		targetUser = "pnadmin"
	}

	dir, uid, gid, err := resolveSSHDir(targetUser)
	if err != nil {
		return fmt.Errorf("resolve ssh dir for %q: %w", targetUser, err)
	}
	path := filepath.Join(dir, "authorized_keys")

	// The parent chain must be correct or sshd — dropping to the target
	// uid under StrictModes to read authorized_keys — cannot even reach
	// the file:
	//   /home      must be traversable. A bare os.MkdirAll(dir, 0700) here
	//              used to create it 0700 root:root on pivot-booted fleet
	//              nodes where /home did not pre-exist, silently breaking
	//              EVERY user's key login (the fleet SSH incident). Cloud-
	//              init nodes escaped only because cloud-init's useradd had
	//              already created the home.
	//   ~user      must be OWNED by the user (0700) so it can traverse into
	//              its own home — this was previously left root:root
	//              because MkdirAll only chowned .ssh below it, not ~user.
	//   ~user/.ssh 0700, user-owned.
	// EnsureOwnedDir reconciles top-level ownership only (never recursive)
	// and refuses symlinks; the modes are single-sourced in etcidentity so
	// they match the base-os tmpfiles.d boot-time backstop.
	home := filepath.Dir(dir)
	if err := etcidentity.EnsureTraversableDir(filepath.Dir(home)); err != nil {
		warn(opts.OnWarn, "authorized_keys_home_parent", err)
	}
	if err := etcidentity.EnsureOwnedDir(home, uid, gid, 0o700); err != nil {
		return fmt.Errorf("ensure home %s: %w", home, err)
	}
	if err := etcidentity.EnsureOwnedDir(dir, uid, gid, 0o700); err != nil {
		return fmt.Errorf("ensure ssh dir %s: %w", dir, err)
	}

	desired := ak.Data.AuthorizedKeys
	if desired != "" && desired[len(desired)-1] != '\n' {
		desired += "\n"
	}
	current, _ := os.ReadFile(path)
	if string(current) != desired {
		if err := os.WriteFile(path, []byte(desired), 0o600); err != nil {
			return fmt.Errorf("write %s: %w", path, err)
		}
	}
	// Always reconcile ownership, even when the content already matches.
	// An earlier cloud-init runcmd may have created authorized_keys as
	// root (before the pnadmin user existed), which sshd rejects under
	// StrictModes. Re-chowning every tick is cheap and self-heals that
	// bootstrap-ordering case.
	if err := os.Chown(path, uid, gid); err != nil {
		warn(opts.OnWarn, "authorized_keys_chown_file", err)
	}
	return nil
}

// resolveSSHDir looks up the unix user named target and returns its
// `~/.ssh` directory plus the user's uid/gid for downstream chown calls.
// Returns an error if the user does not exist on the box — the caller
// should not fall back to root in that case (silently writing to /root
// would mask a misconfiguration the operator needs to see).
func resolveSSHDir(target string) (string, int, int, error) {
	u, err := user.Lookup(target)
	if err != nil {
		return "", 0, 0, fmt.Errorf("user.Lookup: %w", err)
	}
	if u.HomeDir == "" {
		return "", 0, 0, fmt.Errorf("user %q has no home directory", target)
	}
	uid, err := strconv.Atoi(u.Uid)
	if err != nil {
		return "", 0, 0, fmt.Errorf("parse uid %q: %w", u.Uid, err)
	}
	gid, err := strconv.Atoi(u.Gid)
	if err != nil {
		return "", 0, 0, fmt.Errorf("parse gid %q: %w", u.Gid, err)
	}
	return filepath.Join(u.HomeDir, ".ssh"), uid, gid, nil
}

func warn(cb func(string, error), stage string, err error) {
	if cb != nil {
		cb(stage, err)
	}
}
