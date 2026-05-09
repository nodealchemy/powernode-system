package systemd

import (
	"context"
	"errors"
	"testing"

	"github.com/powernode/platform/extensions/system/agent/internal/mount"
)

func TestActionValidVerbs(t *testing.T) {
	cases := []struct {
		verb ActionVerb
		args []string
	}{
		{Start, []string{"start", "nginx.service"}},
		{Stop, []string{"stop", "nginx.service"}},
		{Restart, []string{"restart", "nginx.service"}},
		{Reload, []string{"reload", "nginx.service"}},
		{Status, []string{"status", "nginx.service"}},
	}
	for _, tc := range cases {
		t.Run(string(tc.verb), func(t *testing.T) {
			runner := &mount.RecorderRunner{}
			if err := Action(context.Background(), runner, "nginx.service", tc.verb); err != nil {
				t.Fatalf("Action: %v", err)
			}
			if len(runner.Invocations) != 1 {
				t.Fatalf("expected 1 invocation, got %d", len(runner.Invocations))
			}
			inv := runner.Invocations[0]
			if inv.Op != "Run" || inv.Name != "systemctl" {
				t.Errorf("got %+v", inv)
			}
			if len(inv.Args) != 2 || inv.Args[0] != tc.args[0] || inv.Args[1] != tc.args[1] {
				t.Errorf("args: got %v want %v", inv.Args, tc.args)
			}
		})
	}
}

func TestActionInvalidVerb(t *testing.T) {
	runner := &mount.RecorderRunner{}
	err := Action(context.Background(), runner, "nginx.service", ActionVerb("kill"))
	if err == nil {
		t.Errorf("expected error for invalid verb")
	}
	if len(runner.Invocations) != 0 {
		t.Errorf("invocation leaked: %v", runner.Invocations)
	}
}

func TestActionRejectsShellMetachars(t *testing.T) {
	runner := &mount.RecorderRunner{}
	cases := []string{
		"nginx.service; rm -rf /",
		"nginx.service`whoami`",
		"$EVIL",
		"foo bar.service",
		"-evil.service",
	}
	for _, name := range cases {
		t.Run(name, func(t *testing.T) {
			if err := Action(context.Background(), runner, name, Start); err == nil {
				t.Errorf("expected rejection of %q", name)
			}
		})
	}
}

func TestActionEmptyUnit(t *testing.T) {
	runner := &mount.RecorderRunner{}
	if err := Action(context.Background(), runner, "", Start); err == nil {
		t.Errorf("expected error for empty unit")
	}
}

func TestActionNilRunner(t *testing.T) {
	if err := Action(context.Background(), nil, "nginx.service", Start); err == nil {
		t.Errorf("expected error for nil runner")
	}
}

func TestActionPropagatesRunnerError(t *testing.T) {
	wantErr := errors.New("systemctl missing")
	runner := &mount.RecorderRunner{
		StubErr: map[string]error{"systemctl start nginx.service": wantErr},
	}
	if err := Action(context.Background(), runner, "nginx.service", Start); err == nil {
		t.Errorf("expected error from runner")
	}
}

func TestIsActiveReturnsTrueForActive(t *testing.T) {
	runner := &mount.RecorderRunner{
		StubOutput: map[string][]byte{
			"systemctl is-active nginx.service": []byte("active\n"),
		},
	}
	got, err := IsActive(context.Background(), runner, "nginx.service")
	if err != nil {
		t.Fatalf("IsActive: %v", err)
	}
	if !got {
		t.Errorf("expected true")
	}
}

func TestIsActiveReturnsFalseForInactive(t *testing.T) {
	// systemctl is-active exits non-zero for inactive units, but stdout still
	// has the state. Stub returns inactive output (no error).
	runner := &mount.RecorderRunner{
		StubOutput: map[string][]byte{
			"systemctl is-active nginx.service": []byte("inactive\n"),
		},
	}
	got, _ := IsActive(context.Background(), runner, "nginx.service")
	if got {
		t.Errorf("expected false")
	}
}

func TestDaemonReload(t *testing.T) {
	runner := &mount.RecorderRunner{}
	if err := DaemonReload(context.Background(), runner); err != nil {
		t.Fatalf("DaemonReload: %v", err)
	}
	if len(runner.Invocations) != 1 || runner.Invocations[0].Args[0] != "daemon-reload" {
		t.Errorf("got %+v", runner.Invocations)
	}
}
