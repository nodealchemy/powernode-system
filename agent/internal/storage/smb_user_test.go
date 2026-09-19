package storage

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// IMP-ab6e4075a007 — the password used to travel inline on the task
// (task.Password / task.NewPassword). These pin the replacement: the handler
// resolves it via the credential fetch (fetchCredential → the node_api
// endpoint), never from a field on the task itself, using the SAME pinned
// URL shape (?credential_id=<uuid>) the platform's
// StorageAssignmentsController#resolve_credential now requires.

const (
	smbTestAssignmentID = "019f7cb5-3858-7000-8000-0000000000a1"
	smbTestCredID       = "019f7cb5-3858-7000-8000-0000000000a2"
	smbTestNewCredID    = "019f7cb5-3858-7000-8000-0000000000a3"
)

func smbCredURL(credID string) string {
	return "/api/v1/system/node_api/storage_assignments/" + smbTestAssignmentID + "/credential?credential_id=" + credID
}

// sambaCredentialBody encodes via encoding/json (not string interpolation)
// so a password carrying a control character round-trips as VALID JSON —
// hand-rolled interpolation would put a raw unescaped byte inside a JSON
// string, which breaks json.Unmarshal in fetchCredential for a reason that
// has nothing to do with the taskguard.Secret check these tests exist to
// exercise, and would pass red-first for the wrong cause.
func sambaCredentialBody(password string) string {
	body, err := json.Marshal(map[string]any{
		"success": true,
		"data": map[string]any{
			"kind":     "cifs_user_pass",
			"username": "node-abc123",
			"password": password,
		},
	})
	if err != nil {
		panic(err)
	}
	return string(body)
}

func sambaArgsContain(rec *mount.RecorderRunner, name, value string) bool {
	for _, inv := range rec.Invocations {
		if inv.Name != name {
			continue
		}
		for _, a := range inv.Args {
			if a == value {
				return true
			}
		}
	}
	return false
}

// sambaStdinContains checks the RunStdin-delivered secret, never argv —
// IMP-ad2c66a838f2. Every samba-tool invocation that carries a password now
// goes through RunStdin (see redactedRun), so this is the counterpart
// sambaArgsContain's callers use for password assertions.
func sambaStdinContains(rec *mount.RecorderRunner, name, value string) bool {
	for _, inv := range rec.Invocations {
		if inv.Op != "RunStdin" || inv.Name != name {
			continue
		}
		if strings.Contains(inv.Stdin, value) {
			return true
		}
	}
	return false
}

func TestApplySambaUser_CreateResolvesPasswordFromCredentialEndpoint(t *testing.T) {
	rec := &mount.RecorderRunner{}
	getter := stubGetter{body: sambaCredentialBody("fetched-pw")}
	task := &SmbUserApplyTask{
		StorageID: "019f7cb5-3858-7000-8000-000000000006",
		AccountID: "019f7cb5-3858-7000-8000-000000000007",
		Action:    "create",
		Username:  "svc-share",
		Credential: CredentialRef{
			ID: smbTestCredID, Kind: "cifs_user_pass",
			URL: smbCredURL(smbTestCredID),
		},
	}
	if err := ApplySambaUser(context.Background(), rec, getter, task); err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if !sambaStdinContains(rec, "samba-tool", "fetched-pw") {
		t.Fatalf("expected samba-tool to run with the fetched password via stdin; got %+v", rec.Invocations)
	}
	if sambaArgsContain(rec, "samba-tool", "fetched-pw") {
		t.Fatalf("the fetched password must never appear in argv; got %+v", rec.Invocations)
	}
}

func TestApplySambaUser_CreateFallsThroughToSetPasswordOnExistingUser(t *testing.T) {
	rec := &mount.RecorderRunner{
		StubErr: map[string]error{
			"samba-tool user create svc-share": errUserExists,
		},
	}
	getter := stubGetter{body: sambaCredentialBody("fetched-pw")}
	task := &SmbUserApplyTask{
		StorageID:  "019f7cb5-3858-7000-8000-000000000006",
		AccountID:  "019f7cb5-3858-7000-8000-000000000007",
		Action:     "create",
		Username:   "svc-share",
		Credential: CredentialRef{ID: smbTestCredID, URL: smbCredURL(smbTestCredID)},
	}
	if err := ApplySambaUser(context.Background(), rec, getter, task); err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if !sambaStdinContains(rec, "samba-tool", "fetched-pw") {
		t.Fatalf("expected the setpassword fallback to run with the fetched password via stdin; got %+v", rec.Invocations)
	}
	if sambaArgsContain(rec, "samba-tool", "--newpassword=fetched-pw") || sambaArgsContain(rec, "samba-tool", "fetched-pw") {
		t.Fatalf("the fetched password must never appear in argv; got %+v", rec.Invocations)
	}
}

