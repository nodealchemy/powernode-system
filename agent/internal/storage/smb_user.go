package storage

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/taskguard"
)

// ApplySambaUser shells out to samba-tool for per-instance user
// management. Runs on the backend peer (Shape 1: storage host;
// Shape 2: gateway). Idempotent: create on an existing user updates
// the password; delete on a missing user is a no-op.
//
// client resolves the password at apply time via fetchCredential — the task
// itself never carries it. delete never dereferences a credential, so client
// may be nil on that path (see handlers.StorageHandler, which always passes
// its live transport client regardless of action).
func ApplySambaUser(ctx context.Context, runner mount.Runner, client httpGetter, task *SmbUserApplyTask) error {
	// The single validation seam for storage.smb_user.apply. samba-tool runs
	// without a shell, so the exposure is argv: a leading dash on the username
	// becomes an option. See validate.go.
	if err := task.Validate(); err != nil {
		return err
	}

	switch task.Action {
	case "create":
		return createSambaUser(ctx, runner, client, task)
	case "delete":
		return deleteSambaUser(ctx, runner, task)
	case "set_password":
		return setSambaPassword(ctx, runner, client, task)
	default:
		return fmt.Errorf("unknown samba action: %s", task.Action)
	}
}

func createSambaUser(ctx context.Context, runner mount.Runner, client httpGetter, task *SmbUserApplyTask) error {
	password, err := fetchSambaPassword(client, task.Credential)
	if err != nil {
		return fmt.Errorf("storage.smb_user.apply create: %w", err)
	}
	// samba-tool exits non-zero if the user already exists; we treat
	// that as "make sure password matches" rather than fatal.
	if err := redactedRun(ctx, runner, password, "samba-tool", "user", "create", task.Username, password); err != nil {
		// Fall through to set_password if create failed (existing user).
		return redactedRun(ctx, runner, password, "samba-tool", "user", "setpassword", task.Username, "--newpassword="+password)
	}
	return nil
}

func deleteSambaUser(ctx context.Context, runner mount.Runner, task *SmbUserApplyTask) error {
	// Best-effort — missing user is fine.
	_ = runner.Run(ctx, "samba-tool", "user", "delete", task.Username)
	return nil
}

func setSambaPassword(ctx context.Context, runner mount.Runner, client httpGetter, task *SmbUserApplyTask) error {
	ref := task.NewCredential
	if ref.ID == "" {
		ref = task.Credential
	}
	password, err := fetchSambaPassword(client, ref)
	if err != nil {
		return fmt.Errorf("storage.smb_user.apply set_password: %w", err)
	}
	return redactedRun(ctx, runner, password, "samba-tool", "user", "setpassword", task.Username, "--newpassword="+password)
}

// fetchSambaPassword resolves the plaintext password for a CredentialRef via
// the node_api round-trip, then runs it through taskguard.Secret BEFORE it
// ever touches argv. Secret's refusal is value-free (refuseQuiet), so a
// malformed fetched value — empty, holding a control character (a Vault
// entry or a compromised endpoint response could inject a newline that
// smuggles an extra samba-tool argument), or starting with a dash (which
// samba-tool would parse as a flag) — is refused without ever echoing it.
func fetchSambaPassword(client httpGetter, ref CredentialRef) (string, error) {
	payload, _, err := fetchCredential(client, ref.URL)
	if err != nil {
		return "", fmt.Errorf("fetch samba credential: %w", err)
	}
	if err := taskguard.Secret("password", payload.Password); err != nil {
		return "", err
	}
	return payload.Password, nil
}

// redactedRun runs a samba-tool invocation via runner.Run and, on failure,
// strips the secret value out of the returned error before any caller ever
// sees it. runner.Run's production implementation (mount.ExecRunner) formats
// the FULL ARGV — including a positional password — and the command's
// captured stdout/stderr into the error it returns (mount/runner.go), and
// the runtime loop posts that error's .Error() text verbatim as the task's
// PERSISTED error_message (tasks/client.go Client.Fail) — so an unredacted
// failure would put the plaintext password into a DB column exactly like the
// options field this whole fix removed it from.
func redactedRun(ctx context.Context, runner mount.Runner, secret, name string, args ...string) error {
	err := runner.Run(ctx, name, args...)
	if err == nil || secret == "" {
		return err
	}
	return errors.New(strings.ReplaceAll(err.Error(), secret, "REDACTED"))
}
