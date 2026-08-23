package etcsudoers

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/nodealchemy/powernode-system/agent/internal/fsutil"
)

// OperatorBreakGlassFilename is the basename of the drop-in that
// grants the `pnadmin` user unrestricted NOPASSWD sudo. Kept under
// the powernode- prefix so the normal sweep() in Apply leaves it
// alone (sweep only deletes managed files that aren't in the
// keep-set; we never enumerate this one through that path because
// it's written by ApplyOperatorBreakGlass, not by manifest-driven
// Apply).
const OperatorBreakGlassFilename = "powernode-operator-break-glass"

// OperatorBreakGlassBody is the canonical sudoers content for the
// break-glass grant. Comment block explains intent + how to revoke.
// The trailing newline is required by some visudo implementations
// that flag missing-EOL as a hard error.
const OperatorBreakGlassBody = `# Managed by Powernode: pnadmin break-glass
#
# Grants the cloud-image-equivalent pnadmin login user unrestricted
# NOPASSWD sudo. Enabled via POWERNODE_OPERATOR_BREAK_GLASS=1 on
# the agent process (e.g. systemd Environment=POWERNODE_OPERATOR_BREAK_GLASS=1).
# Unset the env var (or set to anything except "1"/"true") + restart
# the agent to revoke; the file is removed at the next agent start.
#
# Intended for dev/recovery loops on managed_child instances where
# the pnadmin user otherwise has no path to root. Production
# deployments should rely on module-declared SudoersGrant rows
# instead and keep this disabled.
pnadmin ALL=(ALL) NOPASSWD: ALL
`

// ApplyOperatorBreakGlass writes or removes the operator break-glass
// drop-in based on `enabled`. Idempotent: a no-op when the on-disk
// state already matches.
//
// The write goes through Validate (visudo -cf) before atomic-rename
// to catch any syntax breakage in OperatorBreakGlassBody. Even though
// the body is a string constant today, the validator catches issues
// like the visudo binary having stricter syntax than expected on a
// particular distro.
func ApplyOperatorBreakGlass(enabled bool) error {
	return ApplyOperatorBreakGlassAt(enabled, SudoersDir)
}

// ApplyOperatorBreakGlassAt is ApplyOperatorBreakGlass with an
// overridable directory — for tests.
func ApplyOperatorBreakGlassAt(enabled bool, dir string) error {
	path := filepath.Join(dir, OperatorBreakGlassFilename)

	if !enabled {
		// Revocation path: remove the file if present, else no-op. We
		// don't touch any other powernode-* files — Apply()'s sweep
		// handles those.
		if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
			return fmt.Errorf("remove %s: %w", path, err)
		}
		return nil
	}

	if err := os.MkdirAll(dir, 0o750); err != nil {
		return fmt.Errorf("mkdir %s: %w", dir, err)
	}

	body := []byte(OperatorBreakGlassBody)

	// Idempotency: skip write+visudo when on-disk content already matches.
	// Saves the visudo fork on every agent start once converged.
	if existing, err := os.ReadFile(path); err == nil && string(existing) == string(body) {
		return nil
	}

	if err := Validate(body); err != nil {
		return fmt.Errorf("validate %s: %w", OperatorBreakGlassFilename, err)
	}
	if err := fsutil.AtomicWrite(path, body, 0o440); err != nil {
		return fmt.Errorf("write %s: %w", path, err)
	}
	if err := os.Chown(path, 0, 0); err != nil {
		// Non-fatal — the file is still readable by root.
		_ = err
	}
	return nil
}

// OperatorBreakGlassEnabledFromEnv reads POWERNODE_OPERATOR_BREAK_GLASS
// and returns true iff its value is one of the recognized truthy
// strings ("1", "true", "yes"). Any other value (including empty +
// unset) returns false.
//
// Centralized so all callers agree on the truth values; saves
// surprises like "TRUE" being treated differently from "true".
func OperatorBreakGlassEnabledFromEnv() bool {
	v := os.Getenv("POWERNODE_OPERATOR_BREAK_GLASS")
	switch v {
	case "1", "true", "TRUE", "True", "yes", "YES":
		return true
	default:
		return false
	}
}
