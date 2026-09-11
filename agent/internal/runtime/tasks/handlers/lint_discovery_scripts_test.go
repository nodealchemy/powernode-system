package handlers

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// These run the REAL module-forge scripts against stub toolchains in a temp
// directory. Nothing here touches /persist or the network.

var (
	fmtSscan = fmt.Sscan
	errorsAs = errors.As
)

func moduleForgeScript(t *testing.T, name string) string {
	t.Helper()
	p, err := filepath.Abs(filepath.Join("..", "..", "..", "..", "..", "modules", "module-forge", "rootfs", "usr", "local", "bin", name))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(p); err != nil {
		t.Fatalf("script %s: %v", name, err)
	}
	return p
}

func needTools(t *testing.T, tools ...string) {
	t.Helper()
	for _, tool := range tools {
		if _, err := exec.LookPath(tool); err != nil {
			t.Skipf("%s not on PATH", tool)
		}
	}
}

// scriptRig is one repository's workdir plus a directory of stub programs
// that stand in for the toolchains.
type scriptRig struct {
	workdir string
	src     string
	stubs   string
	// The output limit the handler would pass; 0 passes none.
	limit int64
	// The per-step bound the handler would pass.
	step time.Duration
}

func newScriptRig(t *testing.T) *scriptRig {
	t.Helper()
	root := t.TempDir()
	r := &scriptRig{workdir: filepath.Join(root, "lint-discovery-x"), stubs: filepath.Join(root, "stubs"),
		limit: testOutputLimit, step: time.Minute}
	r.src = filepath.Join(r.workdir, lintCloneDir)
	for _, d := range []string{r.src, r.stubs} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if strings.HasPrefix(r.workdir, "/persist") {
		t.Fatalf("rig must not live under /persist: %s", r.workdir)
	}
	return r
}

func (r *scriptRig) file(t *testing.T, rel, body string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(r.src, rel), []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func (r *scriptRig) stub(t *testing.T, name, body string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(r.stubs, name), []byte("#!/bin/sh\n"+body), 0o755); err != nil {
		t.Fatal(err)
	}
}

// env is the lint phase's environment as the handler builds it, or the base
// environment alone when the rig passes no limit.
func (r *scriptRig) env() []string {
	if r.limit == 0 {
		return lintBaseEnv(r.workdir)
	}
	return lintPhaseEnv(r.workdir, r.limit, r.step)
}

// linkTools puts the named host programs, and nothing else, beside the stubs,
// for a run whose PATH is the stubs directory alone.
func linkTools(t *testing.T, r *scriptRig, tools ...string) {
	t.Helper()
	for _, tool := range tools {
		p, err := exec.LookPath(tool)
		if err != nil {
			t.Skipf("%s not on PATH", tool)
		}
		if err := os.Symlink(p, filepath.Join(r.stubs, tool)); err != nil {
			t.Fatal(err)
		}
	}
}

// run executes lint-discovery.sh exactly as the handler would: no arguments,
// the handler's lint-phase environment, the stubs first on PATH.
func (r *scriptRig) run(t *testing.T, extra ...string) (stdout, stderr []byte, err error) {
	t.Helper()
	env := r.env()
	for i, kv := range env {
		if strings.HasPrefix(kv, "PATH=") {
			env[i] = "PATH=" + r.stubs + ":/usr/bin:/bin"
		}
	}
	cmd := exec.Command("bash", moduleForgeScript(t, "lint-discovery.sh"))
	cmd.Env = append(env, extra...)
	cmd.Dir = r.workdir
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	err = cmd.Run()
	return out.Bytes(), errb.Bytes(), err
}

// A linter that prints `size` bytes of output: large output must travel
// through files and stdin, never one exec argument (Linux caps one at 128 KiB).
func bigOutputStub(size int, exitStatus int) string {
	return fmt.Sprintf("head -c %d /dev/zero | tr '\\0' 'a'\nexit %d\n", size, exitStatus)
}

