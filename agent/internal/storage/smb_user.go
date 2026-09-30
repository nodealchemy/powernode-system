package storage

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os/exec"
	"sort"
	"strconv"
	"strings"
	"time"

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
	// that as "make sure password matches" rather than fatal. No password
	// positional argument — see redactedRun.
	if err := redactedRun(ctx, runner, password, "samba-tool", "user", "create", task.Username); err != nil {
		// Fall through to set_password if create failed (existing user).
		return redactedRun(ctx, runner, password, "samba-tool", "user", "setpassword", task.Username)
	}
	return nil
}

// deleteSambaUser removes the principal AND closes the SMB sessions it
// already holds. IMP-65a2b9f94490: this used to discard samba-tool's error
// (a delete that failed reported success) and never touched open sessions —
// an established SMB session keeps its authenticated token, so a revoked
// principal kept every share it had mounted until it disconnected on its own.
//
// Order is deliberate:
//  1. enumerate the user's sessions FIRST, while the name still resolves
//     (smbstatus reports uidtoname(), which after the delete may no longer
//     map back to this user). A failure here mutates nothing.
//  2. delete, so nothing can re-authenticate — closing first would let an
//     auto-reconnecting client straight back in before the delete landed.
//  3. close each enumerated smbd process, then poll until none is listed.
//
// Every command goes through the runner as argv (no shell); the username has
// already passed Validate()'s taskguard.Identifier and pids are parsed as
// integers before they reach smbcontrol.
//
// Residual: an smbd process serves one client connection, and a connection
// can carry sessions for more than one user — closing it drops those too. A
// session opened between step 1 and step 2 is not closed; and a retry after a
// delete that landed but whose close failed finds the user already gone and
// cannot re-identify its sessions by name.
func deleteSambaUser(ctx context.Context, runner mount.Runner, task *SmbUserApplyTask) error {
	pids, err := smbSessionPIDs(ctx, runner, task.Username)
	if err != nil {
		return fmt.Errorf("storage.smb_user.apply delete: list sessions: %w", err)
	}
	if err := runner.Run(ctx, "samba-tool", "user", "delete", task.Username); err != nil {
		if !isSambaUserNotFound(err, task.Username) {
			return fmt.Errorf("storage.smb_user.apply delete: %w", err)
		}
	}
	if len(pids) == 0 {
		return nil
	}
	for _, pid := range pids {
		if err := runner.Run(ctx, "smbcontrol", pid, "shutdown"); err != nil {
			return fmt.Errorf("storage.smb_user.apply delete: close session process %s: %w", pid, err)
		}
	}
	return waitSmbSessionsGone(ctx, runner, pids)
}

// isSambaUserNotFound reports whether err is samba-tool's own "no such user"
// failure for username — the one delete outcome that is success (idempotent).
//
// Shape, from the samba 4.19.5 source (Ubuntu noble ships
// 2:4.19.5+dfsg-4ubuntu9.x): python/samba/netcmd/user.py cmd_user_delete
// raises CommandError('Unable to find user "%s"' % username) when the
// sAMAccountName search is empty; python/samba/netcmd/__init__.py
// show_command_error prints it through _print_error as `ERROR: <message>`
// (inner_exception is None, so no "(klass)"; colour is off because stderr is
// not a tty), and Command._run returns -1, which samba-tool exits with: 255.
// Any other delete failure ("Failed to remove user", an ldb error) is a
// different message and stays a failure. Both the exit code and the exact
// line for THIS username are required, so another user's not-found or the
// text under another exit status does not count.
//
// UNVERIFIED by execution: derived from the source above; the verify script
// (imp65a-samba-verify.sh) proves it against a live samba-tool.
func isSambaUserNotFound(err error, username string) bool {
	var ee *exec.ExitError
	if !errors.As(err, &ee) || ee.ExitCode() != 255 {
		return false
	}
	return strings.Contains(err.Error(), `ERROR: Unable to find user "`+username+`"`)
}

// smbstatusSessions is the part of `smbstatus --processes --json` (samba
// 4.16+; source3/utils/status_json.c traverse_sessionid_json and
// add_server_id_to_json) this file reads. server_id.pid is a string there.
type smbstatusSessions struct {
	Sessions map[string]struct {
		ServerID struct {
			PID string `json:"pid"`
		} `json:"server_id"`
		Username string `json:"username"`
	} `json:"sessions"`
}

func listSmbSessions(ctx context.Context, runner mount.Runner, args ...string) (*smbstatusSessions, error) {
	out, err := runner.Output(ctx, "smbstatus", args...)
	if err != nil {
		return nil, err
	}
	var st smbstatusSessions
	if err := json.Unmarshal(out, &st); err != nil {
		return nil, fmt.Errorf("smbstatus: unparseable output: %w", err)
	}
	if st.Sessions == nil {
		return nil, errors.New("smbstatus: output has no sessions section")
	}
	return &st, nil
}

