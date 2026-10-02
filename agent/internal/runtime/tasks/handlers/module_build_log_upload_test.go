package handlers

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/runtime/tasks"
)

// IMP-dbc22946e05c — the agent keeps only a scrubbed TAIL of a build's output on
// the task result; the rest was discarded, so a failure whose cause scrolled out
// of that window could not be diagnosed over MCP. The handler now also uploads the
// FULL scrubbed log through the node API (POST status/tasks/:id/log), on the
// success path and the failure path alike, size-capped with the truncation stated.

// logUploadHTTP serves the build context on GET and records every POST.
type logUploadHTTP struct {
	posts    []logUploadPost
	postErr  error
	postCode int
}

type logUploadPost struct {
	path string
	body []byte
}

func (f *logUploadHTTP) GetJSON(string) (*http.Response, error) {
	return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(strings.NewReader(okContextBody))}, nil
}

func (f *logUploadHTTP) PostJSON(path string, body []byte) (*http.Response, error) {
	f.posts = append(f.posts, logUploadPost{path: path, body: append([]byte(nil), body...)})
	if f.postErr != nil {
		return nil, f.postErr
	}
	code := f.postCode
	if code == 0 {
		code = http.StatusOK
	}
	return &http.Response{StatusCode: code, Body: io.NopCloser(strings.NewReader(`{"success":true}`))}, nil
}

type uploadedLog struct {
	Log           string `json:"log"`
	OriginalBytes int    `json:"original_bytes"`
	Truncated     bool   `json:"truncated"`
}

func logPosts(t *testing.T, h *logUploadHTTP) []uploadedLog {
	t.Helper()
	var out []uploadedLog
	for _, p := range h.posts {
		if !strings.HasSuffix(p.path, "/log") {
			continue
		}
		var u uploadedLog
		if err := json.Unmarshal(p.body, &u); err != nil {
			t.Fatalf("log upload body is not JSON: %v (%s)", err, p.body)
		}
		out = append(out, u)
	}
	return out
}

func buildTask() *tasks.Task {
	return &tasks.Task{ID: "task-42", Command: "ci.module_build", Options: map[string]any{
		"module": "runtime-ruby", "sha": "deadsha", "oci_ref": "v1.2.3",
	}}
}

const okBuildResult = `{"oci_digest":"sha256:aaa","fsverity_root":"root1","size":2048,"built_from_sha":"deadsha"}`

func TestModuleBuild_UploadsFullScrubbedLog_OnSuccess(t *testing.T) {
	httpc := &logUploadHTTP{}
	stderr := strings.Repeat("apt line\n", 20000) + "the real cause was here\n" // far past the 128 KB tail
	exec := &fakeExec{stdout: []byte(okBuildResult), stderr: []byte(stderr)}
	h := &ModuleBuildHandler{HTTP: httpc, Exec: exec}

	result, err := h.Execute(context.Background(), buildTask())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	ups := logPosts(t, httpc)
	if len(ups) != 1 {
		t.Fatalf("want exactly one log upload, got %d (%v)", len(ups), httpc.posts)
	}
	if httpc.posts[0].path != "/api/v1/system/node_api/status/tasks/task-42/log" {
		t.Fatalf("upload path = %q", httpc.posts[0].path)
	}
	if !strings.Contains(ups[0].Log, "the real cause was here") || !strings.Contains(ups[0].Log, "apt line") {
		t.Fatalf("the upload must carry the whole log, not just the tail")
	}
	if len(ups[0].Log) <= logTailStderrMaxBytes {
		t.Fatalf("uploaded %d bytes, want more than the %d-byte tail", len(ups[0].Log), logTailStderrMaxBytes)
	}
	if ups[0].Truncated {
		t.Fatalf("a log within the cap must not claim truncation")
	}
	if result["log_uploaded"] != true {
		t.Fatalf("result[log_uploaded] = %v, want true", result["log_uploaded"])
	}
}

func TestModuleBuild_UploadsFullLog_OnFailureToo(t *testing.T) {
	httpc := &logUploadHTTP{}
	exec := &fakeExec{stderr: []byte("mmdebstrap: E: something exploded\n"), err: errors.New("exit status 1")}
	h := &ModuleBuildHandler{HTTP: httpc, Exec: exec}

	_, err := h.Execute(context.Background(), buildTask())
	if err == nil {
		t.Fatal("a failing build must still fail")
	}

	ups := logPosts(t, httpc)
	if len(ups) != 1 || !strings.Contains(ups[0].Log, "something exploded") {
		t.Fatalf("the failure path must upload the log before reporting, got %+v", ups)
	}
}