func TestLintScript_RunsTheRepositorysOwnLintersOverLargeOutput(t *testing.T) {
	needTools(t, "bash", "jq", "head", "tr", "timeout")
	r := newScriptRig(t)
	r.file(t, "Gemfile", "source 'https://rubygems.org'\n")
	r.file(t, "package.json", "{}\n")
	r.file(t, ".eslintrc.json", "{}\n") // ESLint configured, no tsconfig.json
	const rubySize, eslintSize = 200 << 10, 300 << 10
	r.stub(t, "bundle", `case "$1" in install) exit 0 ;; exec) shift; [ "$1" = rubocop ] || exit 9; `+bigOutputStub(rubySize, 1)+` ;; esac`+"\nexit 9\n")
	r.stub(t, "npm", `[ "$1" = ci ] && exit 0`+"\nexit 9\n")
	r.stub(t, "ruby", "exit 0\n")
	r.stub(t, "node", "exit 0\n")
	r.stub(t, "npx", `for a in "$@"; do [ "$a" = eslint ] && { `+strings.ReplaceAll(bigOutputStub(eslintSize, 1), "\n", "; ")+` }; done`+"\nexit 9\n")

	stdout, stderr, err := r.run(t)
	if err != nil {
		t.Fatalf("script failed: %v\nstderr: %s", err, stderr)
	}
	res, err := parseLintScriptResult(stdout)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	ruby, js := res.Linters["ruby"], res.Linters["javascript_lint"]
	if ruby.Status != "ran" || ruby.ExitStatus == nil || *ruby.ExitStatus != 1 || ruby.Output != strings.Repeat("a", rubySize) {
		t.Fatalf("ruby: status %q exit %v output %d bytes", ruby.Status, ruby.ExitStatus, len(ruby.Output))
	}
	if js.Status != "ran" || len(js.Output) != eslintSize {
		t.Fatalf("an .eslintrc-only repository must run ESLint: status %q output %d bytes", js.Status, len(js.Output))
	}
	if _, ok := res.Linters["typescript"]; ok {
		t.Fatal("no tsconfig.json, so TypeScript must not be reported at all")
	}
	// Caches and the bundle stay inside the workdir.
	if _, err := os.Stat(filepath.Join(r.workdir, "home")); err != nil {
		t.Fatalf("HOME was not created inside the workdir: %v", err)
	}
}

// D1 re-verify M2: a cut report parses as a parse error, or for tsc as a
// complete one with only its first errors. So output over the limit is never
// sent: the linter is reported output_truncated. Output at the limit is sent
// whole.
func TestLintScript_ReportsOutputOverTheLimitAsTruncated(t *testing.T) {
	needTools(t, "bash", "jq", "head", "tr", "timeout", "wc")
	const limit = 64 << 10
	for name, tc := range map[string]struct {
		size       int
		wantStatus string
		wantOutput int
	}{
		"at the limit":   {size: limit, wantStatus: "ran", wantOutput: limit},
		"over the limit": {size: limit + 1, wantStatus: "output_truncated", wantOutput: 0},
	} {
		t.Run(name, func(t *testing.T) {
			r := newScriptRig(t)
			r.limit = limit
			r.file(t, "Gemfile", "\n")
			r.stub(t, "ruby", "exit 0\n")
			r.stub(t, "bundle", `case "$1" in install) exit 0 ;; exec) `+bigOutputStub(tc.size, 1)+` ;; esac`+"\n")

			stdout, stderr, err := r.run(t)
			if err != nil {
				t.Fatalf("script failed: %v\nstderr: %s", err, stderr)
			}
			res, err := parseLintScriptResult(stdout)
			if err != nil {
				t.Fatal(err)
			}
			ruby := res.Linters["ruby"]
			if ruby.Status != tc.wantStatus || len(ruby.Output) != tc.wantOutput {
				t.Fatalf("status %q with %d bytes of output, want %q with %d", ruby.Status, len(ruby.Output),
					tc.wantStatus, tc.wantOutput)
			}
		})
	}
}

