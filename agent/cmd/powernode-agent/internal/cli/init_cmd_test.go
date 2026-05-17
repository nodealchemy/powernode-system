package cli

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// seedManifest writes a manifest.json to the cache root for a given
// module id with the supplied services. Services are the canonical
// lifecycle source (P8.1) — one per system_module_services row.
func seedManifest(t *testing.T, root, moduleID string, services []manifest.Service) {
	t.Helper()
	dir := filepath.Join(root, moduleID)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	mf := manifest.Manifest{ID: moduleID, Services: services}
	body, _ := json.Marshal(mf)
	if err := os.WriteFile(filepath.Join(dir, "manifest.json"), body, 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
}

// setUnitDir routes lifecycle's systemd-unit-file writes to a tmpdir
// so tests don't touch the host's real /etc/systemd/system.
func setUnitDir(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("POWERNODE_LIFECYCLE_UNIT_DIR", dir)
	return dir
}

func TestInitStartWritesUnitsAndStarts(t *testing.T) {
	root := t.TempDir()
	_ = setUnitDir(t)
	seedManifest(t, root, "m1", []manifest.Service{
		{Name: "nginx", StartCommand: "/usr/sbin/nginx -g 'daemon off;'"},
		{Name: "php-fpm", StartCommand: "/usr/sbin/php-fpm"},
	})

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

	var startCalls []string
	for _, inv := range runner.Invocations {
		if inv.Name == "systemctl" && len(inv.Args) >= 2 && inv.Args[0] == "start" {
			startCalls = append(startCalls, inv.Args[1])
		}
	}
	if len(startCalls) != 2 {
		t.Fatalf("expected 2 start calls, got %d: %v", len(startCalls), startCalls)
	}
	// Both services are independent — topological sort orders them
	// lexicographically (nginx before php-fpm by name asc).
	if startCalls[0] != "powernode-m1-nginx.service" || startCalls[1] != "powernode-m1-php-fpm.service" {
		t.Errorf("start order: %v", startCalls)
	}
}

func TestInitRestartReverseStopsForwardStarts(t *testing.T) {
	root := t.TempDir()
	_ = setUnitDir(t)
	seedManifest(t, root, "m1", []manifest.Service{
		{Name: "nginx", StartCommand: "/usr/sbin/nginx"},
		{Name: "php-fpm", StartCommand: "/usr/sbin/php-fpm", Dependencies: []string{"nginx"}},
	})

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
	// Topo order: nginx, then php-fpm. Stops reverse: php-fpm, nginx.
	if len(stops) != 2 || stops[0] != "powernode-m1-php-fpm.service" || stops[1] != "powernode-m1-nginx.service" {
		t.Errorf("stop order: %v (want reverse topo)", stops)
	}
	// Starts forward topo: nginx then php-fpm.
	if len(starts) != 2 || starts[0] != "powernode-m1-nginx.service" || starts[1] != "powernode-m1-php-fpm.service" {
		t.Errorf("start order: %v (want forward topo)", starts)
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

func TestInitNoServicesDeclared(t *testing.T) {
	root := t.TempDir()
	seedManifest(t, root, "m1", nil)

	res, err := RunInit(context.Background(), InitOptions{
		ModuleID:     "m1",
		Action:       "start",
		ManifestRoot: root,
		Runner:       &mount.RecorderRunner{},
	})
	if err == nil {
		t.Errorf("expected error for no services")
	}
	if res.Status != "error" {
		t.Errorf("status: %q", res.Status)
	}
	if !strings.Contains(err.Error(), "no services") && !strings.Contains(err.Error(), "system_module_services") {
		t.Errorf("expected services-missing message: %v", err)
	}
}

func TestInitOneServiceFailedReturnsPartial(t *testing.T) {
	root := t.TempDir()
	_ = setUnitDir(t)
	seedManifest(t, root, "m1", []manifest.Service{
		{Name: "good", StartCommand: "/bin/true"},
		{Name: "bad", StartCommand: "/bin/false"},
	})

	runner := &mount.RecorderRunner{
		StubErr: map[string]error{
			"systemctl start powernode-m1-bad.service": errors.New("Failed to start"),
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
