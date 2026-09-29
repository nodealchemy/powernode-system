package mount

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"os/exec"
	"strings"
	"time"
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

// BoundedRunner is implemented by Runners that can read a command's stdout
// through a hard byte ceiling. Runner.Output buffers ALL of stdout before its
// caller can cap it, which for a diagnostic (a full BGP table, a large nft
// set, hundreds of long journal lines) means tens of megabytes held in the root
// agent. A caller that wants a bound type-asserts its Runner against this
// interface and falls back to Output when it is not implemented.
//
// Deliberately a SEPARATE interface, for the same reason as StdinRunner: the
// Runner fakes all over the agent must not have to grow a method they never use.
type BoundedRunner interface {
	// OutputBounded runs the command and returns at most max bytes of stdout.
	// When the command produces more, the read stops at max+1, the command is
	// killed, and truncated is true; the kill is expected and is not an error.
	OutputBounded(ctx context.Context, max int, name string, args ...string) (out []byte, truncated bool, err error)
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

// boundedStderrBytes caps the stderr an OutputBounded error carries. Stderr is
// bounded for the same reason stdout is: a loud tool must not fill the agent's
// memory through the channel that was not being watched.
const boundedStderrBytes = 4096

// headBuffer keeps the FIRST boundedStderrBytes of what is written to it and
// discards the rest, always reporting the full write so the child never blocks
// on a full pipe.
type headBuffer struct {
	buf bytes.Buffer
}

func (h *headBuffer) Write(p []byte) (int, error) {
	if room := boundedStderrBytes - h.buf.Len(); room > 0 {
		if len(p) < room {
			room = len(p)
		}
		h.buf.Write(p[:room])
	}
	return len(p), nil
}

// OutputBounded implements BoundedRunner: it reads stdout through
// io.LimitReader(max+1) on the pipe, so at most max+1 bytes are ever held, and
// kills the command the moment the cap is exceeded. Runner.Output, which every
// other caller keeps using unchanged, buffers all of stdout first.
func (ExecRunner) OutputBounded(ctx context.Context, max int, name string, args ...string) ([]byte, bool, error) {
	cctx, cancel := context.WithCancel(ctx)
	defer cancel()

	cmd := exec.CommandContext(cctx, name, args...)
	// A grandchild that inherited the pipe must not hold Wait open after the
	// kill.
	cmd.WaitDelay = 2 * time.Second
	stderr := &headBuffer{}
	cmd.Stderr = stderr
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, false, fmt.Errorf("%s %v: %w", name, args, err)
	}
	if err := cmd.Start(); err != nil {
		return nil, false, fmt.Errorf("%s %v: %w", name, args, err)
	}

	out, readErr := io.ReadAll(io.LimitReader(stdout, int64(max)+1))
	truncated := len(out) > max
	if truncated {
		out = out[:max]
		// The cap is hit: stop the command instead of draining it. The kill
		// makes Wait return an error that is the expected outcome, not a fault.
		cancel()
		_ = cmd.Wait()
		return out, true, nil
	}

	waitErr := cmd.Wait()
	if waitErr != nil {
		return nil, false, fmt.Errorf("%s %v: %w (stderr: %s)", name, args, waitErr, stderr.buf.String())
	}
	if readErr != nil {
		return nil, false, fmt.Errorf("%s %v: read stdout: %w", name, args, readErr)
	}
	return out, false, nil
}

// Invocation captures a single Run/Output/RunStdin/OutputBounded call for
// assertion in tests. Stdin is populated only by RunStdin — left "" for
// Run/Output — so a test can assert BOTH that a secret is absent from Args and
// present in Stdin. Max is populated only by OutputBounded.
type Invocation struct {
	Op    string // "Run", "Output", "RunStdin" or "OutputBounded"
	Name  string
	Args  []string
	Stdin string
	Max   int
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

// OutputBounded is the fake of ExecRunner.OutputBounded: the same StubOutput and
// StubErr keys as Output, cut to max bytes with truncated set, so a test can
// prove a caller bounds its read without executing anything.
func (r *RecorderRunner) OutputBounded(_ context.Context, max int, name string, args ...string) ([]byte, bool, error) {
	r.Invocations = append(r.Invocations, Invocation{Op: "OutputBounded", Name: name, Args: append([]string(nil), args...), Max: max})
	if err, ok := r.consumeStubErr(r.key(name, args)); ok {
		return nil, false, err
	}
	out := r.StubOutput[r.key(name, args)]
	if len(out) > max {
		return append([]byte(nil), out[:max]...), true, nil
	}
	return out, false, nil
}
