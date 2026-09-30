package storage

import (
	"context"
	"errors"
	"os/exec"
	"reflect"
	"strings"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// IMP-65a2b9f94490 — deleteSambaUser used to discard samba-tool's error and
// never touched the user's open SMB sessions, so a revoked principal kept
// every share it already had mounted. These pin the replacement: delete
// fails loudly except for samba-tool's own "user does not exist" shape, and a
// successful delete is followed by closing that user's live sessions.

const (
	smbDelUser = "svc-share"
	// Argv keys, exactly as the RecorderRunner builds them (name + args).
	keySessionList   = "smbstatus --processes --json"
	keySessionVerify = "smbstatus --processes --numeric --json"
	keyUserDelete    = "samba-tool user delete " + smbDelUser
	keyUserShow      = "samba-tool user show " + smbDelUser
	keyWbinfo        = "wbinfo -i " + smbDelUser

	// wbinfoLine is `wbinfo -i <user>` as observed on a live 4.19.5 AD DC
	// (DOMAIN\user:*:<uid>:<gid>::<home>:<shell>).
	wbinfoLine = "SAMDOM\\svc-share:*:3000017:100::/home/SAMDOM/svc-share:/bin/false\n"
)

func smbDelTask() *SmbUserApplyTask {
	return &SmbUserApplyTask{
		StorageID: "019f7cb5-3858-7000-8000-000000000006",
		AccountID: "019f7cb5-3858-7000-8000-000000000007",
		Action:    "delete",
		Username:  smbDelUser,
	}
}

// sessionsJSON is `smbstatus --processes --json` in the shape observed on a
// live samba 4.19.5 AD DC without libnss-winbind: the username field holds
// the NUMERIC uid, never the name, and server_id.pid is a string. The target
// (uid 3000017) holds sessions on two processes — 4242 twice, and 5151 whose
// pid is written as a JSON number to pin that both encodings decode. 6000 is
// an unrelated user; 7000 is a session whose authentication is still in
// progress (uid -1). Neither may be touched.
const sessionsJSON = `{
  "timestamp": "2026-09-30T09:00:00.000000+0000",
  "version": "4.19.5-Ubuntu",
  "smb_conf": "/etc/samba/smb.conf",
  "sessions": {
    "101": {"session_id": "101", "server_id": {"pid": "4242", "task_id": "0", "vnn": "4294967295", "unique_id": "11"},
            "uid": 3000017, "gid": 100, "username": "3000017", "groupname": "users",
            "remote_machine": "127.0.0.1", "hostname": "ipv4:127.0.0.1:39486", "session_dialect": "SMB3_11",
            "encryption": {"cipher": "-", "degree": "none"}, "signing": {"cipher": "AES-128-GMAC", "degree": "partial"}},
    "102": {"session_id": "102", "server_id": {"pid": "4242", "task_id": "0", "vnn": "4294967295", "unique_id": "11"},
            "uid": 3000017, "gid": 100, "username": "3000017", "groupname": "users",
            "remote_machine": "127.0.0.1", "hostname": "ipv4:127.0.0.1:39486", "session_dialect": "SMB3_11",
            "encryption": {"cipher": "-", "degree": "none"}, "signing": {"cipher": "-", "degree": "none"}},
    "103": {"session_id": "103", "server_id": {"pid": 5151, "task_id": "0", "vnn": "4294967295", "unique_id": "12"},
            "uid": 3000017, "gid": 100, "username": "3000017", "groupname": "users",
            "remote_machine": "10.0.0.6", "hostname": "ipv4:10.0.0.6:40000", "session_dialect": "SMB3_11",
            "encryption": {"cipher": "-", "degree": "none"}, "signing": {"cipher": "-", "degree": "none"}},
    "104": {"session_id": "104", "server_id": {"pid": "6000", "task_id": "0", "vnn": "4294967295", "unique_id": "13"},
            "uid": 3000018, "gid": 100, "username": "3000018", "groupname": "users",
            "remote_machine": "10.0.0.7", "hostname": "ipv4:10.0.0.7:40001", "session_dialect": "SMB3_11",
            "encryption": {"cipher": "-", "degree": "none"}, "signing": {"cipher": "-", "degree": "none"}},
    "105": {"session_id": "105", "server_id": {"pid": "7000", "task_id": "0", "vnn": "4294967295", "unique_id": "14"},
            "uid": -1, "gid": -1, "username": "-1", "groupname": "-1",
            "remote_machine": "10.0.0.8", "hostname": "ipv4:10.0.0.8:40002", "session_dialect": "SMB3_11",
            "encryption": {"cipher": "-", "degree": "none"}, "signing": {"cipher": "-", "degree": "none"}}
  }
}`

// sessionsByNameJSON is the other naming smbstatus can produce — when
// libnss-winbind resolves the uid, username is DOMAIN\user. Used where the
// uid could not be resolved, so only the name can match.
const sessionsByNameJSON = `{"sessions": {
  "201": {"server_id": {"pid": "5151"}, "uid": 3000017, "username": "SAMDOM\\svc-share"},
  "202": {"server_id": {"pid": "6000"}, "uid": 3000018, "username": "SAMDOM\\svc-share2"}}}`

// afterKillJSON is the numeric post-kill listing: only the unrelated
// processes are left.
const afterKillJSON = `{"sessions": {
  "104": {"server_id": {"pid": "6000"}, "uid": 3000018, "username": "3000018"},
  "105": {"server_id": {"pid": 7000}, "uid": -1, "username": "-1"}}}`

// delRecorder is a RecorderRunner whose wbinfo resolves the target and whose
// first smbstatus returns list; extra entries are merged over it.
func delRecorder(list string, extraOut map[string][]byte, errs map[string]error) *mount.RecorderRunner {
	out := map[string][]byte{keyWbinfo: []byte(wbinfoLine), keySessionList: []byte(list)}
	for k, v := range extraOut {
		out[k] = v
	}
	return &mount.RecorderRunner{StubOutput: out, StubErr: errs}
}

// execRunnerError produces an error with EXACTLY the shape the production
// runner (mount.ExecRunner.Run) returns for a failing samba-tool: a real
// *exec.ExitError wrapped with the argv and the captured stderr. It runs a
// stand-in via sh that writes stderrText and exits with code; only the argv
// in the message differs from samba-tool's — the wrapped ExitError and the
// captured output are the real thing, not a hand-built string.
func execRunnerError(t *testing.T, stderrText string, code string) error {
	t.Helper()
	err := mount.ExecRunner{}.Run(context.Background(), "sh", "-c", `printf '%s\n' "$0" >&2; exit `+code, stderrText)
	if err == nil {
		t.Fatal("stand-in command unexpectedly succeeded")
	}
	var ee *exec.ExitError
	if !errors.As(err, &ee) {
		t.Fatalf("ExecRunner error does not wrap *exec.ExitError: %v", err)
	}
	return err
}

// notFoundErr is samba-tool 4.19.5's missing-user failure: cmd_user_delete
// raises CommandError('Unable to find user "%s"'), show_command_error prints
// it via _print_error as `ERROR: <msg>` (no klass: inner_exception is None;
// no colour: stderr is not a tty), and Command._run returns -1 → exit 255.
func notFoundErr(t *testing.T, user string) error {
	return execRunnerError(t, `ERROR: Unable to find user "`+user+`"`, "255")
}

// showNotFoundErr is `samba-tool user show` for a missing user (4.19.5
// user.py get_account_attributes → CommandError wrapping the empty search).
func showNotFoundErr(t *testing.T, user string) error {
	return execRunnerError(t, `ERROR: Failed to get password for user '`+user+`': Unable to find user "`+user+`"`, "255")
}

func TestDeleteSambaUser_ExactArgvSequenceAndNoShell(t *testing.T) {
	rec := delRecorder(sessionsJSON, map[string][]byte{keySessionVerify: []byte(afterKillJSON)}, nil)
	if err := ApplySambaUser(context.Background(), rec, nil, smbDelTask()); err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	want := []mount.Invocation{
		{Op: "Output", Name: "wbinfo", Args: []string{"-i", smbDelUser}},
		{Op: "Output", Name: "smbstatus", Args: []string{"--processes", "--json"}},
		{Op: "Run", Name: "samba-tool", Args: []string{"user", "delete", smbDelUser}},
		{Op: "Run", Name: "smbcontrol", Args: []string{"4242", "shutdown"}},
		{Op: "Run", Name: "smbcontrol", Args: []string{"5151", "shutdown"}},
		{Op: "Output", Name: "smbstatus", Args: []string{"--processes", "--numeric", "--json"}},
	}
	if !reflect.DeepEqual(rec.Invocations, want) {
		t.Fatalf("argv sequence mismatch\n got: %+v\nwant: %+v", rec.Invocations, want)
	}
	for _, inv := range rec.Invocations {
		if inv.Name == "sh" || inv.Name == "bash" || inv.Name == "/bin/sh" {
			t.Fatalf("no invocation may go through a shell: %+v", inv)
		}
	}
}

// The live shape: username holds the numeric uid, so only the resolved uid
// can find the session. A name-only matcher saw nothing here on a real DC.
func TestDeleteSambaUser_MatchesTheLiveNumericUsernameShapeByUID(t *testing.T) {
	live := `{"sessions": {"1": {"session_id": "1", "server_id": {"pid": "30046", "task_id": "0", "vnn": "4294967295", "unique_id": "9"},
	  "uid": 3000017, "gid": 100, "username": "3000017", "groupname": "users",
	  "remote_machine": "127.0.0.1", "hostname": "ipv4:127.0.0.1:39486"}}}`
	rec := delRecorder(live, map[string][]byte{keySessionVerify: []byte(`{"sessions": {}}`)}, nil)
	if err := ApplySambaUser(context.Background(), rec, nil, smbDelTask()); err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if !sambaArgsContain(rec, "smbcontrol", "30046") {
		t.Fatalf("the session listed under the numeric uid must be closed; got %+v", rec.Invocations)
	}
}

// Secondary: when the account is already gone (wbinfo cannot resolve it and
// samba-tool user show reports not-found), the name form still matches.
func TestDeleteSambaUser_UnresolvedAbsentUserFallsBackToNameMatch(t *testing.T) {
	rec := &mount.RecorderRunner{
		StubOutput: map[string][]byte{
			keySessionList:   []byte(sessionsByNameJSON),
			keySessionVerify: []byte(`{"sessions": {}}`),
		},
		StubErr: map[string]error{
			keyWbinfo:     errors.New("wbinfo [-i svc-share]: exit status 1"),
			keyUserShow:   showNotFoundErr(t, smbDelUser),
			keyUserDelete: notFoundErr(t, smbDelUser),
		},
	}
	if err := ApplySambaUser(context.Background(), rec, nil, smbDelTask()); err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	want := []mount.Invocation{
		{Op: "Output", Name: "wbinfo", Args: []string{"-i", smbDelUser}},
		{Op: "Run", Name: "samba-tool", Args: []string{"user", "show", smbDelUser}},
		{Op: "Output", Name: "smbstatus", Args: []string{"--processes", "--json"}},
		{Op: "Run", Name: "samba-tool", Args: []string{"user", "delete", smbDelUser}},
		{Op: "Run", Name: "smbcontrol", Args: []string{"5151", "shutdown"}},
		{Op: "Output", Name: "smbstatus", Args: []string{"--processes", "--numeric", "--json"}},
	}
	if !reflect.DeepEqual(rec.Invocations, want) {
		t.Fatalf("argv sequence mismatch\n got: %+v\nwant: %+v", rec.Invocations, want)
	}
}

// An account that exists but whose uid cannot be resolved must fail BEFORE
// the delete: afterwards its sessions could never be identified.
func TestDeleteSambaUser_UnresolvableUIDForExistingUserFailsBeforeDelete(t *testing.T) {
	for name, showErr := range map[string]error{
		"user exists":        nil,
		"show fails another": execRunnerError(t, `ERROR(ldb): Failed to connect - Operations error`, "255"),
		"other user absent":  showNotFoundErr(t, smbDelUser+"2"),
	} {
		t.Run(name, func(t *testing.T) {
			errs := map[string]error{keyWbinfo: errors.New("wbinfo [-i svc-share]: exit status 1")}
			if showErr != nil {
				errs[keyUserShow] = showErr
			}
			rec := &mount.RecorderRunner{StubErr: errs}
			if err := ApplySambaUser(context.Background(), rec, nil, smbDelTask()); err == nil {
				t.Fatal("expected failure: the uid of a user that may exist could not be resolved")
			}
			for _, inv := range rec.Invocations {
				if inv.Name == "smbstatus" || inv.Name == "smbcontrol" || (inv.Name == "samba-tool" && inv.Args[1] == "delete") {
					t.Fatalf("nothing may be listed, deleted or signalled: %+v", rec.Invocations)
				}
			}
		})
	}
}

func TestDeleteSambaUser_RefusesAWbinfoLineThatIsNotThisUsersUID(t *testing.T) {
	for name, line := range map[string]string{
		"other user":   "SAMDOM\\svc-share2:*:3000018:100::/home/SAMDOM/svc-share2:/bin/false\n",
		"uid zero":     "SAMDOM\\svc-share:*:0:0::/root:/bin/sh\n",
		"uid sentinel": "SAMDOM\\svc-share:*:4294967295:100::/:/bin/false\n",
		"uid not int":  "SAMDOM\\svc-share:*:x:100::/:/bin/false\n",
		"wrong shape":  "SAMDOM\\svc-share:3000017\n",
		"two lines":    wbinfoLine + wbinfoLine,
		"empty":        "",
	} {
		t.Run(name, func(t *testing.T) {
			rec := &mount.RecorderRunner{StubOutput: map[string][]byte{keyWbinfo: []byte(line)}}
			if err := ApplySambaUser(context.Background(), rec, nil, smbDelTask()); err == nil {
				t.Fatalf("expected refusal; invocations %+v", rec.Invocations)
			}
			if len(rec.Invocations) != 1 {
				t.Fatalf("nothing may run after a refused wbinfo line: %+v", rec.Invocations)
			}
		})
	}
}

func TestDeleteSambaUser_DeleteFailureFailsTheTask(t *testing.T) {
	rec := delRecorder(sessionsJSON, nil, map[string]error{
		keyUserDelete: execRunnerError(t, `ERROR(ldb): Failed to remove user "svc-share" - Insufficient access`, "255"),
	})
	err := ApplySambaUser(context.Background(), rec, nil, smbDelTask())
	if err == nil {
		t.Fatal("a failed samba-tool user delete must fail the task")
	}
	for _, inv := range rec.Invocations {
		if inv.Name == "smbcontrol" {
			t.Fatalf("sessions must not be closed when the delete itself failed: %+v", rec.Invocations)
		}
	}
}

func TestDeleteSambaUser_NotFoundShapeIsIdempotentSuccess(t *testing.T) {
	rec := &mount.RecorderRunner{
		StubOutput: map[string][]byte{keySessionList: []byte(`{"sessions": {}}`)},
		StubErr: map[string]error{
			keyWbinfo:     errors.New("wbinfo [-i svc-share]: exit status 1"),
			keyUserShow:   showNotFoundErr(t, smbDelUser),
			keyUserDelete: notFoundErr(t, smbDelUser),
		},
	}
	if err := ApplySambaUser(context.Background(), rec, nil, smbDelTask()); err != nil {
		t.Fatalf("samba-tool's missing-user shape must be success (idempotent delete); got %v", err)
	}
}

// The not-found text for a DIFFERENT name, or the right text under a
// different exit code, is not this user's not-found — both must still fail.
func TestDeleteSambaUser_NotFoundShapeMustMatchUserAndExitCode(t *testing.T) {
	for name, stub := range map[string]error{
		"other user":          notFoundErr(t, smbDelUser+"2"),
		"wrong exit code":     execRunnerError(t, `ERROR: Unable to find user "`+smbDelUser+`"`, "1"),
		"text without exit":   errors.New(`samba-tool [user delete svc-share]: (output: ERROR: Unable to find user "svc-share")`),
		"missing ERROR label": execRunnerError(t, `Unable to find user "`+smbDelUser+`" in cache`, "255"),
	} {
		t.Run(name, func(t *testing.T) {
			rec := delRecorder(`{"sessions": {}}`, nil, map[string]error{keyUserDelete: stub})
			if err := ApplySambaUser(context.Background(), rec, nil, smbDelTask()); err == nil {
				t.Fatal("expected failure: this is not samba-tool's missing-user shape for this user")
			}
		})
	}
}

func TestDeleteSambaUser_SessionKillFailureFailsTheTaskAfterDelete(t *testing.T) {
	rec := delRecorder(sessionsJSON, nil, map[string]error{"smbcontrol 4242 shutdown": errors.New("smbcontrol [4242 shutdown]: exit status 1")})
	err := ApplySambaUser(context.Background(), rec, nil, smbDelTask())
	if err == nil {
		t.Fatal("a failed session close must fail the task")
	}
	deleted := false
	for _, inv := range rec.Invocations {
		if inv.Name == "samba-tool" {
			deleted = true
		}
		if inv.Name == "smbcontrol" && !deleted {
			t.Fatalf("sessions must be closed only AFTER the delete: %+v", rec.Invocations)
		}
	}
	if !deleted {
		t.Fatalf("the delete must have run before the session close failed: %+v", rec.Invocations)
	}
}

func TestDeleteSambaUser_SessionStillListedAfterKillFailsTheTask(t *testing.T) {
	prevPolls, prevInterval := smbSessionGonePolls, smbSessionGoneInterval
	smbSessionGonePolls, smbSessionGoneInterval = 3, 0
	t.Cleanup(func() { smbSessionGonePolls, smbSessionGoneInterval = prevPolls, prevInterval })

	// 4242 and 5151 (the latter as a JSON number) never go away.
	rec := delRecorder(sessionsJSON, map[string][]byte{keySessionVerify: []byte(sessionsJSON)}, nil)
	err := ApplySambaUser(context.Background(), rec, nil, smbDelTask())
	if err == nil || !strings.Contains(err.Error(), "4242") || !strings.Contains(err.Error(), "5151") {
		t.Fatalf("a session that survives the close must fail the task, naming its processes; got %v", err)
	}
	polls := 0
	for _, inv := range rec.Invocations {
		if inv.Name == "smbstatus" && reflect.DeepEqual(inv.Args, []string{"--processes", "--numeric", "--json"}) {
			polls++
		}
	}
	if polls != 3 {
		t.Fatalf("expected the post-close check to poll %d times; got %d", 3, polls)
	}
}

// Enumeration runs BEFORE the delete (the account still exists then). If it
// fails, nothing is mutated, so a retry starts from the same state.
func TestDeleteSambaUser_EnumerationFailureMutatesNothing(t *testing.T) {
	rec := delRecorder("", nil, map[string]error{keySessionList: errors.New("smbstatus: not found")})
	if err := ApplySambaUser(context.Background(), rec, nil, smbDelTask()); err == nil {
		t.Fatal("a failed session enumeration must fail the task")
	}
	for _, inv := range rec.Invocations {
		if inv.Name != "smbstatus" && inv.Name != "wbinfo" {
			t.Fatalf("nothing may run after a failed enumeration: %+v", rec.Invocations)
		}
	}
}

func TestDeleteSambaUser_MalformedSessionListFailsClosed(t *testing.T) {
	for name, body := range map[string]string{
		"not json":       `Samba version 4.19.5`,
		"no sessions":    `{"timestamp": "x"}`,
		"pid not int":    `{"sessions": {"1": {"server_id": {"pid": "12;rm"}, "uid": 3000017}}}`,
		"pid is init":    `{"sessions": {"1": {"server_id": {"pid": "1"}, "uid": 3000017}}}`,
		"pid num init":   `{"sessions": {"1": {"server_id": {"pid": 1}, "uid": 3000017}}}`,
		"pid is empty":   `{"sessions": {"1": {"server_id": {"pid": ""}, "uid": 3000017}}}`,
		"pid missing":    `{"sessions": {"1": {"server_id": {}, "uid": 3000017}}}`,
		"pid negative":   `{"sessions": {"1": {"server_id": {"pid": -5}, "uid": 3000017}}}`,
		"pid fractional": `{"sessions": {"1": {"server_id": {"pid": 42.5}, "uid": 3000017}}}`,
	} {
		t.Run(name, func(t *testing.T) {
			rec := delRecorder(body, nil, nil)
			if err := ApplySambaUser(context.Background(), rec, nil, smbDelTask()); err == nil {
				t.Fatalf("expected a fail-closed refusal; invocations %+v", rec.Invocations)
			}
			for _, inv := range rec.Invocations {
				if inv.Name == "smbcontrol" || inv.Name == "samba-tool" {
					t.Fatalf("nothing may be deleted or signalled on a malformed listing: %+v", rec.Invocations)
				}
			}
		})
	}
}

func TestDeleteSambaUser_NoSessionsSkipsTheClose(t *testing.T) {
	rec := delRecorder(`{"sessions": {}}`, nil, nil)
	if err := ApplySambaUser(context.Background(), rec, nil, smbDelTask()); err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	want := []mount.Invocation{
		{Op: "Output", Name: "wbinfo", Args: []string{"-i", smbDelUser}},
		{Op: "Output", Name: "smbstatus", Args: []string{"--processes", "--json"}},
		{Op: "Run", Name: "samba-tool", Args: []string{"user", "delete", smbDelUser}},
	}
	if !reflect.DeepEqual(rec.Invocations, want) {
		t.Fatalf("argv sequence mismatch\n got: %+v\nwant: %+v", rec.Invocations, want)
	}
}