func TestLintScript_RefusesToRunWithoutAnOutputLimit(t *testing.T) {
	needTools(t, "bash")
	for name, limit := range map[string]string{"absent": "", "zero": "LINT_MAX_OUTPUT_BYTES=0",
		"not a number": "LINT_MAX_OUTPUT_BYTES=16M"} {
		t.Run(name, func(t *testing.T) {
			r := newScriptRig(t)
			r.limit = 0
			r.file(t, "Gemfile", "\n")
			r.stub(t, "ruby", "exit 0\n")
			r.stub(t, "bundle", "touch \"$WORKDIR/ran\"\nexit 0\n")

			var extra []string
			if limit != "" {
				extra = append(extra, limit)
			}
			stdout, _, err := r.run(t, extra...)
			var exitErr *exec.ExitError
			if !errorsAs(err, &exitErr) || exitErr.ExitCode() != 64 {
				t.Fatalf("expected exit 64, got %v", err)
			}
			if len(stdout) != 0 {
				t.Fatalf("stdout must stay empty: %q", stdout)
			}
			if _, err := os.Stat(filepath.Join(r.workdir, "ran")); err == nil {
				t.Fatal("repository tooling ran without an output limit")
			}
		})
	}
}

func TestLintScript_ReportsWhatItCouldNotMeasure(t *testing.T) {
	needTools(t, "bash", "jq", "timeout")
	cases := map[string]struct {
		npm  string
		step time.Duration
		want string
	}{
		"install failed":    {npm: "exit 1\n", want: "install_failed"},
		"install timed out": {npm: "sleep 5\n", step: time.Second, want: "timeout"},
		"no toolchain":      {want: "missing_node"},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			r := newScriptRig(t)
			if tc.step > 0 {
				r.step = tc.step
			}
			r.file(t, "package.json", "{}\n")
			r.file(t, "tsconfig.json", "{}\n")
			r.file(t, ".eslintrc.js", "module.exports = {}\n")
			if tc.npm != "" {
				r.stub(t, "node", "exit 0\n")
				r.stub(t, "npm", tc.npm)
			} else {
				// Hide every node on the host: PATH is the stubs directory
				// only, plus the handful of programs the script itself needs.
				linkTools(t, r, "jq", "timeout", "head", "cat", "basename", "mkdir")
			}
			stdout, stderr, err := r.runWithPath(t, tc.npm == "")
			if err != nil {
				t.Fatalf("script failed: %v\nstderr: %s", err, stderr)
			}
			res, err := parseLintScriptResult(stdout)
			if err != nil {
				t.Fatal(err)
			}
			for _, key := range []string{"typescript", "javascript_lint"} {
				if got := res.Linters[key].Status; got != tc.want {
					t.Fatalf("%s status = %q, want %q", key, got, tc.want)
				}
			}
		})
	}
}

func (r *scriptRig) runWithPath(t *testing.T, stubsOnly bool, extra ...string) ([]byte, []byte, error) {
	if !stubsOnly {
		return r.run(t, extra...)
	}
	env := r.env()
	for i, kv := range env {
		if strings.HasPrefix(kv, "PATH=") {
			env[i] = "PATH=" + r.stubs
		}
	}
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("bash not on PATH")
	}
	cmd := exec.Command(bash, moduleForgeScript(t, "lint-discovery.sh"))
	cmd.Env = append(env, extra...)
	cmd.Dir = r.workdir
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	err = cmd.Run()
	return out.Bytes(), errb.Bytes(), err
}

