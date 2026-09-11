package handlers

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/runtime/tasks"
)

// recordingHTTP stubs the platform transport and keeps every POST body, so a
// test can assert what left the node.
type recordingHTTP struct {
	getStatus  int
	getBody    string
	postStatus int
	postBody   string
	postErr    error
	gets       []string
	posts      []recordedPost
}

type recordedPost struct {
	path string
	body []byte
}

func (f *recordingHTTP) GetJSON(path string) (*http.Response, error) {
	f.gets = append(f.gets, path)
	status := f.getStatus
	if status == 0 {
		status = http.StatusOK
	}
	return &http.Response{StatusCode: status, Body: io.NopCloser(strings.NewReader(f.getBody))}, nil
}

func (f *recordingHTTP) PostJSON(path string, body []byte) (*http.Response, error) {
	f.posts = append(f.posts, recordedPost{path: path, body: append([]byte(nil), body...)})
	if f.postErr != nil {
		return nil, f.postErr
	}
	status := f.postStatus
	if status == 0 {
		status = http.StatusOK
	}
	respBody := f.postBody
	if respBody == "" {
		respBody = `{"success":true}`
	}
	return &http.Response{StatusCode: status, Body: io.NopCloser(strings.NewReader(respBody))}, nil
}

// lintExec stands in for the sandbox. It records every phase it is asked to
// run, and whether the workdir existed while that phase ran.
type lintExec struct {
	prepared   []string
	prepareErr error
	calls      []lintCall
	clone      lintReply
	lint       lintReply
}

type lintCall struct {
	name        string
	env         map[string]string
	rawEnv      []string
	workdir     string
	workdirSeen bool
	stdoutMax   int
}

type lintReply struct {
	stdout []byte
	stderr []byte
	err    error
}

func (f *lintExec) Prepare(workdir string) error {
	f.prepared = append(f.prepared, workdir)
	return f.prepareErr
}

func (f *lintExec) Run(_ context.Context, name string, env []string, workdir string, stdoutMax int) ([]byte, []byte, error) {
	_, statErr := os.Stat(workdir)
	f.calls = append(f.calls, lintCall{name: name, env: envMap(env), rawEnv: append([]string(nil), env...),
		workdir: workdir, workdirSeen: statErr == nil, stdoutMax: stdoutMax})
	reply := f.lint
	if name == lintCloneScript {
		reply = f.clone
	}
	return reply.stdout, reply.stderr, reply.err
}

func (f *lintExec) phase(name string) []lintCall {
	var out []lintCall
	for _, c := range f.calls {
		if c.name == name {
			out = append(out, c)
		}
	}
	return out
}

const (
	tokenOne = "LINT-TOKEN-1111"
	tokenTwo = "LINT-TOKEN-2222"
)

// The output limit every fixture context hands out.
const testOutputLimit = 1 << 20

// A lease deadline far enough away that only the phase caps bound a run.
const farDeadline = "2099-01-01T00:00:00Z"

const lintContextBody = `{"success":true,"data":{"output_limit_bytes":1048576,"deadline_at":"2099-01-01T00:00:00Z","repositories":[
	{"id":"repo-1","clone_url":"https://git.example.test/acme/core.git","ref":"main","username":"x-access-token","token":"LINT-TOKEN-1111"},
	{"id":"repo-2","clone_url":"https://git.example.test:8443/acme/docs.git","ref":"main","username":"x-access-token","token":"LINT-TOKEN-2222"}
]}}`

const okLintStdout = `{"linters":{"ruby":{"status":"ran","exitstatus":1,"output":"{\"files\":[]}"},"typescript":{"status":"unavailable"}}}` + "\n"

// contextWith builds a one-repository lint context with the given clone URL
// and token.
func contextWith(t *testing.T, cloneURL, token string) string {
	t.Helper()
	body, err := json.Marshal(map[string]any{"success": true, "data": map[string]any{
		"output_limit_bytes": testOutputLimit,
		"deadline_at":        farDeadline,
		"repositories": []map[string]string{{"id": "repo-1", "clone_url": cloneURL, "ref": "main",
			"username": "x-access-token", "token": token}},
	}})
	if err != nil {
		t.Fatal(err)
	}
	return string(body)
}

func lintTask(ids ...string) *tasks.Task {
	raw := make([]any, len(ids))
	for i, id := range ids {
		raw[i] = id
	}
	return &tasks.Task{ID: "task-1", Command: "ci.lint_discovery",
		Options: map[string]any{"run_ref": "lease-1", "repository_ids": raw}}
}

// isolatedTmp points $TMPDIR at a per-test directory, so a workdir that still
// landed under $TMPDIR is caught, and no test touches a live /persist.
func isolatedTmp(t *testing.T) string {
	t.Helper()
	tmp := t.TempDir()
	t.Setenv("TMPDIR", tmp)
	return tmp
}

// lintTestBase is a per-test workdir base, handed to the handler directly:
// the production resolver would pick a real node path (/persist, /var/lib).
func lintTestBase(t *testing.T) string {
	t.Helper()
	return t.TempDir()
}

func keys(m map[string]string) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

var (
	lintPhaseKeys = []string{"HOME", "LANG", "LINT_KILL_AFTER_SECONDS", "LINT_MAX_OUTPUT_BYTES", "LINT_TIMEOUT_SECONDS",
		"PATH", "TMPDIR", "WORKDIR", "XDG_CACHE_HOME"}
	lintCloneKeys = []string{
		"GIT_ALLOW_PROTOCOL", "GIT_ASKPASS", "GIT_CONFIG_COUNT", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_KEY_0",
		"GIT_CONFIG_KEY_1", "GIT_CONFIG_NOSYSTEM", "GIT_CONFIG_VALUE_0", "GIT_CONFIG_VALUE_1",
		"GIT_HTTP_LOW_SPEED_LIMIT", "GIT_HTTP_LOW_SPEED_TIME", "GIT_TERMINAL_PROMPT", "HOME", "LANG",
		"LINT_CLONE_TIMEOUT_SECONDS", "LINT_GIT_HOST", "LINT_GIT_TOKEN", "LINT_GIT_USERNAME", "LINT_KILL_AFTER_SECONDS",
		"PATH", "REPO_REF", "REPO_URL", "TMPDIR", "WORKDIR", "XDG_CACHE_HOME",
	}
)

func TestLintDiscovery_TwoPhasesPerRepositoryAndCountsOnly(t *testing.T) {
	tmp := isolatedTmp(t)
	base := lintTestBase(t)
	httpc := &recordingHTTP{getBody: lintContextBody}
	ex := &lintExec{lint: lintReply{stdout: []byte(okLintStdout)}}
	h := &ModuleBuildHandler{HTTP: httpc, LintWorkdirBase: base, Lint: ex}

	result, err := h.Execute(context.Background(), lintTask("repo-1", "repo-2"))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(result) != 3 || result["repositories"] != 2 || result["reported"] != 2 || result["failed"] != 0 {
		t.Fatalf("result must be the three counts only, got %+v", result)
	}
	if len(httpc.gets) != 1 || httpc.gets[0] != lintContextPath {
		t.Fatalf("gets: %v", httpc.gets)
	}

	// clone, lint, clone, lint — never a lint before its clone.
	want := []string{lintCloneScript, lintDiscoveryScript, lintCloneScript, lintDiscoveryScript}
	if len(ex.calls) != len(want) {
		t.Fatalf("phases run: %d, want %d", len(ex.calls), len(want))
	}
	for i, c := range ex.calls {
		if c.name != want[i] {
			t.Fatalf("phase %d = %q, want %q", i, c.name, want[i])
		}
	}
	if len(ex.prepared) != 2 {
		t.Fatalf("each workdir must be handed to the sandbox user first, prepared: %v", ex.prepared)
	}

	for i, c := range ex.calls {
		wd := c.env["WORKDIR"]
		if c.workdir != wd || ex.prepared[i/2] != wd {
			t.Fatalf("phase %d ran in %q with WORKDIR %q, prepared %q", i, c.workdir, wd, ex.prepared[i/2])
		}
		// D1b critic H3: under the configured base, never $TMPDIR.
		if !strings.HasPrefix(wd, base+string(os.PathSeparator)) || strings.HasPrefix(wd, tmp+string(os.PathSeparator)) {
			t.Fatalf("WORKDIR %q is not under the base %q, or sits under TMPDIR %q", wd, base, tmp)
		}
		if !c.workdirSeen {
			t.Fatalf("WORKDIR %q did not exist while phase %d ran", wd, i)
		}
		if _, err := os.Stat(wd); !os.IsNotExist(err) {
			t.Fatalf("WORKDIR %q must be removed afterwards (stat err %v)", wd, err)
		}
		for _, k := range []string{"HOME", "TMPDIR", "XDG_CACHE_HOME"} {
			if !strings.HasPrefix(c.env[k], wd+string(os.PathSeparator)) {
				t.Fatalf("%s=%q must live inside the workdir %q", k, c.env[k], wd)
			}
		}
		if c.env["PATH"] != lintSandboxPath {
			t.Fatalf("PATH = %q, want the fixed sandbox PATH", c.env["PATH"])
		}
	}

	clones := ex.phase(lintCloneScript)
	if clones[0].env["LINT_GIT_TOKEN"] != tokenOne || clones[1].env["LINT_GIT_TOKEN"] != tokenTwo {
		t.Fatalf("each repository must get its own credential")
	}
	if clones[0].env["LINT_GIT_HOST"] != "git.example.test" || clones[1].env["LINT_GIT_HOST"] != "git.example.test:8443" {
		t.Fatalf("askpass host: %q, %q", clones[0].env["LINT_GIT_HOST"], clones[1].env["LINT_GIT_HOST"])
	}
	for _, c := range clones {
		if strings.Contains(c.env["REPO_URL"], "@") || strings.Contains(c.env["REPO_URL"], "TOKEN") {
			t.Fatalf("clone URL must carry no credential: %q", c.env["REPO_URL"])
		}
		for k, v := range map[string]string{
			"GIT_ASKPASS": lintDiscoveryAskpass, "GIT_TERMINAL_PROMPT": "0", "GIT_CONFIG_NOSYSTEM": "1",
			"GIT_CONFIG_GLOBAL": "/dev/null", "GIT_ALLOW_PROTOCOL": "https", "GIT_CONFIG_COUNT": "2",
			"GIT_CONFIG_KEY_0": "http.followRedirects", "GIT_CONFIG_VALUE_0": "false",
			"GIT_CONFIG_KEY_1": "credential.helper", "GIT_CONFIG_VALUE_1": "",
		} {
			if got, ok := c.env[k]; !ok || got != v {
				t.Fatalf("clone env %s = %q (present %v), want %q", k, got, ok, v)
			}
		}
	}

	// The lint phase runs repository code: not one credential-bearing value.
	for _, c := range ex.phase(lintDiscoveryScript) {
		for _, kv := range c.rawEnv {
			if strings.Contains(kv, tokenOne) || strings.Contains(kv, tokenTwo) ||
				strings.HasPrefix(kv, "LINT_GIT_") || strings.HasPrefix(kv, "GIT_ASKPASS=") || strings.HasPrefix(kv, "REPO_URL=") {
				t.Fatalf("lint phase env carries %q", kv)
			}
		}
	}

	if len(httpc.posts) != 2 {
		t.Fatalf("posts: %d, want 2", len(httpc.posts))
	}
	for i, p := range httpc.posts {
		if p.path != lintResultPath {
			t.Fatalf("post path = %q", p.path)
		}
		if strings.Contains(string(p.body), tokenOne) || strings.Contains(string(p.body), tokenTwo) {
			t.Fatalf("a posted result carries a credential: %s", p.body)
		}
		var body struct {
			RunRef       string                `json:"run_ref"`
			RepositoryID string                `json:"repository_id"`
			BasePath     string                `json:"base_path"`
			Linters      map[string]lintReport `json:"linters"`
		}
		if err := json.Unmarshal(p.body, &body); err != nil {
			t.Fatalf("decode post: %v", err)
		}
		if body.RunRef != "lease-1" || body.RepositoryID != []string{"repo-1", "repo-2"}[i] {
			t.Fatalf("post identity: %+v", body)
		}
		if body.BasePath != filepath.Join(clones[i].env["WORKDIR"], lintCloneDir) {
			t.Fatalf("base_path = %q", body.BasePath)
		}
		if body.Linters["ruby"].Status != "ran" || body.Linters["typescript"].Status != "unavailable" {
			t.Fatalf("linters: %+v", body.Linters)
		}
	}

	encoded, _ := json.Marshal(result)
	if strings.Contains(string(encoded), tokenOne) || strings.Contains(string(encoded), tokenTwo) {
		t.Fatalf("the task result carries a credential: %s", encoded)
	}
}

