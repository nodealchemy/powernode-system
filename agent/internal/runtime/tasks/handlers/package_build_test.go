package handlers

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/runtime/tasks"
)

// fakeHTTP, fakeExec, envMap, and okContextBody are all defined in
// module_build_test.go (same package) — reused verbatim rather than
// forked, since PackageBuildHandler shares ModuleBuildHandler's HTTP/Exec
// contracts exactly (see package_build.go's doc).

func validPackageOptions() map[string]any {
	return map[string]any{
		"module":            "libssl3-pkg",
		"sha":               "20260101T000000Z",
		"oci_ref":           "abc1234",
		"batch_id":          "019f6084-batch",
		"build_kind":        "package",
		"package_name":      "libssl3",
		"architecture":      "amd64",
		"package_repo_kind": "apt",
		"package_repo_url":  "http://archive.ubuntu.com/ubuntu",
		"apt_suite":         "noble",
		"apt_components":    "main,universe",
		"apt_snapshot":      "20260101T000000Z",
		"gpg_key_armor":     "-----BEGIN PGP PUBLIC KEY BLOCK-----\n...\n-----END PGP PUBLIC KEY BLOCK-----",
		"mask":              "/usr/share/doc/**\n/usr/share/man/**",
		"file_spec_source":  "package_query",
	}
}

func TestParsePackageBuildOptions(t *testing.T) {
	opts, err := parsePackageBuildOptions(&tasks.Task{Options: validPackageOptions()})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if opts.Module != "libssl3-pkg" || opts.PackageName != "libssl3" || opts.OCIRef != "abc1234" {
		t.Fatalf("parsed: %+v", opts)
	}
	if opts.RepoKind != "apt" || opts.AptSuite != "noble" || opts.AptComponents != "main,universe" {
		t.Fatalf("parsed repo fields: %+v", opts)
	}

	required := []string{"module", "oci_ref", "package_name", "architecture", "package_repo_url"}
	for _, key := range required {
		o := validPackageOptions()
		delete(o, key)
		if _, err := parsePackageBuildOptions(&tasks.Task{Options: o}); err == nil {
			t.Fatalf("missing %q: expected validation error", key)
		}
	}

	// apt-conditional requirements.
	for _, key := range []string{"apt_suite", "apt_components"} {
		o := validPackageOptions()
		delete(o, key)
		if _, err := parsePackageBuildOptions(&tasks.Task{Options: o}); err == nil {
			t.Fatalf("missing %q (apt repo): expected validation error", key)
		}
	}

	// rpm/dnf: apt_suite/apt_components not required, rpm_releasever is.
	rpmOpts := validPackageOptions()
	delete(rpmOpts, "apt_suite")
	delete(rpmOpts, "apt_components")
	rpmOpts["package_repo_kind"] = "rpm"
	if _, err := parsePackageBuildOptions(&tasks.Task{Options: rpmOpts}); err == nil {
		t.Fatal("rpm repo missing rpm_releasever: expected validation error")
	}
	rpmOpts["rpm_releasever"] = "9"
	parsed, err := parsePackageBuildOptions(&tasks.Task{Options: rpmOpts})
	if err != nil {
		t.Fatalf("rpm repo with releasever: unexpected error: %v", err)
	}
	if parsed.RPMReleasever != "9" {
		t.Fatalf("RPMReleasever = %q, want 9", parsed.RPMReleasever)
	}

	// unknown repo kind.
	badKind := validPackageOptions()
	badKind["package_repo_kind"] = "homebrew"
	if _, err := parsePackageBuildOptions(&tasks.Task{Options: badKind}); err == nil {
		t.Fatal("unknown package_repo_kind: expected validation error")
	}

	// missing repo kind entirely.
	noKind := validPackageOptions()
	delete(noKind, "package_repo_kind")
	if _, err := parsePackageBuildOptions(&tasks.Task{Options: noKind}); err == nil {
		t.Fatal("missing package_repo_kind: expected validation error")
	}
}