func TestModuleBuild_UploadedLogIsScrubbed(t *testing.T) {
	httpc := &logUploadHTTP{}
	exec := &fakeExec{
		stdout: []byte(okBuildResult),
		stderr: []byte("cloning https://x-access-token:SRC-TOKEN@git.example/x.git\npush with ORAS-PW\n-----BEGIN PRIVATE KEY-----\nAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n-----END PRIVATE KEY-----\nfine\n"),
	}
	h := &ModuleBuildHandler{HTTP: httpc, Exec: exec}

	if _, err := h.Execute(context.Background(), buildTask()); err != nil {
		t.Fatal(err)
	}

	ups := logPosts(t, httpc)
	if len(ups) != 1 {
		t.Fatalf("want one upload, got %d", len(ups))
	}
	for _, secret := range []string{"SRC-TOKEN", "ORAS-PW", "AAAAAAAAAAAAAAAAAAAA", "BEGIN PRIVATE KEY"} {
		if strings.Contains(ups[0].Log, secret) {
			t.Fatalf("the uploaded log leaked %q:\n%s", secret, ups[0].Log)
		}
	}
	if !strings.Contains(ups[0].Log, "fine") {
		t.Fatalf("non-secret text must survive")
	}
}

func TestModuleBuild_UploadCapKeepsTheEndAndStatesTruncation(t *testing.T) {
	old := fullLogMaxBytes
	fullLogMaxBytes = 2048
	t.Cleanup(func() { fullLogMaxBytes = old })

	httpc := &logUploadHTTP{}
	stderr := strings.Repeat("noise line\n", 1000) + "THE-FAILING-LINE\n"
	exec := &fakeExec{stdout: []byte(okBuildResult), stderr: []byte(stderr)}
	h := &ModuleBuildHandler{HTTP: httpc, Exec: exec}

	if _, err := h.Execute(context.Background(), buildTask()); err != nil {
		t.Fatal(err)
	}

	ups := logPosts(t, httpc)
	if len(ups) != 1 {
		t.Fatalf("want one upload, got %d", len(ups))
	}
	if len(ups[0].Log) > fullLogMaxBytes {
		t.Fatalf("uploaded %d bytes, cap is %d", len(ups[0].Log), fullLogMaxBytes)
	}
	if !strings.Contains(ups[0].Log, "THE-FAILING-LINE") {
		t.Fatalf("the END of the log must be kept")
	}
	if !ups[0].Truncated || ups[0].OriginalBytes <= fullLogMaxBytes {
		t.Fatalf("truncation must be stated: truncated=%v original_bytes=%d", ups[0].Truncated, ups[0].OriginalBytes)
	}
}

func TestModuleBuild_UploadFailureNeverFailsTheBuild(t *testing.T) {
	for name, httpc := range map[string]*logUploadHTTP{
		"transport error": {postErr: errors.New("connection reset")},
		"server refusal":  {postCode: http.StatusUnprocessableEntity},
	} {
		t.Run(name, func(t *testing.T) {
			exec := &fakeExec{stdout: []byte(okBuildResult), stderr: []byte("ok\n")}
			h := &ModuleBuildHandler{HTTP: httpc, Exec: exec}

			result, err := h.Execute(context.Background(), buildTask())
			if err != nil {
				t.Fatalf("an upload failure must not fail a successful build: %v", err)
			}
			if result["log_uploaded"] != false {
				t.Fatalf("result[log_uploaded] = %v, want false", result["log_uploaded"])
			}
			if result["oci_digest"] != "sha256:aaa" {
				t.Fatalf("the build result must be untouched: %+v", result)
			}
		})
	}
}

func TestModuleBuild_NoUploadWithoutATaskID(t *testing.T) {
	httpc := &logUploadHTTP{}
	exec := &fakeExec{stdout: []byte(okBuildResult)}
	h := &ModuleBuildHandler{HTTP: httpc, Exec: exec}
	task := buildTask()
	task.ID = ""

	if _, err := h.Execute(context.Background(), task); err != nil {
		t.Fatal(err)
	}
	if len(logPosts(t, httpc)) != 0 {
		t.Fatalf("there is no path to upload to without a task id")
	}
}

