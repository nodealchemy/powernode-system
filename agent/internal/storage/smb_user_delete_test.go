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
)

func smbDelTask() *SmbUserApplyTask {
	return &SmbUserApplyTask{
		StorageID: "019f7cb5-3858-7000-8000-000000000006",
		AccountID: "019f7cb5-3858-7000-8000-000000000007",
		Action:    "delete",
		Username:  smbDelUser,
	}
}

// sessionsJSON is the `smbstatus --processes --json` shape (samba 4.19.5,
// source3/utils/status_json.c traverse_sessionid_json + add_server_id_to_json:
// server_id.pid is a STRING, uid/gid are ints, username is uidtoname()).
// Two sessions for the target (one domain-qualified, one bare, on distinct
// processes, plus a second session on the first process) and one for an
// unrelated user whose process must never be touched.
const sessionsJSON = `{
  "timestamp": "2026-09-30T09:00:00.000000+0000",
  "version": "4.19.5-Ubuntu",
  "smb_conf": "/etc/samba/smb.conf",
  "sessions": {
    "101": {"session_id": "101", "server_id": {"pid": "4242", "task_id": "0", "vnn": "4294967295", "unique_id": "11"},
            "uid": 3000017, "gid": 100, "username": "SAMDOM\\svc-share", "groupname": "SAMDOM\\domain users",
            "remote_machine": "10.0.0.5", "hostname": "ipv4:10.0.0.5:51234", "session_dialect": "SMB3_11",
            "encryption": {"cipher": "-", "degree": "none"}, "signing": {"cipher": "AES-128-GMAC", "degree": "partial"}},
    "102": {"session_id": "102", "server_id": {"pid": "4242", "task_id": "0", "vnn": "4294967295", "unique_id": "11"},
            "uid": 3000017, "gid": 100, "username": "SAMDOM\\svc-share", "groupname": "SAMDOM\\domain users",
            "remote_machine": "10.0.0.5", "hostname": "ipv4:10.0.0.5:51234", "session_dialect": "SMB3_11",
            "encryption": {"cipher": "-", "degree": "none"}, "signing": {"cipher": "-", "degree": "none"}},
    "103": {"session_id": "103", "server_id": {"pid": "5151", "task_id": "0", "vnn": "4294967295", "unique_id": "12"},
            "uid": 3000017, "gid": 100, "username": "svc-share", "groupname": "domain users",
            "remote_machine": "10.0.0.6", "hostname": "ipv4:10.0.0.6:40000", "session_dialect": "SMB3_11",
            "encryption": {"cipher": "-", "degree": "none"}, "signing": {"cipher": "-", "degree": "none"}},
    "104": {"session_id": "104", "server_id": {"pid": "6000", "task_id": "0", "vnn": "4294967295", "unique_id": "13"},
            "uid": 3000018, "gid": 100, "username": "SAMDOM\\svc-share2", "groupname": "SAMDOM\\domain users",
            "remote_machine": "10.0.0.7", "hostname": "ipv4:10.0.0.7:40001", "session_dialect": "SMB3_11",
            "encryption": {"cipher": "-", "degree": "none"}, "signing": {"cipher": "-", "degree": "none"}}
  }
}`

// afterKillJSON is the numeric post-kill listing: only the unrelated user's
// process is left.
const afterKillJSON = `{"sessions": {"104": {"session_id": "104",
  "server_id": {"pid": "6000", "task_id": "0", "vnn": "4294967295", "unique_id": "13"},
  "uid": 3000018, "gid": 100, "username": "3000018", "groupname": "100"}}}`

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