func TestBuildPackageEnv(t *testing.T) {
	opts, err := parsePackageBuildOptions(&tasks.Task{Options: validPackageOptions()})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	bctx := &ciBuildContext{OrasRegistry: "reg.example.com", OrasUser: "u", OrasPassword: "p"}
	env := envMap(buildPackageEnv(opts, bctx))

	want := map[string]string{
		"MODULE":                 "libssl3-pkg",
		"SHA":                    "20260101T000000Z",
		"OCI_REF":                "abc1234",
		"PACKAGE_NAME":           "libssl3",
		"ARCHITECTURE":           "amd64",
		"REPO_KIND":              "apt",
		"REPO_URL":               "http://archive.ubuntu.com/ubuntu",
		"APT_SUITE":              "noble",
		"APT_COMPONENTS":         "main,universe",
		"ORAS_REGISTRY":          "reg.example.com",
		"ORAS_REGISTRY_USER":     "u",
		"ORAS_REGISTRY_PASSWORD": "p",
		"BATCH_ID":               "019f6084-batch",
		"APT_SNAPSHOT":           "20260101T000000Z",
		"MASK":                   "/usr/share/doc/**\n/usr/share/man/**",
		"FILE_SPEC_SOURCE":       "package_query",
	}
	for k, v := range want {
		if env[k] != v {
			t.Errorf("env[%s] = %q, want %q", k, env[k], v)
		}
	}
	if _, ok := env["GPG_KEY_ARMOR"]; !ok {
		t.Error("GPG_KEY_ARMOR should be present when gpg_key_armor is set")
	}
	if _, ok := env["RPM_RELEASEVER"]; ok {
		t.Errorf("RPM_RELEASEVER should be absent for an apt repo, got env=%v", env)
	}

	// Optional keys omitted when blank.
	minimal := map[string]any{
		"module": "m", "oci_ref": "t", "package_name": "p", "architecture": "amd64",
		"package_repo_url": "http://x", "package_repo_kind": "apt",
		"apt_suite": "noble", "apt_components": "main",
	}
	minOpts, err := parsePackageBuildOptions(&tasks.Task{Options: minimal})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	minEnv := envMap(buildPackageEnv(minOpts, &ciBuildContext{}))
	for _, key := range []string{"BATCH_ID", "APT_SNAPSHOT", "GPG_KEY_ARMOR", "MASK", "FILE_SPEC_SOURCE", "RPM_RELEASEVER"} {
		if _, ok := minEnv[key]; ok {
			t.Errorf("%s should be absent when unset, got env=%v", key, minEnv)
		}
	}
}

func TestParsePackageBuildResult(t *testing.T) {
	stdout := []byte("bootstrapping...\ncarving...\n" +
		`{"oci_digest":"sha256:abc","fsverity_root":"deadbeef","size":54321,"built_from_sha":"20260101T000000Z","file_spec":["/usr/lib/libssl.so.3","/usr/bin/openssl"]}` + "\n")
	r, err := parsePackageBuildResult(stdout)
	if err != nil {
		t.Fatal(err)
	}
	if r.OCIDigest != "sha256:abc" || r.FsverityRoot != "deadbeef" || r.BuiltFromSHA != "20260101T000000Z" {
		t.Fatalf("parsed: %+v", r)
	}
	if len(r.FileSpec) != 2 || r.FileSpec[0] != "/usr/lib/libssl.so.3" {
		t.Fatalf("file_spec: %+v", r.FileSpec)
	}
	if n, err := r.Size.Int64(); err != nil || n != 54321 {
		t.Fatalf("size: %v (err %v)", r.Size, err)
	}

	if _, err := parsePackageBuildResult([]byte("")); err == nil {
		t.Fatal("expected error for empty stdout")
	}
	if _, err := parsePackageBuildResult([]byte("not json\n")); err == nil {
		t.Fatal("expected error for non-JSON last line")
	}
}

func TestPackageBuildHandler_Execute_Success(t *testing.T) {
	httpc := &fakeHTTP{body: okContextBody}
	exec := &fakeExec{stdout: []byte(`{"oci_digest":"sha256:pkg1","fsverity_root":"root9","size":4096,"built_from_sha":"20260101T000000Z","file_spec":["/usr/lib/libssl.so.3","/usr/bin/openssl"]}`)}
	h := &PackageBuildHandler{HTTP: httpc, Exec: exec}

	task := &tasks.Task{ID: "t-pkg1", Command: "ci.package_build", Options: validPackageOptions()}

	result, err := h.Execute(context.Background(), task)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if result["oci_digest"] != "sha256:pkg1" || result["fsverity_root"] != "root9" || result["built_from_sha"] != "20260101T000000Z" {
		t.Fatalf("result: %+v", result)
	}
	if result["size"] != int64(4096) {
		t.Fatalf("size = %v (%T), want int64(4096)", result["size"], result["size"])
	}
	spec, ok := result["file_spec"].([]string)
	if !ok || len(spec) != 2 {
		t.Fatalf("file_spec: %+v", result["file_spec"])
	}
	if _, ok := result["log_tail"]; !ok {
		t.Fatal("expected log_tail in result")
	}

	if len(httpc.calls) != 1 || httpc.calls[0] != "/api/v1/system/node_api/config/ci_build_context?module=libssl3-pkg" {
		t.Fatalf("unexpected GET calls (should reuse the SAME ci_build_context endpoint module_build uses): %v", httpc.calls)
	}

	env := envMap(exec.gotEnv)
	if env["MODULE"] != "libssl3-pkg" || env["PACKAGE_NAME"] != "libssl3" || env["OCI_REF"] != "abc1234" {
		t.Fatalf("env: %+v", env)
	}
	if env["ORAS_REGISTRY"] != "registry.example.com" || env["ORAS_REGISTRY_USER"] != "oras-user" || env["ORAS_REGISTRY_PASSWORD"] != "ORAS-PW" {
		t.Fatalf("oras env should come from the SAME ci_build_context fetch as module_build: %+v", env)
	}
	if exec.gotName != moduleForgePackageBuildScript {
		t.Fatalf("exec name = %q, want %q", exec.gotName, moduleForgePackageBuildScript)
	}
}

