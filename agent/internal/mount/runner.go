package mount

import (
	"bytes"
	"context"
	"fmt"
	"os/exec"
	"strings"
)

// Runner abstracts the side-effecting operations the mount package
// performs (mount, umount, mkdir, etc.) so tests can record/replay
// without actually touching the filesystem or invoking root-only
// syscalls.
type Runner interface {
	// Run executes a command. Returns combined stdout+stderr on error.
	Run(ctx context.Context, name string, args ...string) error
	// Output runs a command and returns its stdout.
	Output(ctx context.Context, name string, args ...string) ([]byte, error)
}

// StdinRunner is implemented by Runners that can pipe data to a command's
// stdin rather than passing it as an argument — the delivery a secret
// argument (e.g. a samba-tool password) needs, since argv is readable by
// any other user on the box via /proc/<pid>/cmdline or `ps`, and an env var
// is readable the same way via /proc/<pid>/environ.
//
// Deliberately a SEPARATE interface rather than an added method on Runner
// (IMP-ad2c66a838f2): Runner is consumed and re-implemented (fake Runners in
// bootupgrade/dhcp_renew tests, unrelated to secrets) all over the agent —
// adding a required method there would force every one of those unrelated
// fakes to grow it too. A caller that specifically needs stdin delivery
// type-asserts the mount.Runner it was handed against this interface
// instead; ExecRunner (production) and RecorderRunner (tests) both
// implement it.
type StdinRunner interface {
	RunStdin(ctx context.Context, stdin, name string, args ...string) error
}

// ExecRunner shells out to /bin/$name via os/exec. The default Runner
// in production code paths.
type ExecRunner struct{}

func (ExecRunner) Run(ctx context.Context, name string, args ...string) error {
	cmd := exec.CommandContext(ctx, name, args...)
	var buf bytes.Buffer
	cmd.Stdout = &buf
	cmd.Stderr = &buf
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("%s %v: %w (output: %s)", name, args, err, buf.String())
	}
	return nil
}

// RunStdin is Run's stdin-delivering counterpart: identical argv/error
// handling, except `stdin` is written to the child process's stdin instead
// of appearing as an argument. Used for secrets that must never reach argv
// or the environment.
func (ExecRunner) RunStdin(ctx context.Context, stdin, name string, args ...string) error {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Stdin = strings.NewReader(stdin)
	var buf bytes.Buffer
	cmd.Stdout = &buf
	cmd.Stderr = &buf
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("%s %v: %w (output: %s)", name, args, err, buf.String())
	}
	return nil
}

func (ExecRunner) Output(ctx context.Context, name string, args ...string) ([]byte, error) {
	out, err := exec.CommandContext(ctx, name, args...).Output()
	if err != nil {
		var stderr []byte
		if ee, ok := err.(*exec.ExitError); ok {
			stderr = ee.Stderr
		}
		return nil, fmt.Errorf("%s %v: %w (stderr: %s)", name, args, err, string(stderr))
	}
	return out, nil
}

// Invocation captures a single Run/Output/RunStdin call for assertion in
// tests. Stdin is populated only by RunStdin — left "" for Run/Output — so
// a test can assert BOTH that a secret is absent from Args and present in
// Stdin.
type Invocation struct {
	Op    string // "Run", "Output", or "RunStdin"
	Name  string
	Args  []string
	Stdin string
}

// RecorderRunner records every command instead of executing it. Used by
// unit tests to verify the mount package issues the right syscalls in
// the right order. Optional StubOutput / StubErr maps simulate command
// results.
type RecorderRunner struct {
	Invocations []Invocation
	StubOutput  map[string][]byte // key: "name arg0 arg1 ..." → stdout to return
	StubErr     map[string]error  // key: same → error to return
	// StubErrOnce is StubErr's fail-then-succeed twin: the error fires for
	// the FIRST call matching the key and is then removed from the map, so
	// every later call with the SAME key (identical name+args) falls
	// through to success. Needed wherever a caller retries with the exact
	// same argv — e.g. security.applyEgressScript's per-process staging
	// path is stable across a fallback retry within one apply, so a plain
	// StubErr entry there would fail the retry too, defeating the very
	// fallback path a test wants to exercise. Checked AFTER StubErr, so a
	// key present in both always behaves as a permanent failure (StubErr
	// wins) — no test needs both for the same key today, but a caller that
	// wants "always fail" from an existing StubErr must not have that
	// silently downgraded to "fail once" by an unrelated StubErrOnce entry.
	StubErrOnce map[string]error
}

func (r *RecorderRunner) key(name string, args []string) string {
	k := name
	for _, a := range args {
		k += " " + a
	}
	return k
}

// consumeStubErr returns the error (if any) StubErr/StubErrOnce declares for
// key — StubErr takes precedence and never expires; StubErrOnce, checked
// second, fires exactly once and deletes itself.
func (r *RecorderRunner) consumeStubErr(key string) (error, bool) {
	if err, ok := r.StubErr[key]; ok {
		return err, true
	}
	if err, ok := r.StubErrOnce[key]; ok {
		delete(r.StubErrOnce, key)
		return err, true
	}
	return nil, false
}

func (r *RecorderRunner) Run(_ context.Context, name string, args ...string) error {
	r.Invocations = append(r.Invocations, Invocation{Op: "Run", Name: name, Args: append([]string(nil), args...)})
	if err, ok := r.consumeStubErr(r.key(name, args)); ok {
		return err
	}
	return nil
}

func (r *RecorderRunner) RunStdin(_ context.Context, stdin, name string, args ...string) error {
	r.Invocations = append(r.Invocations, Invocation{Op: "RunStdin", Name: name, Args: append([]string(nil), args...), Stdin: stdin})
	if err, ok := r.consumeStubErr(r.key(name, args)); ok {
		return err
	}
	return nil
}

func (r *RecorderRunner) Output(_ context.Context, name string, args ...string) ([]byte, error) {
	r.Invocations = append(r.Invocations, Invocation{Op: "Output", Name: name, Args: append([]string(nil), args...)})
	if err, ok := r.consumeStubErr(r.key(name, args)); ok {
		return nil, err
	}
	if out, ok := r.StubOutput[r.key(name, args)]; ok {
		return out, nil
	}
	return nil, nil
}
