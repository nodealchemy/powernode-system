package handlers

import (
	"context"
	"errors"
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/runtime/tasks"
)

// fakeHTTP is a minimal tasks.HTTPClient stub for exercising
// ModuleBuildHandler.Execute without a live mTLS connection.
type fakeHTTP struct {
	status int
	body   string
	err    error
	calls  []string
}

func (f *fakeHTTP) GetJSON(path string) (*http.Response, error) {
	f.calls = append(f.calls, path)
	if f.err != nil {
		return nil, f.err
	}
	status := f.status
	if status == 0 {
		status = http.StatusOK
	}
	return &http.Response{StatusCode: status, Body: io.NopCloser(strings.NewReader(f.body))}, nil
}

func (f *fakeHTTP) PostJSON(_ string, _ []byte) (*http.Response, error) {
	return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(strings.NewReader(`{"success":true}`))}, nil
}

// fakeExec is a minimal Execer stub that records the env it was invoked
// with and returns canned stdout/stderr/err.
type fakeExec struct {
	gotName string
	gotEnv  []string
	calls   int
	stdout  []byte
	stderr  []byte
	err     error
}

func (f *fakeExec) Run(_ context.Context, name string, env []string) ([]byte, []byte, error) {
	f.calls++
	f.gotName = name
	f.gotEnv = append([]string(nil), env...)
	return f.stdout, f.stderr, f.err
}

func envMap(env []string) map[string]string {
	m := make(map[string]string, len(env))
	for _, kv := range env {
		parts := strings.SplitN(kv, "=", 2)
		if len(parts) == 2 {
			m[parts[0]] = parts[1]
		}
	}
	return m
}

const okContextBody = `{"success":true,"data":{
	"source_repo_url":"https://git.powernode.net/powernode/powernode-system.git",
	"source_token":"SRC-TOKEN",
	"oras_registry":"registry.example.com",
	"oras_user":"oras-user",
	"oras_password":"ORAS-PW"
}}`

func TestParseModuleBuildOptions(t *testing.T) {
	task := &tasks.Task{Options: map[string]any{"module": "runtime-ruby", "sha": "abc123", "oci_ref": "v1"}}
	opts, err := parseModuleBuildOptions(task)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if opts.Module != "runtime-ruby" || opts.SHA != "abc123" || opts.OCIRef != "v1" {
		t.Fatalf("parsed: %+v", opts)
	}

	missing := []map[string]any{
		{"sha": "abc123", "oci_ref": "v1"},          // no module
		{"module": "runtime-ruby", "oci_ref": "v1"}, // no sha
		{"module": "runtime-ruby", "sha": "abc123"}, // no oci_ref
		{},
	}
	for i, o := range missing {
		if _, err := parseModuleBuildOptions(&tasks.Task{Options: o}); err == nil {
			t.Fatalf("case %d: expected validation error for %v", i, o)
		}
	}
}