func TestPackageBuildHandler_Execute_MissingOptions(t *testing.T) {
	httpc := &fakeHTTP{body: okContextBody}
	exec := &fakeExec{}
	h := &PackageBuildHandler{HTTP: httpc, Exec: exec}

	o := validPackageOptions()
	delete(o, "package_name")
	_, err := h.Execute(context.Background(), &tasks.Task{Options: o})
	if err == nil {
		t.Fatal("expected error for missing package_name")
	}
	if len(httpc.calls) != 0 {
		t.Fatalf("HTTP must not be called before options validate, calls: %v", httpc.calls)
	}
	if exec.calls != 0 {
		t.Fatalf("Exec must not be called before options validate, calls: %d", exec.calls)
	}
}

func TestPackageBuildHandler_Execute_RPMNotSupported(t *testing.T) {
	httpc := &fakeHTTP{body: okContextBody}
	exec := &fakeExec{}
	h := &PackageBuildHandler{HTTP: httpc, Exec: exec}

	o := validPackageOptions()
	delete(o, "apt_suite")
	delete(o, "apt_components")
	o["package_repo_kind"] = "rpm"
	o["rpm_releasever"] = "9"

	_, err := h.Execute(context.Background(), &tasks.Task{Options: o})
	if err == nil {
		t.Fatal("expected a clean 'not supported' error for rpm — never a panic, never a partial build attempt")
	}
	if !strings.Contains(err.Error(), "not yet supported") {
		t.Fatalf("error should explain the rpm/dnf parked status, got: %v", err)
	}
	// Must fail BEFORE ever fetching build context or invoking the script —
	// there is nothing module-forge-package-build.sh (apt-only) could do
	// with an rpm recipe.
	if len(httpc.calls) != 0 {
		t.Fatalf("HTTP must not be called for an unsupported repo kind, calls: %v", httpc.calls)
	}
	if exec.calls != 0 {
		t.Fatalf("Exec must not be called for an unsupported repo kind, calls: %d", exec.calls)
	}
}

func TestPackageBuildHandler_Execute_ContextFetchForbidden(t *testing.T) {
	httpc := &fakeHTTP{status: http.StatusForbidden, body: `{"success":false,"error":"Instance has no active module_build lease"}`}
	exec := &fakeExec{}
	h := &PackageBuildHandler{HTTP: httpc, Exec: exec}

	_, err := h.Execute(context.Background(), &tasks.Task{Options: validPackageOptions()})
	if err == nil {
		t.Fatal("expected error when ci_build_context is forbidden")
	}
	if exec.calls != 0 {
		t.Fatalf("build script must NOT run when the build-context fetch fails, calls: %d", exec.calls)
	}
}

func TestPackageBuildHandler_Execute_ExecFailure(t *testing.T) {
	httpc := &fakeHTTP{body: okContextBody}
	exec := &fakeExec{
		stderr: []byte("mmdebstrap: E: unable to resolve package libssl3"),
		err:    errors.New("exit status 1"),
	}
	h := &PackageBuildHandler{HTTP: httpc, Exec: exec}

	_, err := h.Execute(context.Background(), &tasks.Task{Options: validPackageOptions()})
	if err == nil {
		t.Fatal("expected error when the build script exits non-zero")
	}
	if !strings.Contains(err.Error(), "unable to resolve package") {
		t.Fatalf("error should carry the stderr log tail, got: %v", err)
	}
}

func TestPackageBuildHandler_Execute_BadResultJSON(t *testing.T) {
	httpc := &fakeHTTP{body: okContextBody}
	exec := &fakeExec{stdout: []byte("build finished but forgot to print JSON\n")}
	h := &PackageBuildHandler{HTTP: httpc, Exec: exec}

	_, err := h.Execute(context.Background(), &tasks.Task{Options: validPackageOptions()})
	if err == nil {
		t.Fatal("expected error when stdout's last line isn't valid result JSON")
	}
}

func TestPackageBuildHandler_Execute_NoTransport(t *testing.T) {
	h := &PackageBuildHandler{Exec: &fakeExec{}}
	_, err := h.Execute(context.Background(), &tasks.Task{Options: validPackageOptions()})
	if err == nil {
		t.Fatal("expected error when HTTP transport is nil")
	}
}