// smbSessionPIDs returns the distinct smbd process ids holding a session for
// username, sorted. smbstatus names the session owner with uidtoname(), which
// on a domain member or DC is winbind's DOMAIN\user form, so the part after
// the last separator is compared too; sAMAccountName compares
// case-insensitively. A pid that is not a positive integer above 1 fails the
// whole listing closed rather than being skipped.
//
// UNVERIFIED by execution: that the node's smbstatus reports this user's
// sessions under one of these two names (it needs NSS to resolve the uid).
// The verify script asserts the pre-delete listing matches its session.
func smbSessionPIDs(ctx context.Context, runner mount.Runner, username string) ([]string, error) {
	st, err := listSmbSessions(ctx, runner, "--processes", "--json")
	if err != nil {
		return nil, err
	}
	seen := map[string]bool{}
	for _, s := range st.Sessions {
		pid, err := smbdPID(s.ServerID.PID)
		if err != nil {
			return nil, err
		}
		name := s.Username
		if i := strings.LastIndex(name, `\`); i >= 0 {
			name = name[i+1:]
		}
		if strings.EqualFold(name, username) {
			seen[pid] = true
		}
	}
	pids := make([]string, 0, len(seen))
	for pid := range seen {
		pids = append(pids, pid)
	}
	sort.Slice(pids, func(i, j int) bool {
		a, _ := strconv.ParseUint(pids[i], 10, 64)
		b, _ := strconv.ParseUint(pids[j], 10, 64)
		return a < b
	})
	return pids, nil
}

func smbdPID(raw string) (string, error) {
	n, err := strconv.ParseUint(raw, 10, 32)
	if err != nil || n <= 1 {
		return "", fmt.Errorf("smbstatus: refusing session process id %q", raw)
	}
	return strconv.FormatUint(n, 10), nil
}

// smbSessionGonePolls/Interval bound the post-close check. smbcontrol only
// queues MSG_SHUTDOWN; the smbd child exits asynchronously
// (source3/smbd/server.c msg_exit_server → exit_server_cleanly), and
// smbstatus drops a session once its process is gone (process_exists).
var (
	smbSessionGonePolls    = 10
	smbSessionGoneInterval = 200 * time.Millisecond
)

// waitSmbSessionsGone polls `smbstatus --processes --numeric --json` until no
// session is held by any of pids. --numeric because after the delete the
// uid may no longer resolve to a name; only the pid is compared.
//
// UNVERIFIED by execution: that `smbcontrol <pid> shutdown` ends an smbd
// child's session on the node (the child inherits the parent's MSG_SHUTDOWN
// registration across fork). The verify script proves the session is gone.
func waitSmbSessionsGone(ctx context.Context, runner mount.Runner, pids []string) error {
	var remaining []string
	for i := 0; i < smbSessionGonePolls; i++ {
		if i > 0 && smbSessionGoneInterval > 0 {
			select {
			case <-ctx.Done():
				return fmt.Errorf("storage.smb_user.apply delete: %w", ctx.Err())
			case <-time.After(smbSessionGoneInterval):
			}
		}
		st, err := listSmbSessions(ctx, runner, "--processes", "--numeric", "--json")
		if err != nil {
			return fmt.Errorf("storage.smb_user.apply delete: verify sessions closed: %w", err)
		}
		live := map[string]bool{}
		for _, s := range st.Sessions {
			live[s.ServerID.PID] = true
		}
		remaining = remaining[:0]
		for _, pid := range pids {
			if live[pid] {
				remaining = append(remaining, pid)
			}
		}
		if len(remaining) == 0 {
			return nil
		}
	}
	return fmt.Errorf("storage.smb_user.apply delete: sessions still open after close on process(es) %s", strings.Join(remaining, ", "))
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
	return redactedRun(ctx, runner, password, "samba-tool", "user", "setpassword", task.Username)
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

// redactedRun runs a samba-tool invocation whose secret is delivered via
// STDIN — never argv, never the environment — and, on failure, strips the
// secret value out of the returned error before any caller ever sees it.
//
// IMP-ad2c66a838f2 — `args` used to carry the plaintext password as a
// positional argument (create) or a `--newpassword=` flag (setpassword),
// readable by any other user on the box via /proc/<pid>/cmdline or `ps`.
// Verified BY EXECUTION against a real samba-tool AD DC (docker container,
// `samba-tool domain provision`) that `samba-tool user create <user>` and
// `samba-tool user setpassword <user>` — called with NEITHER the password
// positional NOR --newpassword= — prompt "New Password:" / "Retype
// Password:" and read BOTH from stdin when stdin is not a TTY, so writing
// the secret there twice (one line per prompt) completes the exact same
// operation the old argv-based call did. `-A/--authentication-file` was
// also checked: it authenticates the samba-tool CLIENT itself (like -U),
// not the new user's password, so it doesn't apply here.
//
// runner.Run's production implementation (mount.ExecRunner) used to format
// the FULL ARGV — including the positional password — and the command's
// captured stdout/stderr into the error it returns (mount/runner.go), and
// the runtime loop posts that error's .Error() text verbatim as the task's
// PERSISTED error_message (tasks/client.go Client.Fail) — so this redaction
// stays in place as defense in depth even though the secret can no longer
// reach argv at all. runner must implement mount.StdinRunner — both
// mount.ExecRunner and mount.RecorderRunner do.
func redactedRun(ctx context.Context, runner mount.Runner, secret, name string, args ...string) error {
	sr, ok := runner.(mount.StdinRunner)
	if !ok {
		return fmt.Errorf("%s: runner %T does not support stdin-delivered secrets", name, runner)
	}
	err := sr.RunStdin(ctx, secret+"\n"+secret+"\n", name, args...)
	if err == nil || secret == "" {
		return err
	}
	return errors.New(strings.ReplaceAll(err.Error(), secret, "REDACTED"))
}
