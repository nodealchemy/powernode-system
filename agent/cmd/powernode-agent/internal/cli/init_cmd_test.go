package cli

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/powernode/platform/extensions/system/agent/internal/manifest"
	"github.com/powernode/platform/extensions/system/agent/internal/mount"
)

// seedManifest writes a manifest.json to the cache root for a given
// module id with the supplied units list.
func seedManifest(t *testing.T, root, moduleID string, units []string) {
	t.Helper()
	dir := filepath.Join(root, moduleID)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	mf := manifest.Manifest{
		ID: moduleID,
		Config: map[string]any{
			"units": stringsToAny(units),
		},
	}
	body, _ := json.Marshal(mf)
	if err := os.WriteFile(filepath.Join(dir, "manifest.json"), body, 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
}

func stringsToAny(in []string) []any {
	out := make([]any, len(in))
	for i, s := range in {
		out[i] = s
	}
	return out
}

func TestInitStartIssuesSystemctlStart(t *testing.T) {
	root := t.TempDir()
	seedManifest(t, root, "m1", []string{"nginx.service", "php-fpm.service"})

	runner := &mount.RecorderRunner{}
	res, err := RunInit(context.Background(), InitOptions{
		ModuleID:     "m1",
		Action:       "start",
		ManifestRoot: root,
		Runner:       runner,
	})
	if err != nil {
		t.Fatalf("RunInit: %v", err)
	}
	if res.Status != "ok" {
		t.Errorf("status: %q", res.Status)
	}

	// Both units started, in forward order.
	var startCalls []string
	for _, inv := range runner.Invocations {
		if inv.Name == "systemctl" && len(inv.Args) >= 2 && inv.Args[0] == "start" {
			startCalls = append(startCalls, inv.Args[1])
		}
	}
	if len(startCalls) != 2 || startCalls[0] != "nginx.service" || startCalls[1] != "php-fpm.service" {
		t.Errorf("start order: %v", startCalls)
	}
}

func TestInitRestartReverseStops(t *testing.T) {
	root := t.TempDir()
	seedManifest(t, root, "m1", []string{"nginx.service", "php-fpm.service"})

	runner := &mount.RecorderRunner{}
	res, err := RunInit(context.Background(), InitOptions{
		ModuleID:     "m1",
		Action:       "restart",
		ManifestRoot: root,
		Runner:       runner,
	})
	if err != nil {
		t.Fatalf("RunInit: %v", err)
	}
	if res.Status != "ok" {
		t.Errorf("status: %q", res.Status)
	}

	var stops, starts []string
	for _, inv := range runner.Invocations {
		if inv.Name != "systemctl" || len(inv.Args) < 2 {
			continue
		}
		switch inv.Args[0] {
		case "stop":
			stops = append(stops, inv.Args[1])
		case "start":
			starts = append(starts, inv.Args[1])
		}
	}
	// Stops in reverse order.
	if len(stops) != 2 || stops[0] != "php-fpm.service" || stops[1] != "nginx.service" {
		t.Errorf("stop order: %v (want reverse)", stops)
	}
	// Starts in forward order.
	if len(starts) != 2 || starts[0] != "nginx.service" || starts[1] != "php-fpm.service" {
		t.Errorf("start order: %v (want forward)", starts)
	}
}

func TestInitInvalidVerb(t *testing.T) {
	res, err := RunInit(context.Background(), InitOptions{
		ModuleID: "m1",
		Action:   "kill",
	})
	if err == nil {
		t.Errorf("expected error for invalid verb")
	}
	var ce *CommandError
	if !errors.As(err, &ce) || ce.Code != ExitGeneric {
		t.Errorf("expected ExitGeneric, got %T %v", err, err)
	}
	if res.Status != "error" {
		t.Errorf("status: %q", res.Status)
	}
}

func TestInitMissingModuleID(t *testing.T) {
	_, err := RunInit(context.Background(), InitOptions{Action: "start"})
	if err == nil {
		t.Errorf("expected error for missing module-id")
	}
}

func TestInitMissingManifest(t *testing.T) {
	root := t.TempDir()
	_, err := RunInit(context.Background(), InitOptions{
		ModuleID:     "no-such-module",
		Action:       "start",
		ManifestRoot: root,
	})
	if err == nil {
		t.Errorf("expected error for missing manifest")
	}
	if !strings.Contains(err.Error(), "manifest missing") && !strings.Contains(err.Error(), "no such") {
		t.Errorf("expected manifest-missing message: %v", err)
	}
}

func TestInitNoUnitsDeclared(t *testing.T) {
	root := t.TempDir()
	seedManifest(t, root, "m1", nil)

	res, err := RunInit(context.Background(), InitOptions{
		ModuleID:     "m1",
		Action:       "start",
		ManifestRoot: root,
		Runner:       &mount.RecorderRunner{},
	})
	if err == nil {
		t.Errorf("expected error for no units")
	}
	if res.Status != "error" {
		t.Errorf("status: %q", res.Status)
	}
}

func TestInitOneUnitFailedReturnsPartial(t *testing.T) {
	root := t.TempDir()
	seedManifest(t, root, "m1", []string{"good.service", "bad.service"})

	runner := &mount.RecorderRunner{
		StubErr: map[string]error{
			"systemctl start bad.service": errors.New("Failed to start bad.service"),
		},
	}
	res, err := RunInit(context.Background(), InitOptions{
		ModuleID:     "m1",
		Action:       "start",
		ManifestRoot: root,
		Runner:       runner,
	})
	if err == nil {
		t.Errorf("expected error for partial failure")
	}
	var ce *CommandError
	if !errors.As(err, &ce) || ce.Code != ExitInitFailed {
		t.Errorf("expected ExitInitFailed, got %T %v", err, err)
	}
	if res.ExitCode != ExitInitFailed {
		t.Errorf("res.ExitCode: %d", res.ExitCode)
	}
}
