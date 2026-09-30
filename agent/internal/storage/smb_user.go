package storage

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
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
// the password; delete on a missing user is success, and delete also
// closes the user's live SMB sessions (see deleteSambaUser).
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
//  1. resolve the user's uid (wbinfo -i) and list its sessions FIRST, while
//     the account still exists. Any doubt fails here, with nothing mutated:
//     an account that exists but whose uid cannot be resolved, or — when no
//     uid is known — a listing holding a session whose owner smbstatus could
//     only print as a number (it might be this user's; see smbSessionPIDs).
//  2. delete, so nothing can re-authenticate — closing first would let an
//     auto-reconnecting client straight back in before the delete landed.
//  3. close: signal each listed process, then poll the numeric listing,
//     which is the only success oracle. Each poll also sweeps by the
//     resolved uid, so a session opened between step 1 and step 2 is closed
//     too. A failed signal (the process may already have exited) fails the
//     task only if the poll still lists a session for it.
//
// Every command goes through the runner as argv (no shell); the username has
// already passed Validate()'s taskguard.Identifier, and uids and pids are
// parsed as integers before they are compared or reach smbcontrol. A node
// with samba-tool but without smbstatus/smbcontrol/wbinfo now fails every
// delete (it used to report success without closing anything).
//
// Residual: an smbd process serves one client connection, and a connection
// can carry sessions for more than one user — closing it drops those too.
// When the account is already gone (a retry) no uid is known: sessions can
// be found only by name, and any numeric-owner session fails the task
// closed. smbstatus ignores its own traversal's early stop (status.c
// sessionid_traverse_read), so a listing it cuts short still exits 0.
func deleteSambaUser(ctx context.Context, runner mount.Runner, task *SmbUserApplyTask) error {
	uid, resolved, err := resolveSambaUID(ctx, runner, task.Username)
	if err != nil {
		return fmt.Errorf("storage.smb_user.apply delete: %w", err)
	}
	st, err := listSmbSessions(ctx, runner, "--processes", "--json")
	if err != nil {
		return fmt.Errorf("storage.smb_user.apply delete: list sessions: %w", err)
	}
	pids, err := smbSessionPIDs(st, task.Username, uid, resolved)
	if err != nil {
		return fmt.Errorf("storage.smb_user.apply delete: list sessions: %w", err)
	}
	if err := runner.Run(ctx, "samba-tool", "user", "delete", task.Username); err != nil {
		if !isSambaUserNotFound(err, task.Username) {
			return fmt.Errorf("storage.smb_user.apply delete: %w", err)
		}
	}
	if len(pids) == 0 && !resolved {
		return nil
	}
	return closeSmbSessions(ctx, runner, pids, uid, resolved)
}

// resolveSambaUID returns the uid smbd runs username's sessions under, from
// `wbinfo -i <user>` (passwd-line shape DOMAIN\user:*:<uid>:<gid>:...).
// smbstatus reports a session's owner as that uid, and — without
// libnss-winbind in nsswitch — ALSO puts the bare number in its username
// field, so the uid is the only reliable key.
//
// When wbinfo cannot resolve the name, `samba-tool user show` decides between
// the two cases: an account that exists is a failure (its sessions could not
// be found); an account that does not exist is resolved=false, and the
// delete below reports samba-tool's own not-found as success.
func resolveSambaUID(ctx context.Context, runner mount.Runner, username string) (uint32, bool, error) {
	out, werr := runner.Output(ctx, "wbinfo", "-i", username)
	if werr == nil {
		uid, err := parseWbinfoPasswd(string(out), username)
		if err != nil {
			return 0, false, err
		}
		return uid, true, nil
	}
	serr := runner.Run(ctx, "samba-tool", "user", "show", username)
	switch {
	case serr == nil:
		return 0, false, fmt.Errorf("user %s exists but its uid could not be resolved: %w", username, werr)
	case isSambaUserShowNotFound(serr, username):
		return 0, false, nil
	default:
		return 0, false, fmt.Errorf("resolve uid: %w (existence check: %v)", werr, serr)
	}
}