func TestModuleBuild_UploadScrubsEveryEncodedFormAndTheParentPAT(t *testing.T) {
	httpc := &logUploadHTTP{}
	ctx := `{"success":true,"data":{"source_repo_url":"https://git.example/x.git","source_token":"SRC/TOK+EN","parent_pat":"PARENT-PAT-1","oras_registry":"r","oras_user":"u","oras_password":"ORAS PW&1"}}`
	h := &ModuleBuildHandler{HTTP: &ctxAndPostHTTP{logUploadHTTP: httpc, ctx: ctx}, Exec: &fakeExec{
		stdout: []byte(okBuildResult),
		stderr: []byte("a SRC%2FTOK%2BEN b\nc SRC/TOK+EN d\ne PARENT-PAT-1 f\ng ORAS+PW%261 h\ni ORAS%20PW&1 j\nk ORAS PW&1 l\nok\n"),
	}}
	task := buildTask()
	task.Options["class"] = "B"

	if _, err := h.Execute(context.Background(), task); err != nil {
		t.Fatal(err)
	}
	ups := logPosts(t, httpc)
	if len(ups) != 1 {
		t.Fatalf("want one upload, got %d", len(ups))
	}
	for _, secret := range []string{"SRC%2FTOK%2BEN", "SRC/TOK+EN", "PARENT-PAT-1", "ORAS+PW%261", "ORAS%20PW&1", "ORAS PW&1"} {
		if strings.Contains(ups[0].Log, secret) {
			t.Fatalf("the uploaded log leaked %q:\n%s", secret, ups[0].Log)
		}
	}
}

// ctxAndPostHTTP serves a custom build context on GET and records POSTs.
type ctxAndPostHTTP struct {
	*logUploadHTTP
	ctx string
}

func (c *ctxAndPostHTTP) GetJSON(string) (*http.Response, error) {
	return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(strings.NewReader(c.ctx))}, nil
}

func TestScrubbedFullLog_CapBoundaryAndSecretNearTheCut(t *testing.T) {
	old := fullLogMaxBytes
	fullLogMaxBytes = 400
	t.Cleanup(func() { fullLogMaxBytes = old })

	// A secret sitting just before the cut point must be gone from the kept window
	// too, not left as a fragment: scrub runs on the whole stream BEFORE the cut.
	stderr := strings.Repeat("x", 300) + " SECRET-VALUE-123 " + strings.Repeat("y\n", 120) + "END\n"
	log, original, truncated := scrubbedFullLog(nil, []byte(stderr), "SECRET-VALUE-123")

	if !truncated || original <= fullLogMaxBytes {
		t.Fatalf("expected a truncated log, got truncated=%v original=%d", truncated, original)
	}
	if len(log) > fullLogMaxBytes {
		t.Fatalf("log is %d bytes, cap %d (the marker must count inside the cap)", len(log), fullLogMaxBytes)
	}
	if strings.Contains(log, "SECRET") || strings.Contains(log, "VALUE-123") {
		t.Fatalf("a fragment of the secret survived the cut: %q", log)
	}
	if !strings.HasPrefix(log, fullLogTruncatedMarker) || !strings.HasSuffix(log, "END\n") {
		t.Fatalf("marker first, end kept: %q", log)
	}

	// Exactly at the cap: not truncated.
	fullLogMaxBytes = len("stdout:\n\nstderr:\nabc\n")
	if l, _, tr := scrubbedFullLog(nil, []byte("abc")); tr || l != "stdout:\n\nstderr:\nabc\n" {
		t.Fatalf("a log exactly at the cap must not truncate: %q %v", l, tr)
	}
}

func TestModuleBuild_FailedBuildWithFailedUploadStillReportsItsOwnError(t *testing.T) {
	httpc := &logUploadHTTP{postErr: errors.New("connection reset")}
	h := &ModuleBuildHandler{HTTP: httpc, Exec: &fakeExec{stderr: []byte("boom\n"), err: errors.New("exit status 1")}}

	_, err := h.Execute(context.Background(), buildTask())

	if err == nil || !strings.Contains(err.Error(), "exit status 1") || !strings.Contains(err.Error(), "boom") {
		t.Fatalf("the build's own error and log_tail must survive a failed upload, got %v", err)
	}
}