func TestApplySambaUser_SetPasswordPrefersNewCredentialOverCredential(t *testing.T) {
	rec := &mount.RecorderRunner{}
	getter := &multiURLGetter{
		responses: map[string]string{
			smbCredURL(smbTestCredID):    sambaCredentialBody("old-pw"),
			smbCredURL(smbTestNewCredID): sambaCredentialBody("rotated-pw"),
		},
	}
	task := &SmbUserApplyTask{
		StorageID:     "019f7cb5-3858-7000-8000-000000000006",
		AccountID:     "019f7cb5-3858-7000-8000-000000000007",
		Action:        "set_password",
		Username:      "svc-share",
		Credential:    CredentialRef{ID: smbTestCredID, URL: smbCredURL(smbTestCredID)},
		NewCredential: CredentialRef{ID: smbTestNewCredID, URL: smbCredURL(smbTestNewCredID)},
	}
	if err := ApplySambaUser(context.Background(), rec, getter, task); err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if !sambaStdinContains(rec, "samba-tool", "rotated-pw") {
		t.Fatalf("expected setpassword to use the NEW credential's password via stdin; got %+v", rec.Invocations)
	}
	if sambaStdinContains(rec, "samba-tool", "old-pw") {
		t.Fatalf("setpassword must not fall back to the old credential when a new one is present; got %+v", rec.Invocations)
	}
	if sambaArgsContain(rec, "samba-tool", "--newpassword=rotated-pw") || sambaArgsContain(rec, "samba-tool", "--newpassword=old-pw") {
		t.Fatalf("neither password may ever appear in argv; got %+v", rec.Invocations)
	}
}

func TestApplySambaUser_SetPasswordFallsBackToCredentialWhenNoNewCredential(t *testing.T) {
	rec := &mount.RecorderRunner{}
	getter := stubGetter{body: sambaCredentialBody("only-pw")}
	task := &SmbUserApplyTask{
		StorageID:  "019f7cb5-3858-7000-8000-000000000006",
		AccountID:  "019f7cb5-3858-7000-8000-000000000007",
		Action:     "set_password",
		Username:   "svc-share",
		Credential: CredentialRef{ID: smbTestCredID, URL: smbCredURL(smbTestCredID)},
	}
	if err := ApplySambaUser(context.Background(), rec, getter, task); err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if !sambaStdinContains(rec, "samba-tool", "only-pw") {
		t.Fatalf("expected setpassword to fall back to Credential's password via stdin; got %+v", rec.Invocations)
	}
	if sambaArgsContain(rec, "samba-tool", "--newpassword=only-pw") {
		t.Fatalf("the password must never appear in argv; got %+v", rec.Invocations)
	}
}

func TestApplySambaUser_DeleteNeverFetchesACredential(t *testing.T) {
	rec := &mount.RecorderRunner{}
	getter := stubGetter{err: errFetchMustNotHappen}
	task := &SmbUserApplyTask{
		StorageID:  "019f7cb5-3858-7000-8000-000000000006",
		AccountID:  "019f7cb5-3858-7000-8000-000000000007",
		Action:     "delete",
		Username:   "svc-share",
		Credential: CredentialRef{ID: smbTestCredID, URL: smbCredURL(smbTestCredID)},
	}
	if err := ApplySambaUser(context.Background(), rec, getter, task); err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if !sambaArgsContain(rec, "samba-tool", "delete") {
		t.Fatalf("expected samba-tool delete to run; got %+v", rec.Invocations)
	}
}

func TestApplySambaUser_CreateFailsClosedOnEmptyFetchedPassword(t *testing.T) {
	rec := &mount.RecorderRunner{}
	getter := stubGetter{body: `{"success":true,"data":{"kind":"cifs_user_pass","username":"node-abc123","password":""}}`}
	task := &SmbUserApplyTask{
		StorageID:  "019f7cb5-3858-7000-8000-000000000006",
		AccountID:  "019f7cb5-3858-7000-8000-000000000007",
		Action:     "create",
		Username:   "svc-share",
		Credential: CredentialRef{ID: smbTestCredID, URL: smbCredURL(smbTestCredID)},
	}
	if err := ApplySambaUser(context.Background(), rec, getter, task); err == nil {
		t.Fatal("expected an error when the credential endpoint returns an empty password")
	}
	if len(rec.Invocations) != 0 {
		t.Fatalf("expected samba-tool never to run on an empty fetched password, got %+v", rec.Invocations)
	}
}

