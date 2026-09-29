package mount

import (
	"context"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"
)

// ExecRunner.OutputBounded is exercised against the TEST BINARY ITSELF (the
// standard helper-process pattern): the only thing these tests ever execute is
// this package's own compiled test binary, never a system tool.

func TestBoundedHelperProcess(t *testing.T) {
	mode := os.Getenv("GO_MOUNT_BOUNDED_HELPER")
	if mode == "" {
		t.Skip("helper process only")
	}
	switch mode {
	case "flood":
		// Far more than any test cap. A reader that does not stop early makes
		// this run for the whole test timeout.
		chunk := []byte(strings.Repeat("x", 4096) + "\n")
		for i := 0; i < 1<<20; i++ {
			if _, err := os.Stdout.Write(chunk); err != nil {
				os.Exit(0)
			}
		}
	case "small":
		fmt.Print("hello\nworld\n")
	case "fail":
		fmt.Fprint(os.Stderr, "boom: bad thing")
		os.Exit(3)
	case "loud-stderr":
		fmt.Fprint(os.Stderr, strings.Repeat("e", 1<<20))
		os.Exit(3)
	}
	os.Exit(0)
}

func helper(t *testing.T, mode string) (string, []string) {
	t.Helper()
	t.Setenv("GO_MOUNT_BOUNDED_HELPER", mode)
	return os.Args[0], []string{"-test.run=^TestBoundedHelperProcess$"}
}

func TestExecRunnerOutputBoundedStopsAndKillsAtTheCap(t *testing.T) {
	name, args := helper(t, "flood")
	start := time.Now()

	out, truncated, err := ExecRunner{}.OutputBounded(context.Background(), 1000, name, args...)

	if err != nil {
		t.Fatalf("the kill after the cap is expected, not an error: %v", err)
	}
	if !truncated || len(out) != 1000 {
		t.Fatalf("expected exactly the cap and truncated=true, got %d bytes truncated=%v", len(out), truncated)
	}
	if time.Since(start) > 10*time.Second {
		t.Fatalf("the command must be killed at the cap, not run to completion (took %s)", time.Since(start))
	}
}

func TestExecRunnerOutputBoundedReturnsSmallOutputWhole(t *testing.T) {
	name, args := helper(t, "small")
	out, truncated, err := ExecRunner{}.OutputBounded(context.Background(), 1000, name, args...)
	if err != nil || truncated || !strings.Contains(string(out), "hello\nworld\n") {
		t.Fatalf("got %q truncated=%v err=%v", out, truncated, err)
	}
}

func TestExecRunnerOutputBoundedExactlyAtTheCapIsNotTruncated(t *testing.T) {
	name, args := helper(t, "small")
	out, truncated, err := ExecRunner{}.OutputBounded(context.Background(), len("hello\nworld\n"), name, args...)
	_ = out
	if err != nil {
		t.Fatal(err)
	}
	if truncated {
		t.Fatalf("output that fits within the cap must not be marked truncated")
	}
}

func TestExecRunnerOutputBoundedReportsAFailureWithItsStderr(t *testing.T) {
	name, args := helper(t, "fail")
	_, _, err := ExecRunner{}.OutputBounded(context.Background(), 1000, name, args...)
	if err == nil || !strings.Contains(err.Error(), "boom: bad thing") {
		t.Fatalf("expected the stderr in the error, got %v", err)
	}
}

// stderr is bounded too: a loud tool must not be able to fill memory through it.
func TestExecRunnerOutputBoundedBoundsStderr(t *testing.T) {
	name, args := helper(t, "loud-stderr")
	_, _, err := ExecRunner{}.OutputBounded(context.Background(), 1000, name, args...)
	if err == nil || len(err.Error()) > 16*1024 {
		t.Fatalf("stderr in the error must be bounded, got %d bytes", len(fmt.Sprint(err)))
	}
}

func TestExecRunnerOutputBoundedHonoursAContextDeadline(t *testing.T) {
	name, args := helper(t, "flood")
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	_, _, err := ExecRunner{}.OutputBounded(ctx, 1<<40, name, args...)
	if err == nil {
		t.Fatal("expected the context deadline to stop the command")
	}
}

func TestRecorderRunnerOutputBoundedTruncatesAndRecords(t *testing.T) {
	rec := &RecorderRunner{StubOutput: map[string][]byte{"nft list ruleset": []byte("0123456789")}}
	out, truncated, err := rec.OutputBounded(context.Background(), 4, "nft", "list", "ruleset")
	if err != nil || !truncated || string(out) != "0123" {
		t.Fatalf("got %q truncated=%v err=%v", out, truncated, err)
	}
	if len(rec.Invocations) != 1 || rec.Invocations[0].Op != "OutputBounded" || rec.Invocations[0].Max != 4 {
		t.Fatalf("invocation not recorded: %+v", rec.Invocations)
	}
	out, truncated, _ = rec.OutputBounded(context.Background(), 100, "nft", "list", "ruleset")
	if truncated || string(out) != "0123456789" {
		t.Fatalf("under the cap must come back whole: %q %v", out, truncated)
	}
}
