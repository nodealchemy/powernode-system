// Package mount orchestrates the composefs + overlayfs union mount for
// modules attached to a node instance. The module artifacts (composefs
// metadata images + digest stores) are pulled via oras + verified via
// cosign + fs-verity, then mounted in priority order as overlay lowers,
// with a tmpfs upper layer and a /var bind mount onto /persist/var.
//
// Reference: Golden Eclipse plan M2.D + Security Architecture (composefs
// fs-verity at file open + capability dropping); legacy ipn_functions
// ipn_mod_attach + ipn_mod_detach (which used aufs branch ops).
package mount

import (
	"bytes"
	"context"
	"fmt"
	"os/exec"
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

// Invocation captures a single Run/Output call for assertion in tests.
type Invocation struct {
	Op     string // "Run" or "Output"
	Name   string
	Args   []string
}

// RecorderRunner records every command instead of executing it. Used by
// unit tests to verify the mount package issues the right syscalls in
// the right order. Optional StubOutput / StubErr maps simulate command
// results.
type RecorderRunner struct {
	Invocations []Invocation
	StubOutput  map[string][]byte // key: "name arg0 arg1 ..." → stdout to return
	StubErr     map[string]error  // key: same → error to return
}

func (r *RecorderRunner) key(name string, args []string) string {
	k := name
	for _, a := range args {
		k += " " + a
	}
	return k
}

func (r *RecorderRunner) Run(_ context.Context, name string, args ...string) error {
	r.Invocations = append(r.Invocations, Invocation{Op: "Run", Name: name, Args: append([]string(nil), args...)})
	if err, ok := r.StubErr[r.key(name, args)]; ok {
		return err
	}
	return nil
}

func (r *RecorderRunner) Output(_ context.Context, name string, args ...string) ([]byte, error) {
	r.Invocations = append(r.Invocations, Invocation{Op: "Output", Name: name, Args: append([]string(nil), args...)})
	if err, ok := r.StubErr[r.key(name, args)]; ok {
		return nil, err
	}
	if out, ok := r.StubOutput[r.key(name, args)]; ok {
		return out, nil
	}
	return nil, nil
}
