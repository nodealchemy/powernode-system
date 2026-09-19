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
		if inv.Op != "Run" || inv.Name != name {
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
	if !sambaArgsContain(rec, "samba-tool", "fetched-pw") {
		t.Fatalf("expected samba-tool to run with the fetched password; got %+v", rec.Invocations)
	}
}

func TestApplySambaUser_CreateFallsThroughToSetPasswordOnExistingUser(t *testing.T) {
	rec := &mount.RecorderRunner{
		StubErr: map[string]error{
			"samba-tool user create svc-share fetched-pw": errUserExists,
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
	if !sambaArgsContain(rec, "samba-tool", "--newpassword=fetched-pw") {
		t.Fatalf("expected the setpassword fallback to run with the fetched password; got %+v", rec.Invocations)
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
	if !sambaArgsContain(rec, "samba-tool", "--newpassword=rotated-pw") {
		t.Fatalf("expected setpassword to use the NEW credential's password; got %+v", rec.Invocations)
	}
	if sambaArgsContain(rec, "samba-tool", "--newpassword=old-pw") {
		t.Fatalf("setpassword must not fall back to the old credential when a new one is present; got %+v", rec.Invocations)
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
	if !sambaArgsContain(rec, "samba-tool", "--newpassword=only-pw") {
		t.Fatalf("expected setpassword to fall back to Credential's password; got %+v", rec.Invocations)
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
			"samba-tool user create svc-share " + password:                    errUserExists,
			"samba-tool user setpassword svc-share --newpassword=" + password: errors.New("samba-tool user setpassword svc-share --newpassword=" + password + ": exit status 1"),
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
			"samba-tool user setpassword svc-share --newpassword=" + password: errors.New("samba-tool user setpassword svc-share --newpassword=" + password + ": exit status 1 (output: bad password " + password + ")"),
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