// Both phases get exactly the keys the handler builds, nothing inherited from
// the agent's own environment.
func TestLintDiscovery_PhaseEnvironmentsAreBuiltFromScratch(t *testing.T) {
	isolatedTmp(t)
	t.Setenv("LINT_TEST_INHERITED_SECRET", "agent-side-value")
	httpc := &recordingHTTP{getBody: lintContextBody}
	ex := &lintExec{lint: lintReply{stdout: []byte(okLintStdout)}}
	h := &ModuleBuildHandler{HTTP: httpc, LintWorkdirBase: lintTestBase(t), Lint: ex}

	if _, err := h.Execute(context.Background(), lintTask("repo-1")); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	clone, lint := ex.phase(lintCloneScript)[0], ex.phase(lintDiscoveryScript)[0]
	if got := keys(clone.env); strings.Join(got, ",") != strings.Join(lintCloneKeys, ",") {
		t.Fatalf("clone env keys:\n got %v\nwant %v", got, lintCloneKeys)
	}
	if got := keys(lint.env); strings.Join(got, ",") != strings.Join(lintPhaseKeys, ",") {
		t.Fatalf("lint env keys:\n got %v\nwant %v", got, lintPhaseKeys)
	}
	if lint.env["LINT_MAX_OUTPUT_BYTES"] != "1048576" {
		t.Fatalf("the lint phase must carry the context's output limit, got %q", lint.env["LINT_MAX_OUTPUT_BYTES"])
	}
}

// D1 re-verify M2: the platform's output limit reaches the script, and the
// lint phase's stdout bound follows it; the clone phase keeps its own small
// bound.
func TestLintDiscovery_TheStdoutBoundFollowsTheContextLimit(t *testing.T) {
	isolatedTmp(t)
	httpc := &recordingHTTP{getBody: lintContextBody}
	ex := &lintExec{lint: lintReply{stdout: []byte(okLintStdout)}}
	h := &ModuleBuildHandler{HTTP: httpc, LintWorkdirBase: lintTestBase(t), Lint: ex}

	if _, err := h.Execute(context.Background(), lintTask("repo-1")); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	clone, lint := ex.phase(lintCloneScript)[0], ex.phase(lintDiscoveryScript)[0]
	if want := testOutputLimit*lintLinterCount*lintEscapeFactor + lintResultOverheadBytes; lint.stdoutMax != want {
		t.Fatalf("lint stdout bound = %d, want %d", lint.stdoutMax, want)
	}
	if clone.stdoutMax != lintCloneStdoutMaxBytes {
		t.Fatalf("clone stdout bound = %d, want %d", clone.stdoutMax, lintCloneStdoutMaxBytes)
	}
}

// A context with no output limit is refused before anything runs: the script
// cannot tell a report it may send from one it must not.
func TestLintDiscovery_AContextWithNoOutputLimitRunsNothing(t *testing.T) {
	for name, body := range map[string]string{
		"absent": strings.Replace(lintContextBody, `"output_limit_bytes":1048576,`, "", 1),
		"zero":   strings.Replace(lintContextBody, `"output_limit_bytes":1048576`, `"output_limit_bytes":0`, 1),
	} {
		t.Run(name, func(t *testing.T) {
			isolatedTmp(t)
			if body == lintContextBody {
				t.Fatal("fixture did not change the context")
			}
			httpc := &recordingHTTP{getBody: body}
			ex := &lintExec{lint: lintReply{stdout: []byte(okLintStdout)}}
			h := &ModuleBuildHandler{HTTP: httpc, LintWorkdirBase: lintTestBase(t), Lint: ex}

			_, err := h.Execute(context.Background(), lintTask("repo-1"))
			if err == nil || !strings.Contains(err.Error(), "output_limit_bytes") {
				t.Fatalf("expected a refusal naming output_limit_bytes, got: %v", err)
			}
			if len(ex.prepared) != 0 || len(ex.calls) != 0 || len(httpc.posts) != 0 {
				t.Fatalf("nothing may run: prepared %d, runs %d, posts %d", len(ex.prepared), len(ex.calls), len(httpc.posts))
			}
		})
	}
}

// contextWithDeadline is the fixture context with its lease deadline replaced.
func contextWithDeadline(t *testing.T, deadline string) string {
	t.Helper()
	body := strings.Replace(lintContextBody, `"deadline_at":"`+farDeadline+`"`, `"deadline_at":"`+deadline+`"`, 1)
	if body == lintContextBody && deadline != farDeadline {
		t.Fatal("fixture did not change the deadline")
	}
	return body
}

// D1b critic M1: every bound comes from the lease deadline, so a context that
// names none is refused before anything runs.
func TestLintDiscovery_AContextWithNoDeadlineRunsNothing(t *testing.T) {
	isolatedTmp(t)
	body := strings.Replace(lintContextBody, `"deadline_at":"`+farDeadline+`",`, "", 1)
	if body == lintContextBody {
		t.Fatal("fixture did not drop the deadline")
	}
	httpc := &recordingHTTP{getBody: body}
	ex := &lintExec{lint: lintReply{stdout: []byte(okLintStdout)}}
	h := &ModuleBuildHandler{HTTP: httpc, LintWorkdirBase: lintTestBase(t), Lint: ex}

	_, err := h.Execute(context.Background(), lintTask("repo-1"))
	if err == nil || !strings.Contains(err.Error(), "deadline_at") {
		t.Fatalf("expected a refusal naming deadline_at, got: %v", err)
	}
	if len(ex.prepared) != 0 || len(ex.calls) != 0 || len(httpc.posts) != 0 {
		t.Fatalf("nothing may run: prepared %d, runs %d, posts %d", len(ex.prepared), len(ex.calls), len(httpc.posts))
	}
}

// D1b critic M1: each repository gets an equal share of what is left of the
// lease, and inside that share every script step at its bound, plus its kill
// grace, still ends before the phase is killed; the clone gets a quarter.
func TestLintDiscovery_BudgetsEveryStepUnderTheLeaseDeadline(t *testing.T) {
	isolatedTmp(t)
	deadline := time.Now().Add(21 * time.Minute)
	httpc := &recordingHTTP{getBody: contextWithDeadline(t, deadline.UTC().Format(time.RFC3339))}
	ex := &lintExec{lint: lintReply{stdout: []byte(okLintStdout)}}
	h := &ModuleBuildHandler{HTTP: httpc, LintWorkdirBase: lintTestBase(t), Lint: ex}

	if _, err := h.Execute(context.Background(), lintTask("repo-1", "repo-2")); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	// The first repository's share: (21m - the post margin) / 2 repositories.
	share := (21*time.Minute - lintPostMargin) / 2
	clone, lint := ex.phase(lintCloneScript)[0], ex.phase(lintDiscoveryScript)[0]
	cloneBound := envSeconds(t, clone, "LINT_CLONE_TIMEOUT_SECONDS") + lintKillAfter
	if cloneBound > share/4 {
		t.Fatalf("clone bound %v exceeds a quarter of the share %v", cloneBound, share)
	}
	step := envSeconds(t, lint, "LINT_TIMEOUT_SECONDS")
	if kill := envSeconds(t, lint, "LINT_KILL_AFTER_SECONDS"); kill != lintKillAfter {
		t.Fatalf("kill grace = %v, want %v", kill, lintKillAfter)
	}
	if step <= 0 || lintStepsPerPhase*(step+lintKillAfter)+lintPhaseSlack > share {
		t.Fatalf("%d steps of %v (+%v grace) do not fit the %v share", lintStepsPerPhase, step, lintKillAfter, share)
	}
}