// --- RULE: the fetched password is checked with taskguard.Secret before it
// ever reaches argv, and it is value-free so a refusal can't leak it. -------

func TestApplySambaUser_RefusesAFetchedPasswordThatBeginsWithADash(t *testing.T) {
	rec := &mount.RecorderRunner{}
	getter := stubGetter{body: sambaCredentialBody("-x")}
	task := &SmbUserApplyTask{
		StorageID:  "019f7cb5-3858-7000-8000-000000000006",
		AccountID:  "019f7cb5-3858-7000-8000-000000000007",
		Action:     "create",
		Username:   "svc-share",
		Credential: CredentialRef{ID: smbTestCredID, URL: smbCredURL(smbTestCredID)},
	}
	err := ApplySambaUser(context.Background(), rec, getter, task)
	if err == nil {
		t.Fatal("expected a refusal for a fetched password that would become a samba-tool flag")
	}
	if strings.Contains(err.Error(), "-x") {
		t.Fatalf("refusal echoed the fetched password: %v", err)
	}
	if len(rec.Invocations) != 0 {
		t.Fatalf("expected samba-tool never to run, got %+v", rec.Invocations)
	}
}

func TestApplySambaUser_RefusesAFetchedPasswordWithControlCharacters(t *testing.T) {
	rec := &mount.RecorderRunner{}
	const secret = "correct-horse-battery-staple\nZZ"
	getter := stubGetter{body: sambaCredentialBody(secret)}
	task := &SmbUserApplyTask{
		StorageID:  "019f7cb5-3858-7000-8000-000000000006",
		AccountID:  "019f7cb5-3858-7000-8000-000000000007",
		Action:     "create",
		Username:   "svc-share",
		Credential: CredentialRef{ID: smbTestCredID, URL: smbCredURL(smbTestCredID)},
	}
	err := ApplySambaUser(context.Background(), rec, getter, task)
	if err == nil {
		t.Fatal("expected a refusal for a fetched password containing a newline")
	}
	if strings.Contains(err.Error(), secret) || strings.Contains(err.Error(), "correct-horse-battery-staple") {
		t.Fatalf("refusal echoed the fetched password: %v", err)
	}
	if len(rec.Invocations) != 0 {
		t.Fatalf("expected samba-tool never to run, got %+v", rec.Invocations)
	}
}

// --- RULE: a samba-tool failure must never echo the password it was run
// with — mount.ExecRunner formats the full argv (and captured stdout/stderr)
// into its error, and the runtime loop posts that error's .Error() text
// verbatim as the task's persisted error_message (tasks/client.go Fail). ----

func TestApplySambaUser_CreateFailureNeverEchoesThePasswordOnFallbackFailure(t *testing.T) {
	const password = "s3cret-should-never-leak"
	rec := &mount.RecorderRunner{
		StubErr: map[string]error{
			"samba-tool user create svc-share":      errUserExists,
			"samba-tool user setpassword svc-share": errors.New("samba-tool user setpassword svc-share: exit status 1 (output: bad password " + password + ")"),
		},
	}
	getter := stubGetter{body: sambaCredentialBody(password)}
	task := &SmbUserApplyTask{
		StorageID:  "019f7cb5-3858-7000-8000-000000000006",
		AccountID:  "019f7cb5-3858-7000-8000-000000000007",
		Action:     "create",
		Username:   "svc-share",
		Credential: CredentialRef{ID: smbTestCredID, URL: smbCredURL(smbTestCredID)},
	}
	err := ApplySambaUser(context.Background(), rec, getter, task)
	if err == nil {
		t.Fatal("expected the setpassword fallback failure to propagate")
	}
	if strings.Contains(err.Error(), password) {
		t.Fatalf("returned error echoed the password: %v", err)
	}
}

func TestApplySambaUser_SetPasswordFailureNeverEchoesThePassword(t *testing.T) {
	const password = "another-secret-value"
	rec := &mount.RecorderRunner{
		StubErr: map[string]error{
			"samba-tool user setpassword svc-share": errors.New("samba-tool user setpassword svc-share: exit status 1 (output: bad password " + password + ")"),
		},
	}
	getter := stubGetter{body: sambaCredentialBody(password)}
	task := &SmbUserApplyTask{
		StorageID:  "019f7cb5-3858-7000-8000-000000000006",
		AccountID:  "019f7cb5-3858-7000-8000-000000000007",
		Action:     "set_password",
		Username:   "svc-share",
		Credential: CredentialRef{ID: smbTestCredID, URL: smbCredURL(smbTestCredID)},
	}
	err := ApplySambaUser(context.Background(), rec, getter, task)
	if err == nil {
		t.Fatal("expected the setpassword failure to propagate")
	}
	if strings.Contains(err.Error(), password) {
		t.Fatalf("returned error echoed the password (including the stderr-capture copy): %v", err)
	}
}