// parseWbinfoPasswd reads the uid from one `wbinfo -i` line and checks that
// the line is for username (the part after the domain separator,
// case-insensitive — sAMAccountName is). uid 0 and the -1 sentinel are
// refused: matching sessions on either would close ones that are not this
// user's.
func parseWbinfoPasswd(out, username string) (uint32, error) {
	line := strings.TrimSpace(out)
	fields := strings.Split(line, ":")
	if strings.Contains(line, "\n") || len(fields) != 7 {
		return 0, errors.New("wbinfo -i: unexpected output shape")
	}
	name := fields[0]
	if i := strings.LastIndex(name, `\`); i >= 0 {
		name = name[i+1:]
	}
	if !strings.EqualFold(name, username) {
		return 0, fmt.Errorf("wbinfo -i: output is not for user %s", username)
	}
	uid, err := strconv.ParseUint(fields[2], 10, 32)
	if err != nil || uid == 0 || uid == math.MaxUint32 {
		return 0, fmt.Errorf("wbinfo -i: refusing uid %q", fields[2])
	}
	return uint32(uid), nil
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
// UNVERIFIED by execution: derived from the source above; check C of the
// verify script (imp65a-samba-verify.sh) proves it against a live samba-tool.
func isSambaUserNotFound(err error, username string) bool {
	return sambaToolFailedWith(err, `ERROR: Unable to find user "`+username+`"`)
}

// isSambaUserShowNotFound is the same check for `samba-tool user show`, whose
// 4.19.5 path (user.py GetPasswordCommand.get_account_attributes) wraps the
// empty search as CommandError("Failed to get password for user '%s': %s")
// around Exception('Unable to find user "%s"'); printed and exited as above.
//
// UNVERIFIED by execution: derived from that source; check D of the verify
// script proves it.
func isSambaUserShowNotFound(err error, username string) bool {
	return sambaToolFailedWith(err, `ERROR: Failed to get password for user '`+username+`': Unable to find user "`+username+`"`)
}

func sambaToolFailedWith(err error, line string) bool {
	var ee *exec.ExitError
	if !errors.As(err, &ee) || ee.ExitCode() != 255 {
		return false
	}
	return strings.Contains(err.Error(), line)
}

// smbstatusSessions is the part of `smbstatus --processes --json` (samba
// 4.16+; source3/utils/status_json.c traverse_sessionid_json and
// add_server_id_to_json) this file reads. Observed on a live 4.19.5 AD DC:
//
//	"uid": 3000016, "username": "3000016", "server_id": {"pid": "30046", ...}
//
// server_id.pid is decoded from a string OR a number; uid is an int that is
// -1 while authentication is still in progress.
type smbstatusSessions struct {
	Sessions map[string]struct {
		ServerID struct {
			PID json.RawMessage `json:"pid"`
		} `json:"server_id"`
		UID      *int64 `json:"uid"`
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
// the user, sorted. The session's numeric uid is the primary key (when
// resolved); the username field — the bare name, or winbind's DOMAIN\user
// form when libnss-winbind resolves the uid — is a secondary match. A pid
// that is not an integer above 1 fails the whole listing closed rather than
// being skipped.
//
// Verified by execution on a live 4.19.5 AD DC without libnss-winbind: the
// session listed "username": "<uid>", never the name — which is why the uid
// comes first. It is also why, when no uid is known, a listing that matched
// nothing but holds a session whose owner is printed only as a number
// (uidtoname()'s fallback) is refused: that session could be this user's.
// Sessions still authenticating (uid -1) belong to no one yet and are skipped.
func smbSessionPIDs(st *smbstatusSessions, username string, uid uint32, uidResolved bool) ([]string, error) {
	seen := map[uint64]bool{}
	var unattributed []string
	for _, s := range st.Sessions {
		pid, err := smbdPID(s.ServerID.PID)
		if err != nil {
			return nil, err
		}
		if s.UID != nil && *s.UID == -1 {
			continue
		}
		name := s.Username
		if i := strings.LastIndex(name, `\`); i >= 0 {
			name = name[i+1:]
		}
		switch {
		case uidResolved && s.UID != nil && *s.UID == int64(uid):
			seen[pid] = true
		case strings.EqualFold(name, username):
			seen[pid] = true
		case isAllDigits(s.Username):
			unattributed = append(unattributed, s.Username)
		}
	}
	if len(seen) == 0 && !uidResolved && len(unattributed) > 0 {
		sort.Strings(unattributed)
		return nil, fmt.Errorf("smbstatus: %d live session(s) have an owner smbstatus can print only as a uid (%s) and %s's uid is unknown; cannot prove none of them is %s's",
			len(unattributed), strings.Join(unattributed, ", "), username, username)
	}
	return sortedPIDs(seen), nil
}

func isAllDigits(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

func sortedPIDs(set map[uint64]bool) []string {
	nums := make([]uint64, 0, len(set))
	for pid := range set {
		nums = append(nums, pid)
	}
	sort.Slice(nums, func(i, j int) bool { return nums[i] < nums[j] })
	pids := make([]string, len(nums))
	for i, n := range nums {
		pids[i] = strconv.FormatUint(n, 10)
	}
	return pids
}

// smbdPID decodes server_id.pid, which status_json.c emits as a string but
// which is accepted as a JSON number too, and refuses anything that is not
// an integer above 1 (0 would make smbcontrol broadcast to every daemon).
func smbdPID(raw json.RawMessage) (uint64, error) {
	var s string
	if err := json.Unmarshal(raw, &s); err != nil {
		var n json.Number
		if err := json.Unmarshal(raw, &n); err != nil {
			return 0, fmt.Errorf("smbstatus: refusing session process id %s", raw)
		}
		s = n.String()
	}
	n, err := strconv.ParseUint(s, 10, 32)
	if err != nil || n <= 1 {
		return 0, fmt.Errorf("smbstatus: refusing session process id %q", s)
	}
	return n, nil
}

// smbSessionGonePolls/Interval bound the close: about 10s. smbcontrol only
// queues MSG_SHUTDOWN; the smbd child exits asynchronously
// (source3/smbd/server.c msg_exit_server → exit_server_cleanly, which can
// take a while with open files or oplock breaks), and smbstatus drops a
// session once its process is gone (process_exists).
var (
	smbSessionGonePolls    = 20
	smbSessionGoneInterval = 500 * time.Millisecond
)

// closeSmbSessions signals every listed process with `smbcontrol <pid>
// shutdown`, then polls `smbstatus --processes --numeric --json` (numeric:
// after the delete the uid may not resolve to a name; only uid and pid are
// compared) until none of those processes — and, when the uid is known, no
// session of that uid at all — is listed. A process that shows up for the
// uid during the poll is signalled too. The poll, not smbcontrol's exit
// status, decides: signalling a process that has already exited fails, and
// is only reported if the poll still lists it. Cancellation is honoured
// between polls.
//
// UNVERIFIED by execution: that `smbcontrol <pid> shutdown` ends an smbd
// child's session on the node (the child inherits the parent's MSG_SHUTDOWN
// registration across fork). Check B of the verify script proves it.
func closeSmbSessions(ctx context.Context, runner mount.Runner, pids []string, uid uint32, uidResolved bool) error {
	signalled := map[string]bool{}
	signalErrs := map[string]error{}
	signal := func(pid string) {
		signalled[pid] = true
		if err := runner.Run(ctx, "smbcontrol", pid, "shutdown"); err != nil {
			signalErrs[pid] = err
		}
	}
	for _, pid := range pids {
		signal(pid)
	}

	var remaining []string
	for i := 0; i < smbSessionGonePolls; i++ {
		if i > 0 {
			select {
			case <-ctx.Done():
				return fmt.Errorf("storage.smb_user.apply delete: closing sessions: %w", ctx.Err())
			case <-time.After(smbSessionGoneInterval):
			}
		}
		st, err := listSmbSessions(ctx, runner, "--processes", "--numeric", "--json")
		if err != nil {
			return fmt.Errorf("storage.smb_user.apply delete: verify sessions closed: %w", err)
		}
		live := map[uint64]bool{}
		for _, s := range st.Sessions {
			pid, err := smbdPID(s.ServerID.PID)
			if err != nil {
				return fmt.Errorf("storage.smb_user.apply delete: verify sessions closed: %w", err)
			}
			if signalled[strconv.FormatUint(pid, 10)] || (uidResolved && s.UID != nil && *s.UID == int64(uid)) {
				live[pid] = true
			}
		}
		remaining = sortedPIDs(live)
		if len(remaining) == 0 {
			return nil
		}
		for _, pid := range remaining {
			if !signalled[pid] {
				signal(pid)
			}
		}
	}
	msg := fmt.Sprintf("storage.smb_user.apply delete: sessions still open after close on process(es) %s", strings.Join(remaining, ", "))
	if uidResolved {
		msg += fmt.Sprintf(" (uid %d)", uid)
	}
	var errs []error
	for _, pid := range remaining {
		if err := signalErrs[pid]; err != nil {
			errs = append(errs, fmt.Errorf("close session process %s: %w", pid, err))
		}
	}
	if len(errs) > 0 {
		return fmt.Errorf("%s: %w", msg, errors.Join(errs...))
	}
	return errors.New(msg)
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