// Too little of the lease left: the repository is not cloned at all, and the
// task says why.
func TestLintDiscovery_StartsNoRepositoryItHasNoTimeFor(t *testing.T) {
	isolatedTmp(t)
	httpc := &recordingHTTP{getBody: contextWithDeadline(t, time.Now().Add(90*time.Second).UTC().Format(time.RFC3339))}
	ex := &lintExec{lint: lintReply{stdout: []byte(okLintStdout)}}
	h := &ModuleBuildHandler{HTTP: httpc, LintWorkdirBase: lintTestBase(t), Lint: ex}

	_, err := h.Execute(context.Background(), lintTask("repo-1"))
	if err == nil || !strings.Contains(err.Error(), "too little time left before the lease deadline") {
		t.Fatalf("expected a named refusal, got: %v", err)
	}
	if len(ex.calls) != 0 || len(httpc.posts) != 0 {
		t.Fatalf("nothing may run: runs %d, posts %d", len(ex.calls), len(httpc.posts))
	}
}

func envSeconds(t *testing.T, call lintCall, key string) time.Duration {
	t.Helper()
	n, err := strconv.Atoi(call.env[key])
	if err != nil {
		t.Fatalf("%s = %q: %v", key, call.env[key], err)
	}
	return time.Duration(n) * time.Second
}

// D1b critic H3: every workdir lives under the base, never $TMPDIR.
func TestLintDiscovery_EveryWorkdirLivesUnderTheBase(t *testing.T) {
	isolatedTmp(t)
	base := lintTestBase(t)
	httpc := &recordingHTTP{getBody: lintContextBody}
	ex := &lintExec{lint: lintReply{stdout: []byte(okLintStdout)}}
	h := &ModuleBuildHandler{HTTP: httpc, LintWorkdirBase: base, Lint: ex}

	if _, err := h.Execute(context.Background(), lintTask("repo-1", "repo-2")); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(ex.calls) != 4 {
		t.Fatalf("expected 4 phases, got %d", len(ex.calls))
	}
	for _, c := range ex.calls {
		if !strings.HasPrefix(c.workdir, base+string(os.PathSeparator)+lintWorkdirPrefix) {
			t.Fatalf("workdir %s is not under the base %s", c.workdir, base)
		}
	}
}

// D1b correctness L7: both arms against a fixed layout, asserted as the
// documented paths, never through the code's own probe or constants.
func TestResolveLintWorkdirBase_TheSettingWinsElseTheNodeLayoutDecides(t *testing.T) {
	mount := lintPersistMount
	t.Cleanup(func() { lintPersistMount = mount })

	lintPersistMount = "/proc" // always a filesystem of its own
	if got := resolveLintWorkdirBase(""); got != "/persist/lint-discovery" {
		t.Fatalf("with a persistent mount of its own, want /persist/lint-discovery, got %s", got)
	}
	if got := resolveLintWorkdirBase("/srv/lint"); got != "/srv/lint" {
		t.Fatalf("the platform setting must win, got %s", got)
	}
	lintPersistMount = filepath.Join(t.TempDir(), "no-such-mount")
	if got := resolveLintWorkdirBase(""); got != "/var/lib/lint-discovery" {
		t.Fatalf("without one, want /var/lib/lint-discovery, got %s", got)
	}
}

func TestDistinctFilesystem(t *testing.T) {
	if !distinctFilesystem("/proc", "/") {
		t.Fatal("/proc is a filesystem of its own")
	}
	if distinctFilesystem("/", "/") {
		t.Fatal("a path is not distinct from itself")
	}
	if distinctFilesystem(filepath.Join(t.TempDir(), "missing"), "/") {
		t.Fatal("a missing path is never a filesystem of its own")
	}
}

// D1b correctness L6: the lint phase gets only what is left of the share
// after the clone, so a slow clone shortens it instead of pushing the phase
// past the share.
func TestLintDiscovery_TheLintPhaseGetsOnlyWhatTheCloneLeft(t *testing.T) {
	isolatedTmp(t)
	elapsed := lintElapsed
	t.Cleanup(func() { lintElapsed = elapsed })
	lintElapsed = func(time.Time) time.Duration { return 10 * time.Minute }
	deadline := time.Now().Add(21 * time.Minute)
	httpc := &recordingHTTP{getBody: contextWithDeadline(t, deadline.UTC().Format(time.RFC3339))}
	ex := &lintExec{lint: lintReply{stdout: []byte(okLintStdout)}}
	h := &ModuleBuildHandler{HTTP: httpc, LintWorkdirBase: lintTestBase(t), Lint: ex}

	if _, err := h.Execute(context.Background(), lintTask("repo-1")); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	// A 20-minute share less the clone's 10 leaves a 10-minute phase: each of
	// 5 steps gets (600 s - 30 s - 5 x 10 s) / 5 = 104 s at most.
	if step := envSeconds(t, ex.phase(lintDiscoveryScript)[0], "LINT_TIMEOUT_SECONDS"); step > 104*time.Second {
		t.Fatalf("step bound %v ignores the clone's 10 minutes (at most 104s)", step)
	}
}