// --- RULE (IMP-ad2c66a838f2): the password is NEVER an argument to
// samba-tool — not the "create" positional, not --newpassword= — and never
// an environment variable either. It travels via stdin only. -------------

// TestApplySambaUser_PasswordNeverInArgvAcrossAllActions is the
// consolidated, red-first assertion for the finding itself: for every
// action that touches a password (create, create-falls-through-to-
// setpassword, and standalone set_password), no argv token anywhere in the
// invocation list ever equals or embeds the secret, while RunStdin's Stdin
// field carries it. Reverting redactedRun to its old argv-based form (or
// re-adding the password/--newpassword= argument) turns this red.
func TestApplySambaUser_PasswordNeverInArgvAcrossAllActions(t *testing.T) {
	const password = "argv-must-never-see-this-9f3a"

	cases := []struct {
		name string
		task *SmbUserApplyTask
		rec  *mount.RecorderRunner
	}{
		{
			name: "create",
			task: &SmbUserApplyTask{
				StorageID: "019f7cb5-3858-7000-8000-000000000006", AccountID: "019f7cb5-3858-7000-8000-000000000007",
				Action: "create", Username: "svc-share",
				Credential: CredentialRef{ID: smbTestCredID, URL: smbCredURL(smbTestCredID)},
			},
			rec: &mount.RecorderRunner{},
		},
		{
			name: "create falls through to setpassword",
			task: &SmbUserApplyTask{
				StorageID: "019f7cb5-3858-7000-8000-000000000006", AccountID: "019f7cb5-3858-7000-8000-000000000007",
				Action: "create", Username: "svc-share",
				Credential: CredentialRef{ID: smbTestCredID, URL: smbCredURL(smbTestCredID)},
			},
			rec: &mount.RecorderRunner{StubErr: map[string]error{"samba-tool user create svc-share": errUserExists}},
		},
		{
			name: "set_password",
			task: &SmbUserApplyTask{
				StorageID: "019f7cb5-3858-7000-8000-000000000006", AccountID: "019f7cb5-3858-7000-8000-000000000007",
				Action: "set_password", Username: "svc-share",
				Credential: CredentialRef{ID: smbTestCredID, URL: smbCredURL(smbTestCredID)},
			},
			rec: &mount.RecorderRunner{},
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			getter := stubGetter{body: sambaCredentialBody(password)}
			if err := ApplySambaUser(context.Background(), tc.rec, getter, tc.task); err != nil {
				t.Fatalf("unexpected err: %v", err)
			}
			if len(tc.rec.Invocations) == 0 {
				t.Fatal("expected at least one samba-tool invocation")
			}
			// Pinned exactly, not just Contains: samba-tool's "New
			// Password:" / "Retype Password:" prompts each read ONE line —
			// a regression that sent the secret only once (secret+"\n")
			// would raise EOFError on the second prompt in production
			// (verified by execution — see redactedRun's doc comment), but
			// a Contains-only check would stay green for it. Checked on
			// EVERY RunStdin invocation in the case (the fallback case has
			// two: the failed create attempt and the setpassword retry —
			// both must conform).
			wantStdin := password + "\n" + password + "\n"
			sawStdin := false
			for _, inv := range tc.rec.Invocations {
				for _, a := range inv.Args {
					if strings.Contains(a, password) {
						t.Fatalf("password leaked into argv: %+v", inv)
					}
				}
				if inv.Op != "RunStdin" {
					continue
				}
				sawStdin = true
				if inv.Stdin != wantStdin {
					t.Fatalf("expected stdin to be the password written exactly twice (one line per samba-tool prompt); got %q", inv.Stdin)
				}
			}
			if !sawStdin {
				t.Fatalf("expected the password to be delivered via RunStdin's Stdin field; got %+v", tc.rec.Invocations)
			}
		})
	}
}