func TestLintScript_RefusesToRunRepositoryCodeWithACredential(t *testing.T) {
	needTools(t, "bash")
	for _, kv := range []string{"LINT_GIT_TOKEN=x", "LINT_GIT_USERNAME=x", "GIT_ASKPASS=/x"} {
		t.Run(kv, func(t *testing.T) {
			r := newScriptRig(t)
			r.file(t, "Gemfile", "\n")
			r.stub(t, "ruby", "exit 0\n")
			r.stub(t, "bundle", "touch \"$WORKDIR/ran\"\nexit 0\n")

			stdout, _, err := r.run(t, kv)
			var exitErr *exec.ExitError
			if !errorsAs(err, &exitErr) || exitErr.ExitCode() != 64 {
				t.Fatalf("expected exit 64, got %v", err)
			}
			if len(stdout) != 0 {
				t.Fatalf("stdout must stay empty: %q", stdout)
			}
			if _, err := os.Stat(filepath.Join(r.workdir, "ran")); err == nil {
				t.Fatal("repository tooling ran despite the credential")
			}
		})
	}
}

func TestAskpass_AnswersOnlyTheNamedHost(t *testing.T) {
	needTools(t, "sh")
	env := []string{"LINT_GIT_HOST=git.example.test:8443", "LINT_GIT_USERNAME=x-access-token", "LINT_GIT_TOKEN=" + tokenOne}
	cases := map[string]string{
		"Username for 'https://git.example.test:8443': ":                     "x-access-token",
		"Password for 'https://x-access-token@git.example.test:8443': ":      tokenOne,
		"Password for 'https://x-access-token@evil.test': ":                  "",
		"Username for 'https://evil.test': ":                                 "",
		"Password for 'https://x-access-token@git.example.test:8443.evil': ": "",
		"Password for 'https://x-access-token@git.example.test': ":           "",
		"Password for 'https://other@git.example.test:8443': ":               "",
		"Password for 'https://evil.test/git.example.test:8443': ":           "",
		"Are you sure you want to continue connecting (yes/no)? ":            "",
	}
	for prompt, want := range cases {
		cmd := exec.Command("sh", moduleForgeScript(t, "lint-discovery-askpass.sh"), prompt)
		cmd.Env = env
		out, err := cmd.Output()
		if err != nil {
			t.Fatalf("%q: %v", prompt, err)
		}
		if got := strings.TrimRight(string(out), "\n"); got != want {
			t.Fatalf("prompt %q answered %q, want %q", prompt, got, want)
		}
	}
}

func TestCloneScript_RefusesAnythingButHTTPSAndRunsNoGit(t *testing.T) {
	needTools(t, "bash")
	r := newScriptRig(t)
	r.stub(t, "git", "touch \"$WORKDIR/git-ran\"\nexit 0\n")
	r.stub(t, "timeout", "shift; exec \"$@\"\n")
	for _, u := range []string{"http://git.example.test/a.git", "ext::sh -c id", "file:///etc", "ssh://h/a"} {
		env := lintCloneEnv(lintRepository{Ref: "main", Username: "x-access-token", Token: tokenOne}, u, "h", r.workdir,
			time.Minute)
		for i, kv := range env {
			if strings.HasPrefix(kv, "PATH=") {
				env[i] = "PATH=" + r.stubs + ":/usr/bin:/bin"
			}
		}
		cmd := exec.Command("bash", moduleForgeScript(t, "lint-discovery-clone.sh"))
		cmd.Env = env
		out, err := cmd.CombinedOutput()
		var exitErr *exec.ExitError
		if !errorsAs(err, &exitErr) || exitErr.ExitCode() != 64 {
			t.Fatalf("%q: expected exit 64, got %v (%s)", u, err, out)
		}
		if strings.Contains(string(out), tokenOne) {
			t.Fatalf("%q: the refusal printed the credential", u)
		}
	}
	if _, err := os.Stat(filepath.Join(r.workdir, "git-ran")); err == nil {
		t.Fatal("git ran for a refused URL")
	}
}

// scriptStatuses runs the script and returns each linter's status.
func scriptStatuses(t *testing.T, r *scriptRig, stubsOnly bool, extra ...string) map[string]string {
	t.Helper()
	stdout, stderr, err := r.runWithPath(t, stubsOnly, extra...)
	if err != nil {
		t.Fatalf("script failed: %v\nstderr: %s", err, stderr)
	}
	res, err := parseLintScriptResult(stdout)
	if err != nil {
		t.Fatal(err)
	}
	out := map[string]string{}
	for key, rep := range res.Linters {
		out[key] = rep.Status
	}
	return out
}