// D1b security R2: a crash mid-repository leaves the account's source in a
// workdir on persistent disk. The sweep removes what earlier agent processes
// left and nothing else: never a name it did not make, never a symlink that
// merely carries the name, never this process's own workdirs, never through
// a symlink, never the base.
func TestSweepLintWorkdirs_RemovesOnlyWorkdirsEarlierProcessesLeft(t *testing.T) {
	parent := diskParent(t)
	mkdirs := func(paths ...string) {
		t.Helper()
		for _, p := range paths {
			if err := os.MkdirAll(p, 0o700); err != nil {
				t.Fatal(err)
			}
		}
	}
	base, victim := filepath.Join(parent, "base"), filepath.Join(parent, "victim")
	stale := filepath.Join(base, lintWorkdirPrefix+"0ldtoken-1")
	staleLink := filepath.Join(base, lintWorkdirPrefix+"0ldtoken-2")
	live := filepath.Join(base, lintWorkdirPrefix+lintProcessToken+"-3")
	foreign := filepath.Join(base, "not-a-workdir")
	mkdirs(victim, filepath.Join(stale, "src"), live, foreign)
	if err := os.WriteFile(filepath.Join(victim, "keep"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(victim, filepath.Join(stale, "src", "escape")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(victim, staleLink); err != nil {
		t.Fatal(err)
	}

	removed, err := sweepLintWorkdirs(base)
	if err != nil || removed != 1 {
		t.Fatalf("the sweep removed %d (err %v), want the 1 stale workdir", removed, err)
	}
	if _, err := os.Lstat(stale); !os.IsNotExist(err) {
		t.Fatalf("%s must be removed (lstat err %v)", stale, err)
	}
	for _, kept := range []string{staleLink, live, foreign, base, filepath.Join(victim, "keep")} {
		if _, err := os.Lstat(kept); err != nil {
			t.Fatalf("%s must be kept: %v", kept, err)
		}
	}
}

func TestSweepLintWorkdirs_TouchesNothingThroughAnUnsafeBase(t *testing.T) {
	parent := diskParent(t)
	real := filepath.Join(parent, "real")
	stale := filepath.Join(real, lintWorkdirPrefix+"0ldtoken-1")
	if err := os.MkdirAll(stale, 0o700); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(parent, "link")
	if err := os.Symlink(real, link); err != nil {
		t.Fatal(err)
	}

	if _, err := sweepLintWorkdirs(link); err == nil || !strings.Contains(err.Error(), "symlink") {
		t.Fatalf("a symlinked base must be refused, got: %v", err)
	}
	if _, err := os.Lstat(stale); err != nil {
		t.Fatalf("nothing may be removed through a symlink: %v", err)
	}
	missing := filepath.Join(parent, "missing")
	if n, err := sweepLintWorkdirs(missing); n != 0 || err != nil {
		t.Fatalf("a missing base has nothing to sweep: %d, %v", n, err)
	}
	if _, err := os.Lstat(missing); !os.IsNotExist(err) {
		t.Fatalf("a sweep must never create the base (lstat err %v)", err)
	}
}

// At agent start the sweep runs on the default base, and only when that base
// exists and passes the checks an existing base must pass.
func TestSweepLintWorkdirsAtStart_OnlyOnABaseThatPassesTheChecks(t *testing.T) {
	for name, own := range map[string]bool{"a root-owned 0711 base": true, "a base another user owns": false} {
		t.Run(name, func(t *testing.T) {
			parent := diskParent(t)
			allowLintBase(t, parent, own)
			base := filepath.Join(parent, "base")
			stale := filepath.Join(base, lintWorkdirPrefix+"0ldtoken-1")
			if err := os.MkdirAll(stale, 0o700); err != nil {
				t.Fatal(err)
			}
			if err := os.Chmod(base, 0o711); err != nil {
				t.Fatal(err)
			}
			if os.Getuid() == 0 && !own {
				if err := os.Chown(base, 65534, 65534); err != nil {
					t.Fatal(err)
				}
			}

			_, err := sweepLintWorkdirsAtStart(base)
			_, statErr := os.Lstat(stale)
			if removed := os.IsNotExist(statErr); removed != own {
				t.Fatalf("stale workdir removed = %v, want %v (sweep err %v)", removed, own, err)
			}
			if !own && err == nil {
				t.Fatal("a base that fails the checks must be reported, not swept")
			}
		})
	}
	dir := t.TempDir()
	allowLintBase(t, dir, false)
	missing := filepath.Join(dir, "missing")
	if n, err := sweepLintWorkdirsAtStart(missing); n != 0 || err != nil {
		t.Fatalf("a missing default base has nothing to sweep: %d, %v", n, err)
	}
	if _, err := os.Lstat(missing); !os.IsNotExist(err) {
		t.Fatalf("the start sweep must never create the base (lstat err %v)", err)
	}
}

// D1b security addendum LOW-A: the start sweep refuses what the per-task
// prepare refuses. A root-owned 0711 base outside the allowlist, or on a
// RAM-backed filesystem, is reported and not swept.
func TestSweepLintWorkdirsAtStart_RefusesABaseOutsideTheAllowlistOrInRAM(t *testing.T) {
	seed := func(t *testing.T, parent string) (string, string) {
		base := filepath.Join(parent, "base")
		stale := filepath.Join(base, lintWorkdirPrefix+"0ldtoken-1")
		if err := os.MkdirAll(stale, 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(base, 0o711); err != nil {
			t.Fatal(err)
		}
		return base, stale
	}
	check := func(t *testing.T, base, stale, want string) {
		n, err := sweepLintWorkdirsAtStart(base)
		if err == nil || !strings.Contains(err.Error(), want) {
			t.Fatalf("expected a refusal naming %q, got %d, %v", want, n, err)
		}
		if _, statErr := os.Lstat(stale); statErr != nil {
			t.Fatalf("a refused base must not be swept: %v", statErr)
		}
		if mode := modeOf(t, base); mode.Perm() != 0o711 {
			t.Fatalf("a refused base keeps its mode, got %v", mode)
		}
	}
	t.Run("outside the allowlist", func(t *testing.T) {
		parent := diskParent(t)
		// Owned as required, but only parent/allowed/ is allowlisted.
		allowLintBase(t, filepath.Join(parent, "allowed"), true)
		base, stale := seed(t, parent)
		check(t, base, stale, "strictly below")
	})
	t.Run("on a RAM-backed filesystem", func(t *testing.T) {
		shm, err := os.MkdirTemp("/dev/shm", "lint-discovery-test-")
		if err != nil {
			t.Skipf("no /dev/shm to test with: %v", err)
		}
		t.Cleanup(func() { os.RemoveAll(shm) })
		if shm, err = filepath.EvalSymlinks(shm); err != nil {
			t.Fatal(err)
		}
		var fs syscall.Statfs_t
		if err := syscall.Statfs(shm, &fs); err != nil || diskBackedFS(int64(fs.Type)) {
			t.Skipf("/dev/shm is not RAM-backed here (%v)", err)
		}
		allowLintBase(t, shm, true)
		base, stale := seed(t, shm)
		check(t, base, stale, "RAM-backed")
	})
}

// Before each task the sweep clears what earlier processes left, and every
// workdir this task makes carries this process's token.
func TestLintDiscovery_SweepsLeftoverWorkdirsBeforeItRuns(t *testing.T) {
	isolatedTmp(t)
	base := lintTestBase(t)
	stale := filepath.Join(base, lintWorkdirPrefix+"0ldtoken-1")
	foreign := filepath.Join(base, "keep-me")
	for _, d := range []string{stale, foreign} {
		if err := os.Mkdir(d, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	httpc := &recordingHTTP{getBody: lintContextBody}
	ex := &lintExec{lint: lintReply{stdout: []byte(okLintStdout)}}
	h := &ModuleBuildHandler{HTTP: httpc, LintWorkdirBase: base, Lint: ex}

	if _, err := h.Execute(context.Background(), lintTask("repo-1")); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if _, err := os.Lstat(stale); !os.IsNotExist(err) {
		t.Fatalf("the stale workdir must be swept before the task runs (lstat err %v)", err)
	}
	if _, err := os.Lstat(foreign); err != nil {
		t.Fatalf("an entry not named like a workdir must be kept: %v", err)
	}
	for _, c := range ex.calls {
		if !strings.HasPrefix(filepath.Base(c.workdir), lintWorkdirPrefix+lintProcessToken+"-") {
			t.Fatalf("workdir %s does not carry this process's token", c.workdir)
		}
	}
}

// D1b correctness N1: a refused /tmp keeps its mode (1777). The base is
// refused before anything is changed; run as root, this is what would notice
// a chmod that crept back in ahead of the checks.
func TestPrepareLintWorkdirBase_ARefusedTmpKeepsItsMode(t *testing.T) {
	before := modeOf(t, "/tmp")
	if err := prepareLintWorkdirBase("/tmp"); err == nil {
		t.Fatal("/tmp must be refused as a workdir base")
	}
	if after := modeOf(t, "/tmp"); after != before {
		t.Fatalf("a refused /tmp must keep its mode: %v -> %v", before, after)
	}
}

func TestDiskBackedFS(t *testing.T) {
	for magic, want := range map[int64]bool{
		fsTmpfsMagic: false, fsRamfsMagic: false, fsOverlayMagic: false,
		0xEF53: true, 0x58465342: true, 0x9123683E: true, // ext4, xfs, btrfs
	} {
		if got := diskBackedFS(magic); got != want {
			t.Fatalf("diskBackedFS(%#x) = %v, want %v", magic, got, want)
		}
	}
}

// allowLintBase lets a test's base live under dir, which the production
// allowlist never names, and, when own is set, makes the test's uid the owner
// an existing base must have (production: root).
func allowLintBase(t *testing.T, dir string, own bool) {
	t.Helper()
	prefixes, owner := lintBasePrefixes, lintBaseOwnerUID
	t.Cleanup(func() { lintBasePrefixes, lintBaseOwnerUID = prefixes, owner })
	lintBasePrefixes = append(append([]string{}, prefixes...), dir+"/")
	if own {
		lintBaseOwnerUID = uint32(os.Getuid())
	}
}

// lintTestDiskDirEnv names a disk-backed directory for the base tests. A gate
// that runs this package as root sets it, because root's temp and cache
// directories are often on an overlay (D1b correctness N3).
const lintTestDiskDirEnv = "POWERNODE_LINT_TEST_DISK_DIR"

// diskParent is a disk-backed directory to put a base in: under
// $POWERNODE_LINT_TEST_DISK_DIR, else t.TempDir(), else the user cache
// directory. Every candidate is statfs'd once its symlinks are resolved. A
// directory the gate named that is not disk-backed fails the test; when no
// candidate is disk-backed the test is skipped and says what it tried.
func diskParent(t *testing.T) string {
	t.Helper()
	var tried []string
	diskBacked := func(dir string) (string, bool) {
		resolved, err := filepath.EvalSymlinks(dir)
		if err != nil {
			tried = append(tried, fmt.Sprintf("%s (%v)", dir, err))
			return "", false
		}
		var fs syscall.Statfs_t
		if err := syscall.Statfs(resolved, &fs); err != nil {
			tried = append(tried, fmt.Sprintf("%s (%v)", resolved, err))
			return "", false
		}
		if !diskBackedFS(int64(fs.Type)) {
			tried = append(tried, fmt.Sprintf("%s (filesystem type %#x)", resolved, fs.Type))
			return "", false
		}
		return resolved, true
	}
	under := func(dir string) (string, bool) {
		parent, err := os.MkdirTemp(dir, "lint-discovery-test-")
		if err != nil {
			tried = append(tried, fmt.Sprintf("%s (%v)", dir, err))
			return "", false
		}
		t.Cleanup(func() { os.RemoveAll(parent) })
		return diskBacked(parent)
	}
	if dir := os.Getenv(lintTestDiskDirEnv); dir != "" {
		parent, ok := under(dir)
		if !ok {
			t.Fatalf("%s is set but gives no disk-backed directory: %s", lintTestDiskDirEnv, strings.Join(tried, "; "))
		}
		return parent
	}
	if parent, ok := diskBacked(t.TempDir()); ok {
		return parent
	}
	if cache, err := os.UserCacheDir(); err != nil {
		tried = append(tried, fmt.Sprintf("user cache directory (%v)", err))
	} else if parent, ok := under(cache); ok {
		return parent
	}
	t.Skipf("no disk-backed directory to put a workdir base in; tried %s. Set %s to one",
		strings.Join(tried, "; "), lintTestDiskDirEnv)
	return ""
}

// modeOf is a path's own mode: a symlink is not followed.
func modeOf(t *testing.T, path string) os.FileMode {
	t.Helper()
	info, err := os.Lstat(path)
	if err != nil {
		t.Fatalf("lstat %s: %v", path, err)
	}
	return info.Mode()
}

// D1b security R1: a configured base lives strictly below an allowlisted
// prefix, never in a system or shared directory, and is a clean path.
func TestValidLintWorkdirBase_OnlyACleanPathBelowAnAllowedPrefix(t *testing.T) {
	for _, bad := range []string{"", "lint", "/", "/srv/../lint", "/persist", "/srv", "/var/lib", "/etc/lint",
		"/root", "/var/tmp", "/usr/local/lint", "/proc/1", "/tmp/lint", "/persistx/lint", "/var/library/lint"} {
		if err := validLintWorkdirBase(bad); err == nil {
			t.Fatalf("%q must be refused", bad)
		}
	}
	for _, good := range []string{lintPersistBase, lintVarLibBase, "/srv/lint", "/persist/a/b"} {
		if err := validLintWorkdirBase(good); err != nil {
			t.Fatalf("%q must be accepted: %v", good, err)
		}
	}
}

// D1b security R1: a base that fails a check is refused before anything is
// created or changed. Each arm names what must stay as it was.
func TestPrepareLintWorkdirBase_RefusesWithoutTouchingAnything(t *testing.T) {
	mkdir := func(t *testing.T, path string, mode os.FileMode) string {
		t.Helper()
		if err := os.Mkdir(path, 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(path, mode); err != nil {
			t.Fatal(err)
		}
		return path
	}
	type watched struct {
		path   string
		absent bool // must not come to exist; otherwise must keep its mode
	}
	for name, tc := range map[string]struct {
		own   bool
		setup func(t *testing.T, parent string) (string, watched)
		want  string
	}{
		"an unclean path": {setup: func(t *testing.T, parent string) (string, watched) {
			return parent + "/x/../lint", watched{path: filepath.Join(parent, "lint"), absent: true}
		}, want: "clean"},
		"the base is a symlink": {own: true, setup: func(t *testing.T, parent string) (string, watched) {
			real := mkdir(t, filepath.Join(parent, "real"), 0o700)
			link := filepath.Join(parent, "link")
			if err := os.Symlink(real, link); err != nil {
				t.Fatal(err)
			}
			return link, watched{path: real}
		}, want: "symlink"},
		"an ancestor is a symlink": {own: true, setup: func(t *testing.T, parent string) (string, watched) {
			real := mkdir(t, filepath.Join(parent, "real"), 0o755)
			link := filepath.Join(parent, "link")
			if err := os.Symlink(real, link); err != nil {
				t.Fatal(err)
			}
			return filepath.Join(link, "lint"), watched{path: filepath.Join(real, "lint"), absent: true}
		}, want: "symlink"},
		"an ancestor is a file": {own: true, setup: func(t *testing.T, parent string) (string, watched) {
			file := filepath.Join(parent, "file")
			if err := os.WriteFile(file, nil, 0o644); err != nil {
				t.Fatal(err)
			}
			return filepath.Join(file, "lint"), watched{path: file}
		}, want: "not a directory"},
		"an existing base another user owns": {setup: func(t *testing.T, parent string) (string, watched) {
			dir := mkdir(t, filepath.Join(parent, "other"), 0o711)
			if os.Getuid() == 0 {
				if err := os.Chown(dir, 65534, 65534); err != nil {
					t.Fatal(err)
				}
			}
			return dir, watched{path: dir}
		}, want: "owned by"},
		"an existing base more open than 0711": {own: true, setup: func(t *testing.T, parent string) (string, watched) {
			dir := mkdir(t, filepath.Join(parent, "open"), 0o755)
			return dir, watched{path: dir}
		}, want: "mode"},
		"an existing base like /var/tmp (1777)": {own: true, setup: func(t *testing.T, parent string) (string, watched) {
			dir := mkdir(t, filepath.Join(parent, "sticky"), os.ModeSticky|0o777)
			return dir, watched{path: dir}
		}, want: "mode"},
		"an existing base the sandbox user cannot traverse": {own: true, setup: func(t *testing.T, parent string) (string, watched) {
			dir := mkdir(t, filepath.Join(parent, "closed"), 0o700)
			return dir, watched{path: dir}
		}, want: "mode"},
		"an existing 0711 base that is setgid": {own: true, setup: func(t *testing.T, parent string) (string, watched) {
			dir := mkdir(t, filepath.Join(parent, "setgid"), os.ModeSetgid|0o711)
			return dir, watched{path: dir}
		}, want: "mode"},
		"the base is a 0711 file": {own: true, setup: func(t *testing.T, parent string) (string, watched) {
			file := filepath.Join(parent, "file")
			if err := os.WriteFile(file, nil, 0o600); err != nil {
				t.Fatal(err)
			}
			if err := os.Chmod(file, 0o711); err != nil {
				t.Fatal(err)
			}
			return file, watched{path: file}
		}, want: "not a directory"},
	} {
		t.Run(name, func(t *testing.T) {
			parent := diskParent(t)
			allowLintBase(t, parent, tc.own)
			base, w := tc.setup(t, parent)
			var before os.FileMode
			if !w.absent {
				before = modeOf(t, w.path)
			}

			err := prepareLintWorkdirBase(base)
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("expected a refusal naming %q, got: %v", tc.want, err)
			}
			if w.absent {
				if _, err := os.Lstat(w.path); !os.IsNotExist(err) {
					t.Fatalf("%s must not be created (lstat err %v)", w.path, err)
				}
			} else if after := modeOf(t, w.path); after != before {
				t.Fatalf("%s must keep its mode: %v -> %v", w.path, before, after)
			}
		})
	}
}

// D1b security R1: the RAM check runs on the nearest existing directory
// BEFORE anything is created or changed.
func TestPrepareLintWorkdirBase_RefusesARAMBackedBaseBeforeCreatingOrChangingIt(t *testing.T) {
	var fs syscall.Statfs_t
	if err := syscall.Statfs("/dev/shm", &fs); err != nil || diskBackedFS(int64(fs.Type)) {
		t.Skip("/dev/shm is not RAM-backed here")
	}
	shm, err := os.MkdirTemp("/dev/shm", "lint-discovery-test-")
	if err != nil {
		t.Skipf("cannot write /dev/shm: %v", err)
	}
	t.Cleanup(func() { os.RemoveAll(shm) })
	allowLintBase(t, shm, true)

	fresh := filepath.Join(shm, "lint-discovery")
	if err := prepareLintWorkdirBase(fresh); err == nil || !strings.Contains(err.Error(), "RAM-backed") {
		t.Fatalf("a base on tmpfs must be refused as RAM-backed, got: %v", err)
	}
	if _, err := os.Lstat(fresh); !os.IsNotExist(err) {
		t.Fatalf("a refused base must not be created (lstat err %v)", err)
	}

	existing := filepath.Join(shm, "existing")
	if err := os.Mkdir(existing, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(existing, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := prepareLintWorkdirBase(existing); err == nil || !strings.Contains(err.Error(), "RAM-backed") {
		t.Fatalf("an existing base on tmpfs must be refused as RAM-backed, got: %v", err)
	}
	if m := modeOf(t, existing).Perm(); m != 0o700 {
		t.Fatalf("a refused base must keep its mode: 0700 -> %#o", m)
	}
}

func TestPrepareLintWorkdirBase_CreatesAFreshBase0711(t *testing.T) {
	parent := diskParent(t)
	allowLintBase(t, parent, false)
	base := filepath.Join(parent, "a", "lint-discovery")

	if err := prepareLintWorkdirBase(base); err != nil {
		t.Fatalf("a fresh disk-backed base must be created: %v", err)
	}
	if m := modeOf(t, base); !m.IsDir() || m.Perm() != 0o711 {
		t.Fatalf("a fresh base must be a 0711 directory, got %v", m)
	}
}

// D1b security R1: an existing base that passes every check is used exactly
// as it is; the agent never changes a directory it did not just create.
func TestPrepareLintWorkdirBase_LeavesAnAcceptedExistingBaseAlone(t *testing.T) {
	for _, perm := range []os.FileMode{0o711, 0o701} {
		parent := diskParent(t)
		allowLintBase(t, parent, true)
		base := filepath.Join(parent, "lint-discovery")
		if err := os.Mkdir(base, 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(base, perm); err != nil {
			t.Fatal(err)
		}

		if err := prepareLintWorkdirBase(base); err != nil {
			t.Fatalf("an existing %#o base must be accepted: %v", perm, err)
		}
		if m := modeOf(t, base).Perm(); m != perm {
			t.Fatalf("an accepted base must keep its mode: %#o -> %#o", perm, m)
		}
	}
}

func TestLintDiscovery_TheContextNeverWidensTheTask(t *testing.T) {
	isolatedTmp(t)
	httpc := &recordingHTTP{getBody: lintContextBody}
	ex := &lintExec{lint: lintReply{stdout: []byte(okLintStdout)}}
	h := &ModuleBuildHandler{HTTP: httpc, LintWorkdirBase: lintTestBase(t), Lint: ex}

	if _, err := h.Execute(context.Background(), lintTask("repo-1")); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	clones := ex.phase(lintCloneScript)
	if len(clones) != 1 || clones[0].env["LINT_GIT_TOKEN"] != tokenOne {
		t.Fatalf("only the named repository may run, clones: %d", len(clones))
	}
}

// The token as it can appear on the way out: raw, percent-encoded (a clone
// URL) and JSON-escaped. It carries characters each encoding changes.
const oddToken = `se<cr/et+1111"x`

func TestLintDiscovery_ScrubsEverySiteThatSendsTextBack(t *testing.T) {
	// Go's own JSON escaping also escapes <, > and &: se<cr/... (critic L5a).
	goJSON, _ := json.Marshal(oddToken)
	encodings := map[string]string{
		"raw":     oddToken,
		"query":   url.QueryEscape(oddToken),
		"path":    url.PathEscape(oddToken),
		"json":    `se<cr/et+1111\"x`,
		"go-json": string(goJSON[1 : len(goJSON)-1]),
	}
	if encodings["go-json"] == encodings["json"] || strings.ContainsRune(encodings["go-json"], '<') {
		t.Fatalf("the go-json form must escape <, got %s", encodings["go-json"])
	}
	for enc, leaked := range encodings {
		cases := map[string]struct {
			ex    *lintExec
			httpc func(ctx string) *recordingHTTP
		}{
			"clone stderr": {
				ex: &lintExec{clone: lintReply{stderr: []byte("fatal: unable to access 'https://x-access-token:" + leaked + "@git.example.test/'"),
					err: errors.New("exit status 128")}},
			},
			"clone stdout": {
				ex: &lintExec{clone: lintReply{stdout: []byte("echo " + leaked), err: errors.New("exit status 1")}},
			},
			"lint stderr": {
				ex: &lintExec{lint: lintReply{stderr: []byte("boom " + leaked), err: errors.New("exit status 2")}},
			},
			"lint result that is not JSON": {
				ex: &lintExec{lint: lintReply{stdout: []byte("not json " + leaked + "\n")}},
			},
			"result transport error": {
				ex: &lintExec{lint: lintReply{stdout: []byte(okLintStdout)}},
				httpc: func(ctx string) *recordingHTTP {
					return &recordingHTTP{getBody: ctx, postErr: errors.New("dial https://x:" + leaked + "@platform")}
				},
			},
			"result refusal body": {
				ex: &lintExec{lint: lintReply{stdout: []byte(okLintStdout)}},
				httpc: func(ctx string) *recordingHTTP {
					return &recordingHTTP{getBody: ctx, postStatus: http.StatusUnprocessableEntity,
						postBody: `{"success":false,"error":"echoed ` + leaked + `"}`}
				},
			},
		}
		for site, tc := range cases {
			t.Run(enc+"/"+site, func(t *testing.T) {
				isolatedTmp(t)
				ctx := contextWith(t, "https://git.example.test/acme/core.git", oddToken)
				httpc := &recordingHTTP{getBody: ctx}
				if tc.httpc != nil {
					httpc = tc.httpc(ctx)
				}
				h := &ModuleBuildHandler{HTTP: httpc, LintWorkdirBase: lintTestBase(t), Lint: tc.ex}

				_, err := h.Execute(context.Background(), lintTask("repo-1"))
				if err == nil {
					t.Fatal("expected the only repository's failure to fail the task")
				}
				for name, v := range encodings {
					if strings.Contains(err.Error(), v) {
						t.Fatalf("error text carries the %s form of the credential: %v", name, err)
					}
				}
				if !strings.Contains(err.Error(), "[REDACTED]") {
					t.Fatalf("the diagnosis must survive with the credential redacted, got: %v", err)
				}
			})
		}
	}
}

// A secret straddling the log-tail cut must not leave a fragment behind:
// scrub the whole stream first, then bound it.
func TestLintDiscovery_ScrubsBeforeTruncating(t *testing.T) {
	isolatedTmp(t)
	fragment := tokenOne[len(tokenOne)-5:] // "-1111"
	stderr := tokenOne + strings.Repeat("y", logTailStderrMaxBytes-5)
	if cut := len(stderr) - logTailStderrMaxBytes; cut <= 0 || cut >= len(tokenOne) {
		t.Fatalf("fixture must place the cut inside the token, cut at %d", cut)
	}
	httpc := &recordingHTTP{getBody: lintContextBody}
	ex := &lintExec{clone: lintReply{stderr: []byte(stderr), err: errors.New("exit status 128")}}
	h := &ModuleBuildHandler{HTTP: httpc, LintWorkdirBase: lintTestBase(t), Lint: ex}

	_, err := h.Execute(context.Background(), lintTask("repo-1"))
	if err == nil {
		t.Fatal("expected an error")
	}
	if strings.Contains(err.Error(), fragment) {
		t.Fatalf("a fragment of the credential survived the cut: %.200s", err)
	}
}

func TestLintDiscovery_BoundsFailureText(t *testing.T) {
	isolatedTmp(t)
	httpc := &recordingHTTP{getBody: lintContextBody}
	ex := &lintExec{clone: lintReply{stderr: []byte(strings.Repeat("z", 1<<20)), err: errors.New("exit status 128")}}
	h := &ModuleBuildHandler{HTTP: httpc, LintWorkdirBase: lintTestBase(t), Lint: ex}

	_, err := h.Execute(context.Background(), lintTask("repo-1", "repo-2"))
	if err == nil {
		t.Fatal("expected an error")
	}
	if n := len(err.Error()); n > lintFailuresMaxBytes+64 {
		t.Fatalf("failure text is %d bytes, bound is %d", n, lintFailuresMaxBytes)
	}
}

func TestLintDiscovery_WithholdsAResultThatCarriesTheCredential(t *testing.T) {
	for name, leaked := range map[string]string{"raw": oddToken, "query-encoded": url.QueryEscape(oddToken)} {
		t.Run(name, func(t *testing.T) {
			isolatedTmp(t)
			out, _ := json.Marshal(map[string]any{"linters": map[string]any{
				"ruby": map[string]any{"status": "ran", "exitstatus": 1, "output": "token=" + leaked}}})
			httpc := &recordingHTTP{getBody: contextWith(t, "https://git.example.test/acme/core.git", oddToken)}
			ex := &lintExec{lint: lintReply{stdout: append(out, '\n')}}
			h := &ModuleBuildHandler{HTTP: httpc, LintWorkdirBase: lintTestBase(t), Lint: ex}

			_, err := h.Execute(context.Background(), lintTask("repo-1"))
			if err == nil || !strings.Contains(err.Error(), "result withheld") {
				t.Fatalf("expected the result to be withheld, got: %v", err)
			}
			if len(httpc.posts) != 0 {
				t.Fatalf("a result carrying the credential must never be posted, posts: %d", len(httpc.posts))
			}
		})
	}
}

func TestLintDiscovery_RejectsCloneURLsBeforeRunningAnything(t *testing.T) {
	for _, bad := range []string{
		"http://git.example.test/acme/core.git",
		"https://user:pw-in-url@git.example.test/acme/core.git",
		"https://pw-in-url@git.example.test/acme/core.git",
		"git@git.example.test:acme/core.git",
		"ssh://git.example.test/acme/core.git",
		"file:///etc/passwd",
		"https:///no-host",
		"ext::sh -c touch% /tmp/pwned",
	} {
		t.Run(bad, func(t *testing.T) {
			isolatedTmp(t)
			httpc := &recordingHTTP{getBody: contextWith(t, bad, tokenOne)}
			ex := &lintExec{lint: lintReply{stdout: []byte(okLintStdout)}}
			h := &ModuleBuildHandler{HTTP: httpc, LintWorkdirBase: lintTestBase(t), Lint: ex}

			_, err := h.Execute(context.Background(), lintTask("repo-1"))
			if err == nil || !strings.Contains(err.Error(), "clone URL rejected") {
				t.Fatalf("expected a clone URL refusal, got: %v", err)
			}
			if strings.Contains(err.Error(), "pw-in-url") {
				t.Fatalf("the refusal repeats the URL's credential: %v", err)
			}
			if len(ex.prepared) != 0 || len(ex.calls) != 0 || len(httpc.posts) != 0 {
				t.Fatalf("nothing may run for a rejected URL: prepared %d, runs %d, posts %d",
					len(ex.prepared), len(ex.calls), len(httpc.posts))
			}
		})
	}
}

func TestLintDiscovery_AConflictMeansAlreadyReported(t *testing.T) {
	isolatedTmp(t)
	httpc := &recordingHTTP{getBody: lintContextBody, postStatus: http.StatusConflict}
	ex := &lintExec{lint: lintReply{stdout: []byte(okLintStdout)}}
	h := &ModuleBuildHandler{HTTP: httpc, LintWorkdirBase: lintTestBase(t), Lint: ex}

	result, err := h.Execute(context.Background(), lintTask("repo-1"))
	if err != nil {
		t.Fatalf("a 409 is the platform already holding the result, not a failure: %v", err)
	}
	if result["reported"] != 1 || result["failed"] != 0 {
		t.Fatalf("result: %+v", result)
	}
}

func TestLintDiscovery_AnyOtherRefusalIsAFailure(t *testing.T) {
	isolatedTmp(t)
	httpc := &recordingHTTP{getBody: lintContextBody, postStatus: http.StatusForbidden,
		postBody: `{"success":false,"error":"lease expired"}`}
	ex := &lintExec{lint: lintReply{stdout: []byte(okLintStdout)}}
	h := &ModuleBuildHandler{HTTP: httpc, LintWorkdirBase: lintTestBase(t), Lint: ex}

	_, err := h.Execute(context.Background(), lintTask("repo-1"))
	if err == nil || !strings.Contains(err.Error(), "status 403") {
		t.Fatalf("expected the refusal to surface, got: %v", err)
	}
}

func TestLintDiscovery_ASandboxThatCannotBePreparedRunsNothing(t *testing.T) {
	isolatedTmp(t)
	httpc := &recordingHTTP{getBody: lintContextBody}
	ex := &lintExec{prepareErr: errors.New("chown: operation not permitted")}
	h := &ModuleBuildHandler{HTTP: httpc, LintWorkdirBase: lintTestBase(t), Lint: ex}

	if _, err := h.Execute(context.Background(), lintTask("repo-1")); err == nil {
		t.Fatal("expected an error")
	}
	if len(ex.calls) != 0 {
		t.Fatalf("no phase may run in a workdir the sandbox user does not own, runs: %d", len(ex.calls))
	}
}

func TestLintDiscovery_ACloneFailureSkipsTheLintPhase(t *testing.T) {
	isolatedTmp(t)
	httpc := &recordingHTTP{getBody: lintContextBody}
	ex := &lintExec{clone: lintReply{err: errors.New("exit status 128")}, lint: lintReply{stdout: []byte(okLintStdout)}}
	h := &ModuleBuildHandler{HTTP: httpc, LintWorkdirBase: lintTestBase(t), Lint: ex}

	if _, err := h.Execute(context.Background(), lintTask("repo-1")); err == nil {
		t.Fatal("expected an error")
	}
	if n := len(ex.phase(lintDiscoveryScript)); n != 0 {
		t.Fatalf("the lint phase ran %d times after a failed clone", n)
	}
}

func TestLintDiscovery_CountsAPartialFailureWithoutFailingTheTask(t *testing.T) {
	isolatedTmp(t)
	httpc := &recordingHTTP{getBody: lintContextBody}
	ex := &lintExec{lint: lintReply{stdout: []byte(okLintStdout)}}
	h := &ModuleBuildHandler{HTTP: httpc, LintWorkdirBase: lintTestBase(t), Lint: ex}

	result, err := h.Execute(context.Background(), lintTask("repo-1", "repo-missing"))
	if err != nil {
		t.Fatalf("one repository reported, so the task must not fail: %v", err)
	}
	if result["reported"] != 1 || result["failed"] != 1 {
		t.Fatalf("result: %+v", result)
	}
}

func TestLintDiscovery_ContextRefusedRunsNothing(t *testing.T) {
	isolatedTmp(t)
	httpc := &recordingHTTP{getStatus: http.StatusForbidden, getBody: `{"success":false,"error":"Instance has no active lint_discovery lease"}`}
	ex := &lintExec{lint: lintReply{stdout: []byte(okLintStdout)}}
	h := &ModuleBuildHandler{HTTP: httpc, LintWorkdirBase: lintTestBase(t), Lint: ex}

	if _, err := h.Execute(context.Background(), lintTask("repo-1")); err == nil {
		t.Fatal("expected an error when the lint context is refused")
	}
	if len(ex.calls) != 0 || len(httpc.posts) != 0 {
		t.Fatalf("nothing may run or post without the context, runs %d posts %d", len(ex.calls), len(httpc.posts))
	}
}

func TestLintDiscovery_MissingOptions(t *testing.T) {
	httpc := &recordingHTTP{getBody: lintContextBody}
	ex := &lintExec{}
	h := &ModuleBuildHandler{HTTP: httpc, LintWorkdirBase: lintTestBase(t), Lint: ex}

	for i, opts := range []map[string]any{
		{"repository_ids": []any{"repo-1"}},
		{"run_ref": "lease-1"},
		{"run_ref": "lease-1", "repository_ids": []any{}},
	} {
		if _, err := h.Execute(context.Background(), &tasks.Task{Command: "ci.lint_discovery", Options: opts}); err == nil {
			t.Fatalf("case %d: expected a validation error", i)
		}
	}
	if len(httpc.gets) != 0 || len(ex.calls) != 0 {
		t.Fatalf("nothing may be fetched or run before options validate")
	}
}

func TestCIHandler_RefusesACommandNotOnTheAllowlist(t *testing.T) {
	httpc := &recordingHTTP{getBody: lintContextBody}
	ex := &lintExec{}
	h := &ModuleBuildHandler{HTTP: httpc, LintWorkdirBase: lintTestBase(t), Lint: ex, Exec: &fakeExec{}}

	_, err := h.Execute(context.Background(), &tasks.Task{Command: "ci.anything_else", Options: map[string]any{}})
	if err == nil || !strings.Contains(err.Error(), "not on the allowlist") {
		t.Fatalf("expected an allowlist refusal, got: %v", err)
	}
	if len(httpc.gets) != 0 || len(ex.calls) != 0 {
		t.Fatalf("a refused command may fetch or run nothing")
	}
}

// registerAndWait calls a real registration entry point with base as the
// lint workdir base (never the node's real one) and waits for its start-up
// sweep to finish, so no sweep outlives the test.
func registerAndWait(t *testing.T, register func(*tasks.Registry, tasks.Dependencies), base string,
	onError func(string, error)) (*tasks.Registry, int, error) {
	t.Helper()
	type result struct {
		n   int
		err error
	}
	done := make(chan result, 1)
	prev := lintStartSweepDone
	lintStartSweepDone = func(n int, err error) { done <- result{n, err} }
	t.Cleanup(func() { lintStartSweepDone = prev })

	r := tasks.NewRegistry()
	register(r, tasks.Dependencies{LintWorkdirBase: base, OnError: onError})
	select {
	case res := <-done:
		return r, res.n, res.err
	case <-time.After(5 * time.Second):
		t.Fatal("the start-up sweep never ran")
		return nil, 0, nil
	}
}

// D1b security R2, the start path, through the real entry point the agent's
// service calls once at start: only a stale workdir an earlier process left
// is removed. A foreign-named directory, a symlink named like a workdir, and
// what that symlink points at all stay.
func TestRegisterDefaults_SweepsStaleWorkdirsAtStart(t *testing.T) {
	parent := diskParent(t)
	allowLintBase(t, parent, true)
	base, victim := filepath.Join(parent, "base"), filepath.Join(parent, "victim")
	stale := filepath.Join(base, lintWorkdirPrefix+"0ldtoken-1")
	foreign := filepath.Join(base, "not-a-workdir")
	link := filepath.Join(base, lintWorkdirPrefix+"0ldtoken-link")
	for _, d := range []string{filepath.Join(stale, "src"), foreign, victim} {
		if err := os.MkdirAll(d, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Chmod(base, 0o711); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(victim, "keep"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(victim, link); err != nil {
		t.Fatal(err)
	}

	_, removed, err := registerAndWait(t, RegisterDefaults, base, nil)
	if err != nil || removed != 1 {
		t.Fatalf("the start-up sweep removed %d (err %v), want the 1 stale workdir", removed, err)
	}
	if _, err := os.Lstat(stale); !os.IsNotExist(err) {
		t.Fatalf("the stale workdir must be removed at start (lstat err %v)", err)
	}
	for _, kept := range []string{foreign, link, base, filepath.Join(victim, "keep")} {
		if _, err := os.Lstat(kept); err != nil {
			t.Fatalf("%s must be kept: %v", kept, err)
		}
	}
}

// A base that fails the checks is not swept, and the refusal reaches the
// service's error reporter instead of vanishing.
func TestRegisterDefaults_ReportsAStartSweepItRefused(t *testing.T) {
	parent := diskParent(t)
	allowLintBase(t, parent, false) // the base's owner is not the required one
	base := filepath.Join(parent, "base")
	stale := filepath.Join(base, lintWorkdirPrefix+"0ldtoken-1")
	if err := os.MkdirAll(stale, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(base, 0o711); err != nil {
		t.Fatal(err)
	}
	if os.Getuid() == 0 {
		if err := os.Chown(base, 65534, 65534); err != nil {
			t.Fatal(err)
		}
	}
	var stages []string
	_, _, err := registerAndWait(t, RegisterDefaults, base, func(stage string, err error) { stages = append(stages, stage) })

	if err == nil || len(stages) != 1 || stages[0] != "lint_workdir_sweep" {
		t.Fatalf("a refused start-up sweep must be reported as lint_workdir_sweep: err %v, reported %v", err, stages)
	}
	if _, err := os.Lstat(stale); err != nil {
		t.Fatalf("a refused base must not be swept: %v", err)
	}
}

func TestRegisterModuleBuild_BindsEveryAllowlistedCommandToTheSandboxedHandler(t *testing.T) {
	r, _, _ := registerAndWait(t, RegisterModuleBuild, lintTestBase(t), nil)

	for _, command := range []string{"ci.module_build", "ci.lint_discovery"} {
		got, ok := r.Lookup(command)
		if !ok {
			t.Fatalf("%s is not registered", command)
		}
		h, ok := got.(*ModuleBuildHandler)
		if !ok {
			t.Fatalf("%s is bound to %T", command, got)
		}
		if _, ok := h.Lint.(sandboxRunner); !ok {
			t.Fatalf("%s: the lint runner is %T, want the sandbox runner", command, h.Lint)
		}
	}
	if n := len(r.Commands()); n != 2 {
		t.Fatalf("registered %d commands, want exactly the 2 on the allowlist: %v", n, r.Commands())
	}
}

func TestSandboxCommand_UnprivilegedOwnGroupExactEnvironment(t *testing.T) {
	t.Setenv("LINT_TEST_INHERITED_SECRET", "agent-side-value")
	env := []string{"PATH=" + lintSandboxPath, "WORKDIR=/w"}
	cmd := sandboxCommand(context.Background(), lintDiscoveryScript, env, "/w")

	if strings.Join(cmd.Env, "\n") != strings.Join(env, "\n") {
		t.Fatalf("env must be exactly what the handler built, got %v", cmd.Env)
	}
	if cmd.Dir != "/w" {
		t.Fatalf("dir = %q", cmd.Dir)
	}
	attr := cmd.SysProcAttr
	if attr == nil || !attr.Setpgid {
		t.Fatalf("the phase must run in its own process group: %+v", attr)
	}
	cred := attr.Credential
	if cred == nil || cred.Uid != lintSandboxUID || cred.Gid != lintSandboxGID || cred.Groups == nil || len(cred.Groups) != 0 {
		t.Fatalf("the phase must run as %d:%d with no supplementary groups: %+v", lintSandboxUID, lintSandboxGID, cred)
	}
	if lintSandboxUID == 0 || lintSandboxGID == 0 {
		t.Fatal("the sandbox identity must not be root")
	}
	if attr.Cloneflags&syscall.CLONE_NEWPID == 0 {
		t.Fatalf("the phase must run in its own PID namespace: cloneflags %#x", attr.Cloneflags)
	}
	if cmd.Cancel == nil || cmd.WaitDelay != lintWaitDelay {
		t.Fatalf("cancellation must kill the group and bound the wait: cancel set %v, wait delay %v", cmd.Cancel != nil, cmd.WaitDelay)
	}
}

// Root only: the sandbox user is real, so this runs the actual runner and
// proves a background process the phase started does not outlive it.
func TestSandboxRunner_KillsWhatThePhaseLeftBehind(t *testing.T) {
	if os.Geteuid() != 0 {
		t.Skip("needs root to switch to the sandbox user")
	}
	// Not t.TempDir(): the testing package makes its parent 0700, which the
	// sandbox user cannot traverse (D1b correctness N2). This directory and
	// every directory above it must be traversable by others.
	dir, err := os.MkdirTemp("", "lint-sandbox-test-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	if err := os.Chmod(dir, 0o711); err != nil {
		t.Fatal(err)
	}
	for p := dir; ; p = filepath.Dir(p) {
		info, err := os.Stat(p)
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode().Perm()&0o001 == 0 {
			t.Fatalf("%s is not traversable by the sandbox user; run with TMPDIR=/tmp", p)
		}
		if p == "/" {
			break
		}
	}
	workdir, err := os.MkdirTemp(dir, lintWorkdirPrefix)
	if err != nil {
		t.Fatal(err)
	}
	if err := (sandboxRunner{}).Prepare(workdir); err != nil {
		t.Fatal(err)
	}
	// The phase's own pids are namespace pids (its first process is pid 1;
	// `echo $!` printed 2, and the host's pid 2 always exists), so the
	// escapees are found on the host by a marker in argv[0] (D1b N2).
	marker := survivorMarker(t)
	script := filepath.Join(dir, "phase.sh")
	body := fmt.Sprintf(`#!/bin/bash
( exec -a %[1]s-bg sleep 300 ) </dev/null >/dev/null 2>&1 &
setsid bash -c 'exec -a %[1]s-setsid sleep 300' </dev/null >/dev/null 2>&1 &
for _ in $(seq 50); do pgrep -f '^%[1]s-bg ' >/dev/null && pgrep -f '^%[1]s-setsid ' >/dev/null && break; sleep 0.1; done
echo "started $(pgrep -fc '^%[1]s-(bg|setsid) ')"
id -u
`, marker)
	if err := os.WriteFile(script, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}

	stdout, _, err := (sandboxRunner{}).Run(context.Background(), script, []string{"PATH=" + lintSandboxPath}, workdir,
		lintCloneStdoutMaxBytes)
	if err != nil {
		t.Fatalf("run: %v", err)
	}
	if got := strings.TrimSpace(string(stdout)); got != "started 2\n65534" {
		t.Fatalf("the phase must start both escapees and run as the sandbox user, stdout %q", stdout)
	}
	if left := processesCarrying(marker); len(left) != 0 {
		t.Fatalf("processes %v outlived the phase", left)
	}
}

// unprivilegedRunner is the REAL runner with its test seam on: the same PID
// namespace, start, wait and overflow paths, created through a user namespace
// so the gate runs them without root (D1b critic M2).
func unprivilegedRunner(t *testing.T) sandboxRunner {
	t.Helper()
	probe := exec.Command("true")
	probe.SysProcAttr = &syscall.SysProcAttr{
		Cloneflags:                 syscall.CLONE_NEWUSER | syscall.CLONE_NEWPID,
		UidMappings:                []syscall.SysProcIDMap{{ContainerID: 0, HostID: os.Getuid(), Size: 1}},
		GidMappings:                []syscall.SysProcIDMap{{ContainerID: 0, HostID: os.Getgid(), Size: 1}},
		GidMappingsEnableSetgroups: false,
	}
	if err := probe.Run(); err != nil {
		t.Skipf("unprivileged user namespaces are unavailable on this host: %v", err)
	}
	return sandboxRunner{unprivileged: true, waitDelay: 2 * time.Second}
}

// phaseScript writes a bash phase into its own directory and returns the
// script and a workdir for it.
func phaseScript(t *testing.T, body string) (script, workdir string) {
	t.Helper()
	dir := t.TempDir()
	script = filepath.Join(dir, "phase.sh")
	if err := os.WriteFile(script, []byte("#!/bin/bash\n"+body), 0o755); err != nil {
		t.Fatal(err)
	}
	workdir = filepath.Join(dir, "work")
	if err := os.Mkdir(workdir, 0o700); err != nil {
		t.Fatal(err)
	}
	return script, workdir
}

// processesCarrying lists the pids whose command line carries marker. The
// marker rides in argv[0] (`exec -a`), which a pid inside the phase's
// namespace cannot hide from the host's /proc.
func processesCarrying(marker string) []int {
	entries, _ := os.ReadDir("/proc")
	var pids []int
	for _, e := range entries {
		pid, err := strconv.Atoi(e.Name())
		if err != nil {
			continue
		}
		cmdline, err := os.ReadFile(filepath.Join("/proc", e.Name(), "cmdline"))
		if err == nil && bytes.Contains(cmdline, []byte(marker)) {
			pids = append(pids, pid)
		}
	}
	return pids
}

// survivorMarker is unique per test, and anything carrying it is killed when
// the test ends, so a failing run leaves nothing behind.
func survivorMarker(t *testing.T) string {
	t.Helper()
	marker := fmt.Sprintf("lint-survivor-%d", time.Now().UnixNano())
	t.Cleanup(func() {
		for _, pid := range processesCarrying(marker) {
			_ = syscall.Kill(pid, syscall.SIGKILL)
		}
	})
	return marker
}

// D1b critic H1. A process that leaves the phase's process group (setsid) or
// is double-forked used to survive the phase, as the same uid, and could read
// the NEXT repository's clone-phase environment. The phase's PID namespace
// takes all of them with it: none is alive when Run returns.
func TestSandboxRunner_NothingThePhaseStartedOutlivesIt(t *testing.T) {
	runner := unprivilegedRunner(t)
	marker := survivorMarker(t)
	script, workdir := phaseScript(t, fmt.Sprintf(`setsid bash -c 'exec -a %[1]s-setsid sleep 300' </dev/null >/dev/null 2>&1 &
( ( exec -a %[1]s-double sleep 300 ) </dev/null >/dev/null 2>&1 & )
for _ in $(seq 50); do pgrep -f '^%[1]s-setsid ' >/dev/null && pgrep -f '^%[1]s-double ' >/dev/null && break; sleep 0.1; done
echo started "$(pgrep -fc '^%[1]s-(setsid|double) ')"
`, marker))

	stdout, _, err := runner.Run(context.Background(), script, []string{"PATH=" + lintSandboxPath}, workdir, lintCloneStdoutMaxBytes)
	if err != nil {
		t.Fatalf("run: %v", err)
	}
	if strings.TrimSpace(string(stdout)) != "started 2" {
		t.Fatalf("the phase must have started both escapees before it exited, stdout %q", stdout)
	}
	if left := processesCarrying(marker); len(left) != 0 {
		t.Fatalf("processes %v outlived the phase", left)
	}
}

// A phase cut off by its bound takes its whole namespace with it too.
func TestSandboxRunner_ACancelledPhaseTakesItsWholeNamespace(t *testing.T) {
	runner := unprivilegedRunner(t)
	marker := survivorMarker(t)
	script, workdir := phaseScript(t, fmt.Sprintf(`setsid bash -c 'exec -a %[1]s-setsid sleep 300' </dev/null >/dev/null 2>&1 &
exec -a %[1]s-phase sleep 300
`, marker))
	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()

	started := time.Now()
	if _, _, err := runner.Run(ctx, script, []string{"PATH=" + lintSandboxPath}, workdir, lintCloneStdoutMaxBytes); err == nil {
		t.Fatal("a phase killed at its bound must fail")
	}
	// D1b correctness L8: promptly, at the bound, not at the WaitDelay
	// backstop (2 s here, 10 s in production).
	if took := time.Since(started); took > 1500*time.Millisecond {
		t.Fatalf("the cancelled phase took %v to end; it must end within 1s of its 500ms bound", took)
	}
	if left := processesCarrying(marker); len(left) != 0 {
		t.Fatalf("processes %v outlived the cancelled phase", left)
	}
}

// The agent-side half of the output limit: more stdout than the bound is an
// error, never a cut result that could be parsed; at the bound it is not.
func TestSandboxRunner_StdoutOverTheBoundIsAnError(t *testing.T) {
	runner := unprivilegedRunner(t)
	script, workdir := phaseScript(t, `printf '%s' "$(head -c "$N" /dev/zero | tr '\0' 'a')"`+"\n")

	stdout, _, err := runner.Run(context.Background(), script, []string{"PATH=" + lintSandboxPath, "N=10"}, workdir, 10)
	if err != nil || len(stdout) != 10 {
		t.Fatalf("exactly at the bound: %d bytes, err %v", len(stdout), err)
	}
	stdout, _, err = runner.Run(context.Background(), script, []string{"PATH=" + lintSandboxPath, "N=11"}, workdir, 10)
	if err == nil || !strings.Contains(err.Error(), "stdout exceeded 10 bytes") {
		t.Fatalf("one byte over the bound must be an error, got %v", err)
	}
	if len(stdout) != 10 {
		t.Fatalf("the agent must keep at most the bound, kept %d bytes", len(stdout))
	}
}

// Security critic L2. The credential here reaches only the wrapped error, so
// phaseError's own scrub is the only thing between it and the cut: the pad
// puts the cut inside the token, and the task's final scrub cannot redact a
// fragment of it.
func TestLintDiscovery_ScrubsThePhaseErrorBeforeCuttingIt(t *testing.T) {
	isolatedTmp(t)
	keep := 12 // the cut would keep "LINT-TOKEN-1"
	pad := strings.Repeat("y", lintFailureMaxBytes-len("clone: ")-keep)
	httpc := &recordingHTTP{getBody: lintContextBody}
	ex := &lintExec{clone: lintReply{err: errors.New(pad + tokenOne)}}
	h := &ModuleBuildHandler{HTTP: httpc, LintWorkdirBase: lintTestBase(t), Lint: ex}

	_, err := h.Execute(context.Background(), lintTask("repo-1"))
	if err == nil {
		t.Fatal("expected the clone failure to surface")
	}
	if strings.Contains(err.Error(), tokenOne[:keep]) {
		t.Fatalf("a fragment of the credential survived the cut: …%s", err.Error()[max(len(err.Error())-80, 0):])
	}
}

func TestCappedBuffer_KeepsTheHeadOrTheTail(t *testing.T) {
	head := &cappedBuffer{max: 4}
	head.Write([]byte("abc"))
	head.Write([]byte("defg"))
	if string(head.Bytes()) != "abcd" || !head.overflow {
		t.Fatalf("head: %q overflow %v", head.Bytes(), head.overflow)
	}

	tail := &cappedBuffer{max: 4, keepTail: true}
	for _, s := range []string{"abc", "defg", "hij"} {
		tail.Write([]byte(s))
	}
	if string(tail.Bytes()) != "ghij" || !tail.overflow {
		t.Fatalf("tail: %q overflow %v", tail.Bytes(), tail.overflow)
	}

	small := &cappedBuffer{max: 8}
	small.Write([]byte("ok"))
	if string(small.Bytes()) != "ok" || small.overflow {
		t.Fatalf("under the bound nothing is dropped: %q overflow %v", small.Bytes(), small.overflow)
	}
}

func TestModuleBuild_ScrubsEverySecretFromItsLogTail(t *testing.T) {
	httpc := &fakeHTTP{body: `{"success":true,"data":{
		"source_repo_url":"https://git.powernode.net/powernode/powernode-system.git",
		"source_token":"SRC-TOKEN",
		"parent_pat":"PARENT-TOKEN",
		"oras_registry":"registry.example.com",
		"oras_user":"oras-user",
		"oras_password":"ORAS-PW"
	}}`}
	ex := &fakeExec{
		stderr: []byte("fatal: https://x-access-token:SRC-TOKEN@git.powernode.net/x.git; parent PARENT-TOKEN; login ORAS-PW"),
		err:    errors.New("exit status 1"),
	}
	h := &ModuleBuildHandler{HTTP: httpc, Exec: ex}

	_, err := h.Execute(context.Background(), &tasks.Task{Command: "ci.module_build",
		Options: map[string]any{"module": "powernode-hub-backend", "sha": "abc123", "oci_ref": "v1"}})
	if err == nil {
		t.Fatal("expected the exec failure to surface")
	}
	for _, secret := range []string{"SRC-TOKEN", "PARENT-TOKEN", "ORAS-PW"} {
		if strings.Contains(err.Error(), secret) {
			t.Fatalf("module build error text carries %s: %v", secret, err)
		}
	}
	if strings.Count(err.Error(), "[REDACTED]") != 3 {
		t.Fatalf("expected three redactions, got: %v", err)
	}
}

func TestParseLintScriptResult(t *testing.T) {
	r, err := parseLintScriptResult([]byte("noise on stdout\n" + okLintStdout + "\n\n"))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if r.Linters["ruby"].ExitStatus == nil || *r.Linters["ruby"].ExitStatus != 1 {
		t.Fatalf("ruby report: %+v", r.Linters["ruby"])
	}

	empty, err := parseLintScriptResult([]byte(`{}` + "\n"))
	if err != nil || empty.Linters == nil || len(empty.Linters) != 0 {
		t.Fatalf("a result naming no linter is an empty map, not nil: %+v %v", empty, err)
	}

	if _, err := parseLintScriptResult(nil); err == nil {
		t.Fatal("no output must be an error")
	}
	if _, err := parseLintScriptResult([]byte("not json\n")); err == nil {
		t.Fatal("a non-JSON last line must be an error")
	}
}