func TestDeleteSambaUser_ExactArgvSequenceAndNoShell(t *testing.T) {
	rec := &mount.RecorderRunner{StubOutput: map[string][]byte{
		keySessionList:   []byte(sessionsJSON),
		keySessionVerify: []byte(afterKillJSON),
	}}
	if err := ApplySambaUser(context.Background(), rec, nil, smbDelTask()); err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	want := []mount.Invocation{
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

func TestDeleteSambaUser_DeleteFailureFailsTheTask(t *testing.T) {
	rec := &mount.RecorderRunner{
		StubOutput: map[string][]byte{keySessionList: []byte(sessionsJSON)},
		StubErr: map[string]error{
			keyUserDelete: execRunnerError(t, `ERROR(ldb): Failed to remove user "svc-share" - Insufficient access`, "255"),
		},
	}
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
		StubErr:    map[string]error{keyUserDelete: notFoundErr(t, smbDelUser)},
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
			rec := &mount.RecorderRunner{
				StubOutput: map[string][]byte{keySessionList: []byte(`{"sessions": {}}`)},
				StubErr:    map[string]error{keyUserDelete: stub},
			}
			if err := ApplySambaUser(context.Background(), rec, nil, smbDelTask()); err == nil {
				t.Fatal("expected failure: this is not samba-tool's missing-user shape for this user")
			}
		})
	}
}

func TestDeleteSambaUser_SessionKillFailureFailsTheTaskAfterDelete(t *testing.T) {
	rec := &mount.RecorderRunner{
		StubOutput: map[string][]byte{keySessionList: []byte(sessionsJSON)},
		StubErr:    map[string]error{"smbcontrol 4242 shutdown": errors.New("smbcontrol [4242 shutdown]: exit status 1")},
	}
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

	rec := &mount.RecorderRunner{StubOutput: map[string][]byte{
		keySessionList:   []byte(sessionsJSON),
		keySessionVerify: []byte(sessionsJSON), // 4242 and 5151 never go away
	}}
	err := ApplySambaUser(context.Background(), rec, nil, smbDelTask())
	if err == nil || !strings.Contains(err.Error(), "4242") {
		t.Fatalf("a session that survives the close must fail the task, naming its process; got %v", err)
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

// Enumeration runs BEFORE the delete (the name still resolves then). If it
// fails, nothing is mutated, so a retry starts from the same state.
func TestDeleteSambaUser_EnumerationFailureMutatesNothing(t *testing.T) {
	rec := &mount.RecorderRunner{StubErr: map[string]error{keySessionList: errors.New("smbstatus: not found")}}
	if err := ApplySambaUser(context.Background(), rec, nil, smbDelTask()); err == nil {
		t.Fatal("a failed session enumeration must fail the task")
	}
	for _, inv := range rec.Invocations {
		if inv.Name != "smbstatus" {
			t.Fatalf("nothing may run after a failed enumeration: %+v", rec.Invocations)
		}
	}
}

func TestDeleteSambaUser_MalformedSessionListFailsClosed(t *testing.T) {
	for name, body := range map[string]string{
		"not json":     `Samba version 4.19.5`,
		"pid not int":  `{"sessions": {"1": {"server_id": {"pid": "12;rm"}, "username": "svc-share"}}}`,
		"pid is init":  `{"sessions": {"1": {"server_id": {"pid": "1"}, "username": "svc-share"}}}`,
		"pid is empty": `{"sessions": {"1": {"server_id": {"pid": ""}, "username": "svc-share"}}}`,
	} {
		t.Run(name, func(t *testing.T) {
			rec := &mount.RecorderRunner{StubOutput: map[string][]byte{keySessionList: []byte(body)}}
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
	rec := &mount.RecorderRunner{StubOutput: map[string][]byte{keySessionList: []byte(`{"sessions": {}}`)}}
	if err := ApplySambaUser(context.Background(), rec, nil, smbDelTask()); err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	want := []mount.Invocation{
		{Op: "Output", Name: "smbstatus", Args: []string{"--processes", "--json"}},
		{Op: "Run", Name: "samba-tool", Args: []string{"user", "delete", smbDelUser}},
	}
	if !reflect.DeepEqual(rec.Invocations, want) {
		t.Fatalf("argv sequence mismatch\n got: %+v\nwant: %+v", rec.Invocations, want)
	}
}