func TestBuildEnv(t *testing.T) {
	opts := moduleBuildOptions{Module: "runtime-ruby", SHA: "sha123", OCIRef: "v2"}
	bctx := &ciBuildContext{
		OrasRegistry: "reg.example.com",
		OrasUser:     "u",
		OrasPassword: "p",
	}
	env := envMap(buildEnv(opts, "https://x-access-token:tok@host/o/r.git", bctx))

	want := map[string]string{
		"MODULE":                 "runtime-ruby",
		"BUILD_SHA":              "sha123",
		"OCI_REF":                "v2",
		"MODULE_SOURCE_URL":      "https://x-access-token:tok@host/o/r.git",
		"ORAS_REGISTRY":          "reg.example.com",
		"ORAS_REGISTRY_USER":     "u",
		"ORAS_REGISTRY_PASSWORD": "p",
	}
	for k, v := range want {
		if env[k] != v {
			t.Errorf("env[%s] = %q, want %q", k, env[k], v)
		}
	}
	if _, ok := env["PARENT_PAT"]; ok {
		t.Errorf("PARENT_PAT should be absent when ParentPAT is empty, got env=%v", env)
	}
	if _, ok := env["APT_SNAPSHOT"]; ok {
		t.Errorf("APT_SNAPSHOT should be absent when AptSnapshot is empty, got env=%v", env)
	}
	// PRESENT-BUT-EMPTY, deliberately — the opposite of PARENT_PAT above.
	// buildEnv's slice is appended to os.Environ() (execRunner.Run), so
	// OMITTING CORE_REF would let an ambient one (a unit-file Environment=, an
	// operator's systemd-run --setenv) survive into the build and pin it to a
	// commit the platform never chose, while stage15.sh logged "parent
	// PINNED". Emitting it empty keeps the platform authoritative in the
	// no-pin state too.
	if v, ok := env["CORE_REF"]; !ok || v != "" {
		t.Errorf("CORE_REF must be PRESENT and EMPTY when CoreRef is empty (ok=%v v=%q) — "+
			"omitting it cannot clear an ambient value", ok, v)
	}

	// Class-B + snapshot override + a pinned core ref -> all three set.
	bctx.ParentPAT = "PARENT-TOK"
	bctx.AptSnapshot = "20260101T000000Z"
	bctx.CoreRef = "0f4b6e1db4c2a9f1e8d70c3b5a6f2e1d9c8b7a60"
	env = envMap(buildEnv(opts, "url", bctx))
	if env["PARENT_PAT"] != "PARENT-TOK" {
		t.Errorf("PARENT_PAT = %q, want PARENT-TOK", env["PARENT_PAT"])
	}
	if env["APT_SNAPSHOT"] != "20260101T000000Z" {
		t.Errorf("APT_SNAPSHOT = %q, want 20260101T000000Z", env["APT_SNAPSHOT"])
	}
	if env["CORE_REF"] != "0f4b6e1db4c2a9f1e8d70c3b5a6f2e1d9c8b7a60" {
		t.Errorf("CORE_REF = %q, want the pinned core sha", env["CORE_REF"])
	}
}

// The whole reason the agent had to be rebuilt for the core-ref pin:
// encoding/json decodes ci_build_context into a FIXED struct, so a field the
// platform sends with no matching struct field is dropped with no error. A
// `core_ref` that decoded to "" would leave every Class-B build silently
// unpinned while the platform's logs said it was pinned.
//
// Drives the REAL fetchBuildContext -> buildEnv path rather than a hand-copied
// envelope struct, so it guards the decode as well as the struct tag.
func TestFetchBuildContextDecodesCoreRefIntoEnv(t *testing.T) {
	const sha = "0f4b6e1db00c0ffee0000000000000000deadbeef"
	client := &fakeHTTP{body: `{"success":true,"data":{"source_repo_url":"https://host/o/r.git",` +
		`"source_token":"tok","parent_pat":"ppat","oras_registry":"reg",` +
		`"oras_user":"u","oras_password":"p","core_ref":"` + sha + `"}}`}

	bctx, err := fetchBuildContext(client, "powernode-hub-backend")
	if err != nil {
		t.Fatalf("fetchBuildContext: %v", err)
	}
	if bctx.CoreRef != sha {
		t.Fatalf("CoreRef = %q, want %q — the core_ref JSON key is not bound to a struct field, "+
			"so the pin would be dropped silently", bctx.CoreRef, sha)
	}

	env := envMap(buildEnv(moduleBuildOptions{Module: "powernode-hub-backend", SHA: "s", OCIRef: "t"},
		"url", bctx))
	if env["CORE_REF"] != sha {
		t.Fatalf("CORE_REF = %q, want %q — decoded but never placed in the build env", env["CORE_REF"], sha)
	}
}

func TestEmbedCredential(t *testing.T) {
	got, err := embedCredential("https://git.powernode.net/powernode/powernode-system.git", "TOK")
	if err != nil {
		t.Fatal(err)
	}
	want := "https://x-access-token:TOK@git.powernode.net/powernode/powernode-system.git"
	if got != want {
		t.Fatalf("got %q, want %q", got, want)
	}

	// Empty token: URL passed through unchanged.
	bare, err := embedCredential("https://host/o/r.git", "")
	if err != nil {
		t.Fatal(err)
	}
	if bare != "https://host/o/r.git" {
		t.Fatalf("bare url mutated: %q", bare)
	}

	// Unparseable URL surfaces an error.
	if _, err := embedCredential("://not a url", "TOK"); err == nil {
		t.Fatal("expected parse error for malformed URL")
	}
}