// TestExecRunner_RunStdin_SecretNeverInArgvOrEnviron is the real-process
// counterpart to the RecorderRunner-based tests above: it exercises
// mount.ExecRunner directly (the production Runner — RecorderRunner never
// actually execs anything, so it can't prove this on its own) to confirm
// the stdin-delivery PLUMBING itself never leaks the secret into the child
// process's argv or environment — the two channels readable by any other
// user on the box via /proc/<pid>/cmdline and /proc/<pid>/environ. The
// child deliberately dumps both, then exits non-zero, so ExecRunner's
// existing captured-output-in-error behavior (mount/runner.go) surfaces
// them to the assertion below without this test needing its own stdout
// plumbing.
func TestExecRunner_RunStdin_SecretNeverInArgvOrEnviron(t *testing.T) {
	const secret = "leak-check-env-argv-7c21"
	r := mount.ExecRunner{}
	// The child (1) dumps its own argv and environ, proving neither channel
	// carries the secret, then (2) echoes back exactly what it read from
	// stdin via a bare `cat` — proving RunStdin actually DELIVERS it (a
	// RunStdin that silently dropped stdin would produce no such echo, so
	// this can't pass vacuously). Comparing INSIDE the shell (e.g.
	// `[ "$x" = "<secret>" ]`) would put the literal secret into the
	// child's own -c script argument and self-contaminate the very argv
	// check this test exists to run — so the echoed value is compared by
	// the Go test itself instead. Always exits 1 so ExecRunner's existing
	// captured-output-in-error behavior (mount/runner.go) surfaces
	// everything here without this test needing its own stdout plumbing.
	err := r.RunStdin(context.Background(), secret+"\n", "sh", "-c",
		"cat /proc/self/cmdline; echo; cat /proc/self/environ; echo; cat; exit 1")
	if err == nil {
		t.Fatal("expected the deliberate exit 1 to produce an error")
	}
	msg := err.Error()
	if n := strings.Count(msg, secret); n != 1 {
		t.Fatalf("expected the secret to appear EXACTLY once (the stdin echo) — 0 means RunStdin never delivered it, >1 means it ALSO leaked into argv or environ; got %d occurrences in: %q", n, msg)
	}
	if !strings.HasSuffix(strings.TrimRight(msg, ")"), secret+"\n") {
		t.Fatalf("expected the secret's one occurrence to be the trailing stdin echo, not the argv/environ dump before it: %q", msg)
	}
}

// --- RULE (IMP-ad2c66a838f2 review round 1): redactedRun fails CLOSED when
// its runner doesn't support stdin-delivered secrets — it must return an
// error and must NEVER fall back to running the command (via argv or
// otherwise). -----------------------------------------------------------

// argvOnlyRunner implements mount.Runner (Run/Output) but deliberately NOT
// mount.StdinRunner — simulating a Runner that predates RunStdin. Records
// whether Run/Output was ever invoked at all, so the test below can prove
// redactedRun never executes anything through it.
type argvOnlyRunner struct {
	called bool
}

func (r *argvOnlyRunner) Run(_ context.Context, _ string, _ ...string) error {
	r.called = true
	return nil
}

func (r *argvOnlyRunner) Output(_ context.Context, _ string, _ ...string) ([]byte, error) {
	r.called = true
	return nil, nil
}

func TestRedactedRun_FailsClosedWhenRunnerLacksStdinSupport(t *testing.T) {
	const secret = "must-never-reach-argv-fallback"
	r := &argvOnlyRunner{}

	err := redactedRun(context.Background(), r, secret, "samba-tool", "user", "setpassword", "svc-share")

	if err == nil {
		t.Fatal("expected redactedRun to refuse a runner without stdin support")
	}
	if strings.Contains(err.Error(), secret) {
		t.Fatalf("the refusal echoed the secret: %v", err)
	}
	if r.called {
		t.Fatal("redactedRun must never fall back to running the command (via argv or otherwise) when the runner lacks stdin support")
	}
}

// errUserExists simulates samba-tool's non-zero exit for an already-present
// user, which createSambaUser treats as "fall through to setpassword".
var errUserExists = &sambaTestError{"user already exists"}

// errFetchMustNotHappen fails the test if fetchCredential is ever called —
// used to prove the delete path never fetches credential material.
var errFetchMustNotHappen = &sambaTestError{"fetchCredential must not be called for delete"}

type sambaTestError struct{ msg string }

func (e *sambaTestError) Error() string { return e.msg }

// multiURLGetter routes to a different canned body per URL, so a test can
// prove which of two credential refs the code actually fetched.
type multiURLGetter struct {
	responses map[string]string
}

func (g *multiURLGetter) GetJSON(path string) (*http.Response, error) {
	body, ok := g.responses[path]
	if !ok {
		return nil, &sambaTestError{"no stub for " + path}
	}
	return stubGetter{body: body}.GetJSON(path)
}