// D1b critic M3: a runner without the toolchain says which program is
// missing, and that is a did-not-measure status, never a clean one.
func TestLintScript_NamesTheMissingToolchain(t *testing.T) {
	needTools(t, "bash", "jq", "timeout")
	cases := map[string]struct {
		files []string
		stubs []string
		key   string
		want  string
	}{
		"no ruby":   {files: []string{"Gemfile"}, key: "ruby", want: "missing_ruby"},
		"no bundle": {files: []string{"Gemfile"}, stubs: []string{"ruby"}, key: "ruby", want: "missing_bundle"},
		"no npm":    {files: []string{"package.json", "tsconfig.json"}, stubs: []string{"node"}, key: "typescript", want: "missing_npm"},
		// The install ran; the linter's own launcher is what is missing.
		"no npx": {files: []string{"package.json", "tsconfig.json"}, stubs: []string{"node", "npm"}, key: "typescript", want: "missing_npx"},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			r := newScriptRig(t)
			for _, f := range tc.files {
				r.file(t, f, "{}\n")
			}
			for _, s := range tc.stubs {
				r.stub(t, s, "exit 0\n")
			}
			linkTools(t, r, "jq", "timeout", "cat", "basename", "mkdir")

			if got := scriptStatuses(t, r, true)[tc.key]; got != tc.want {
				t.Fatalf("%s status = %q, want %q", tc.key, got, tc.want)
			}
		})
	}
}

// D1b critic L4: a tsconfig or ESLint config with no package.json at the root
// is reported, instead of silently dropping out of the result.
func TestLintScript_ReportsADetectedLinterWithNoPackageJSON(t *testing.T) {
	needTools(t, "bash", "jq", "timeout")
	r := newScriptRig(t)
	r.file(t, "tsconfig.json", "{}\n")
	r.file(t, ".eslintrc.json", "{}\n")

	got := scriptStatuses(t, r, false)
	if got["typescript"] != "no_package_json" || got["javascript_lint"] != "no_package_json" {
		t.Fatalf("statuses %v, want no_package_json for both", got)
	}
}

// D1b critic L5b and H2: a linter that runs out of its step bound reads
// timeout; one ended by a signal reads killed. Neither sends output. One that
// ignores TERM is KILLed after the grace (critic M1: `timeout -k`), so a step
// never outlives its bound plus the grace.
func TestLintScript_ReportsALinterThatTimedOutOrWasKilled(t *testing.T) {
	needTools(t, "bash", "jq", "timeout", "wc")
	for name, tc := range map[string]struct {
		exec string
		want string
	}{
		"timed out":    {exec: "sleep 5", want: "timeout"},
		"killed":       {exec: "kill -KILL $$", want: "killed"},
		"ignored TERM": {exec: "trap '' TERM; sleep 5", want: "killed"},
	} {
		t.Run(name, func(t *testing.T) {
			r := newScriptRig(t)
			r.step = time.Second
			r.file(t, "Gemfile", "\n")
			r.stub(t, "ruby", "exit 0\n")
			r.stub(t, "bundle", `case "$1" in install) exit 0 ;; exec) `+tc.exec+` ;; esac`+"\n")

			started := time.Now()
			if got := scriptStatuses(t, r, false, "LINT_KILL_AFTER_SECONDS=1")["ruby"]; got != tc.want {
				t.Fatalf("ruby status = %q, want %q", got, tc.want)
			}
			if took := time.Since(started); took > 4*time.Second {
				t.Fatalf("the step outlived its bound plus the grace: %v", took)
			}
		})
	}
}