func TestParseBuildResult(t *testing.T) {
	stdout := []byte("cloning...\nbuilding...\n{\"oci_digest\":\"sha256:abc\",\"fsverity_root\":\"deadbeef\",\"size\":12345,\"built_from_sha\":\"sha123\"}\n")
	r, err := parseBuildResult(stdout)
	if err != nil {
		t.Fatal(err)
	}
	if r.OCIDigest != "sha256:abc" || r.FsverityRoot != "deadbeef" || r.BuiltFromSHA != "sha123" {
		t.Fatalf("parsed: %+v", r)
	}
	if n, err := r.Size.Int64(); err != nil || n != 12345 {
		t.Fatalf("size: %v (err %v)", r.Size, err)
	}

	// Trailing blank lines are skipped when finding the last real line.
	trailing := []byte("{\"oci_digest\":\"d\",\"fsverity_root\":\"f\",\"size\":1,\"built_from_sha\":\"s\"}\n\n\n")
	if _, err := parseBuildResult(trailing); err != nil {
		t.Fatalf("trailing blank lines: %v", err)
	}

	if _, err := parseBuildResult([]byte("")); err == nil {
		t.Fatal("expected error for empty stdout")
	}
	if _, err := parseBuildResult([]byte("not json\n")); err == nil {
		t.Fatal("expected error for non-JSON last line")
	}
}

func TestModuleBuildHandler_Execute_Success(t *testing.T) {
	httpc := &fakeHTTP{body: okContextBody}
	exec := &fakeExec{stdout: []byte(`{"oci_digest":"sha256:aaa","fsverity_root":"root1","size":2048,"built_from_sha":"deadsha"}`)}
	h := &ModuleBuildHandler{HTTP: httpc, Exec: exec}

	task := &tasks.Task{ID: "t1", Command: "ci.module_build", Options: map[string]any{
		"module": "runtime-ruby", "sha": "deadsha", "oci_ref": "v1.2.3",
	}}

	result, err := h.Execute(context.Background(), task)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if result["oci_digest"] != "sha256:aaa" || result["fsverity_root"] != "root1" || result["built_from_sha"] != "deadsha" {
		t.Fatalf("result: %+v", result)
	}
	if result["size"] != int64(2048) {
		t.Fatalf("size = %v (%T), want int64(2048)", result["size"], result["size"])
	}
	if _, ok := result["log_tail"]; !ok {
		t.Fatal("expected log_tail in result")
	}

	if len(httpc.calls) != 1 || httpc.calls[0] != "/api/v1/system/node_api/config/ci_build_context?module=runtime-ruby" {
		t.Fatalf("unexpected GET calls: %v", httpc.calls)
	}

	env := envMap(exec.gotEnv)
	if env["MODULE"] != "runtime-ruby" || env["BUILD_SHA"] != "deadsha" || env["OCI_REF"] != "v1.2.3" {
		t.Fatalf("env: %+v", env)
	}
	if env["MODULE_SOURCE_URL"] != "https://x-access-token:SRC-TOKEN@git.powernode.net/powernode/powernode-system.git" {
		t.Fatalf("MODULE_SOURCE_URL = %q", env["MODULE_SOURCE_URL"])
	}
	if env["ORAS_REGISTRY"] != "registry.example.com" || env["ORAS_REGISTRY_USER"] != "oras-user" || env["ORAS_REGISTRY_PASSWORD"] != "ORAS-PW" {
		t.Fatalf("oras env: %+v", env)
	}
	if _, ok := env["PARENT_PAT"]; ok {
		t.Fatalf("Class-A module must NOT receive PARENT_PAT: %+v", env)
	}
	if exec.gotName != moduleForgeBuildScript {
		t.Fatalf("exec name = %q, want %q", exec.gotName, moduleForgeBuildScript)
	}
}

func TestModuleBuildHandler_Execute_ClassBGetsParentPAT(t *testing.T) {
	httpc := &fakeHTTP{body: `{"success":true,"data":{
		"source_repo_url":"https://git.powernode.net/powernode/powernode-system.git",
		"source_token":"SRC-TOKEN",
		"parent_pat":"PARENT-TOKEN",
		"oras_registry":"registry.example.com",
		"oras_user":"oras-user",
		"oras_password":"ORAS-PW"
	}}`}
	exec := &fakeExec{stdout: []byte(`{"oci_digest":"sha256:bbb","fsverity_root":"root2","size":99,"built_from_sha":"sha2"}`)}
	h := &ModuleBuildHandler{HTTP: httpc, Exec: exec}

	task := &tasks.Task{Options: map[string]any{
		"module": "powernode-hub-backend", "sha": "sha2", "oci_ref": "v9",
	}}

	if _, err := h.Execute(context.Background(), task); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	env := envMap(exec.gotEnv)
	if env["PARENT_PAT"] != "PARENT-TOKEN" {
		t.Fatalf("Class-B module must receive PARENT_PAT, env: %+v", env)
	}
}

func TestModuleBuildHandler_Execute_MissingOptions(t *testing.T) {
	httpc := &fakeHTTP{body: okContextBody}
	exec := &fakeExec{}
	h := &ModuleBuildHandler{HTTP: httpc, Exec: exec}

	_, err := h.Execute(context.Background(), &tasks.Task{Options: map[string]any{"module": "runtime-ruby"}})
	if err == nil {
		t.Fatal("expected error for missing sha/oci_ref")
	}
	if len(httpc.calls) != 0 {
		t.Fatalf("HTTP must not be called before options validate, calls: %v", httpc.calls)
	}
	if exec.calls != 0 {
		t.Fatalf("Exec must not be called before options validate, calls: %d", exec.calls)
	}
}

func TestModuleBuildHandler_Execute_ContextFetchForbidden(t *testing.T) {
	httpc := &fakeHTTP{status: http.StatusForbidden, body: `{"success":false,"error":"Instance has no active module_build lease"}`}
	exec := &fakeExec{}
	h := &ModuleBuildHandler{HTTP: httpc, Exec: exec}

	task := &tasks.Task{Options: map[string]any{"module": "runtime-ruby", "sha": "s", "oci_ref": "v1"}}
	_, err := h.Execute(context.Background(), task)
	if err == nil {
		t.Fatal("expected error when ci_build_context is forbidden")
	}
	if exec.calls != 0 {
		t.Fatalf("build script must NOT run when the build-context fetch fails, calls: %d", exec.calls)
	}
}

func TestModuleBuildHandler_Execute_ExecFailure(t *testing.T) {
	httpc := &fakeHTTP{body: okContextBody}
	exec := &fakeExec{
		stderr: []byte("mmdebstrap: E: something exploded"),
		err:    errors.New("exit status 1"),
	}
	h := &ModuleBuildHandler{HTTP: httpc, Exec: exec}

	task := &tasks.Task{Options: map[string]any{"module": "runtime-ruby", "sha": "s", "oci_ref": "v1"}}
	_, err := h.Execute(context.Background(), task)
	if err == nil {
		t.Fatal("expected error when the build script exits non-zero")
	}
	if !strings.Contains(err.Error(), "something exploded") {
		t.Fatalf("error should carry the stderr log tail, got: %v", err)
	}
}

func TestModuleBuildHandler_Execute_BadResultJSON(t *testing.T) {
	httpc := &fakeHTTP{body: okContextBody}
	exec := &fakeExec{stdout: []byte("build finished but forgot to print JSON\n")}
	h := &ModuleBuildHandler{HTTP: httpc, Exec: exec}

	task := &tasks.Task{Options: map[string]any{"module": "runtime-ruby", "sha": "s", "oci_ref": "v1"}}
	_, err := h.Execute(context.Background(), task)
	if err == nil {
		t.Fatal("expected error when stdout's last line isn't valid result JSON")
	}
}

func TestModuleBuildHandler_Execute_NoTransport(t *testing.T) {
	h := &ModuleBuildHandler{Exec: &fakeExec{}}
	task := &tasks.Task{Options: map[string]any{"module": "runtime-ruby", "sha": "s", "oci_ref": "v1"}}
	if _, err := h.Execute(context.Background(), task); err == nil {
		t.Fatal("expected error when HTTP transport is nil")
	}
}