// Security critic I1: the host and username are matched as literal text, so a
// `*` in either never widens the match to another host.
func TestAskpass_MatchesTheHostAndUserLiterally(t *testing.T) {
	needTools(t, "sh")
	env := []string{"LINT_GIT_HOST=*", "LINT_GIT_USERNAME=*", "LINT_GIT_TOKEN=" + tokenOne}
	for prompt, want := range map[string]string{
		"Password for 'https://*@*': ":         tokenOne, // the literal host and user
		"Username for 'https://*': ":           "*",
		"Password for 'https://x@evil.test': ": "",
		"Username for 'https://evil.test': ":   "",
		"Password for 'https://*@evil.test': ": "",
	} {
		cmd := exec.Command("sh", moduleForgeScript(t, "lint-discovery-askpass.sh"), prompt)
		cmd.Env = env
		out, err := cmd.Output()
		if err != nil {
			t.Fatalf("%q: %v", prompt, err)
		}
		if got := strings.TrimRight(string(out), "\n"); got != want {
			t.Fatalf("prompt %q answered %q, want %q", prompt, got, want)
		}
	}
}

// D1b critic M1: a git that ignores TERM is KILLed after the grace, so the
// clone phase never outlives its bound plus the grace.
func TestCloneScript_KillsAGitThatIgnoresTERM(t *testing.T) {
	needTools(t, "bash", "timeout")
	r := newScriptRig(t)
	r.stub(t, "git", "trap '' TERM\nsleep 5\n")
	env := lintCloneEnv(lintRepository{Ref: "main", Username: "x-access-token", Token: tokenOne},
		"https://git.example.test/a.git", "git.example.test", r.workdir, time.Second)
	for i, kv := range env {
		if strings.HasPrefix(kv, "PATH=") {
			env[i] = "PATH=" + r.stubs + ":/usr/bin:/bin"
		}
	}
	cmd := exec.Command("bash", moduleForgeScript(t, "lint-discovery-clone.sh"))
	cmd.Env = append(env, "LINT_KILL_AFTER_SECONDS=1")

	started := time.Now()
	out, err := cmd.CombinedOutput()
	var exitErr *exec.ExitError
	if !errorsAs(err, &exitErr) || exitErr.ExitCode() != 137 {
		t.Fatalf("expected the clone KILLed (exit 137), got %v (%s)", err, out)
	}
	if took := time.Since(started); took > 4*time.Second {
		t.Fatalf("the clone outlived its bound plus the grace: %v", took)
	}
}

// D1b critic M1: every step bound comes from the agent. Without one, or with
// one that is not a positive whole number, the script runs nothing rather than
// an unbounded step.
func TestLintScript_RefusesToRunWithoutItsStepBounds(t *testing.T) {
	needTools(t, "bash")
	for _, key := range []string{"LINT_TIMEOUT_SECONDS", "LINT_KILL_AFTER_SECONDS"} {
		for name, value := range map[string]string{"absent": "", "zero": "0", "not a number": "10m"} {
			t.Run(key+" "+name, func(t *testing.T) {
				r := newScriptRig(t)
				r.file(t, "Gemfile", "\n")
				r.stub(t, "ruby", "exit 0\n")
				r.stub(t, "bundle", "touch \"$WORKDIR/ran\"\nexit 0\n")
				var env []string
				for _, kv := range r.env() {
					switch {
					case strings.HasPrefix(kv, key+"="):
					case strings.HasPrefix(kv, "PATH="):
						env = append(env, "PATH="+r.stubs+":/usr/bin:/bin")
					default:
						env = append(env, kv)
					}
				}
				if value != "" {
					env = append(env, key+"="+value)
				}
				cmd := exec.Command("bash", moduleForgeScript(t, "lint-discovery.sh"))
				cmd.Env = env
				cmd.Dir = r.workdir

				stdout, err := cmd.Output()
				var exitErr *exec.ExitError
				if !errorsAs(err, &exitErr) || exitErr.ExitCode() != 64 {
					t.Fatalf("expected exit 64, got %v", err)
				}
				if len(stdout) != 0 {
					t.Fatalf("stdout must stay empty: %q", stdout)
				}
				if _, err := os.Stat(filepath.Join(r.workdir, "ran")); err == nil {
					t.Fatal("repository tooling ran without its step bound")
				}
			})
		}
	}
}
