package lifecycle

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/manifest"
	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// Plan reference: P8.1 — service lifecycle test suite. Each test
// uses RecorderRunner to assert shell-out shape without invoking
// systemd, and POWERNODE_LIFECYCLE_UNIT_DIR to write to a per-test
// tmpdir so the host's real /etc/systemd/system stays untouched.

func setUnitDir(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("POWERNODE_LIFECYCLE_UNIT_DIR", dir)
	return dir
}

func TestRenderUnit_FullDirective_Mapping(t *testing.T) {
	svc := manifest.Service{
		Name:             "postgres",
		StartCommand:     "/usr/bin/postgres -D /var/lib/postgresql",
		StopCommand:      "/usr/bin/pg_ctl stop -m fast",
		RestartPolicy:    "always",
		User:             "postgres",
		WorkingDirectory: "/var/lib/postgresql",
		Env:              map[string]string{"PGDATA": "/var/lib/postgresql", "LANG": "en_US.UTF-8"},
		Dependencies:     []string{"redis"},
	}
	got := RenderUnit(svc, "mod-123")

	wants := []string{
		"Description=Powernode service postgres (module mod-123)",
		"After=powernode-mod-123-redis.service",
		"Requires=powernode-mod-123-redis.service",
		"User=postgres",
		"WorkingDirectory=/var/lib/postgresql",
		"Environment=LANG=en_US.UTF-8", // sorted by key
		"Environment=PGDATA=/var/lib/postgresql",
		"ExecStart=/usr/bin/postgres -D /var/lib/postgresql",
		"ExecStop=/usr/bin/pg_ctl stop -m fast",
		"Restart=always",
		"WantedBy=multi-user.target",
	}
	for _, want := range wants {
		if !strings.Contains(got, want) {
			t.Errorf("expected %q in unit body:\n%s", want, got)
		}
	}
}

func TestRenderUnit_RestartPolicyMapping(t *testing.T) {
	cases := []struct {
		policy string
		want   string
	}{
		{"always", "Restart=always"},
		{"on-failure", "Restart=on-failure"},
		{"never", "Restart=no"},
		{"", "Restart=on-failure"}, // safe default
		{"garbage", "Restart=on-failure"},
	}
	for _, c := range cases {
		got := RenderUnit(manifest.Service{Name: "x", StartCommand: "/bin/true", RestartPolicy: c.policy}, "m")
		if !strings.Contains(got, c.want) {
			t.Errorf("policy=%q: missing %q in:\n%s", c.policy, c.want, got)
		}
	}
}

func TestTopoSort_LinearChain(t *testing.T) {
	services := []manifest.Service{
		{Name: "c", StartCommand: "/bin/true", Dependencies: []string{"b"}},
		{Name: "a", StartCommand: "/bin/true"},
		{Name: "b", StartCommand: "/bin/true", Dependencies: []string{"a"}},
	}
	ordered, err := topoSort(services)
	if err != nil {
		t.Fatalf("topoSort: %v", err)
	}
	names := []string{ordered[0].Name, ordered[1].Name, ordered[2].Name}
	want := []string{"a", "b", "c"}
	for i := range want {
		if names[i] != want[i] {
			t.Fatalf("order[%d]: got %q, want %q (full: %v)", i, names[i], want[i], names)
		}
	}
}

func TestTopoSort_StableOnTies(t *testing.T) {
	// Two independent services — sort by name asc deterministically.
	services := []manifest.Service{
		{Name: "z", StartCommand: "/bin/true"},
		{Name: "a", StartCommand: "/bin/true"},
		{Name: "m", StartCommand: "/bin/true"},
	}
	ordered, err := topoSort(services)
	if err != nil {
		t.Fatalf("topoSort: %v", err)
	}
	got := []string{ordered[0].Name, ordered[1].Name, ordered[2].Name}
	if got[0] != "a" || got[1] != "m" || got[2] != "z" {
		t.Errorf("expected stable a,m,z; got %v", got)
	}
}

func TestTopoSort_CycleDetected(t *testing.T) {
	services := []manifest.Service{
		{Name: "a", StartCommand: "/bin/true", Dependencies: []string{"b"}},
		{Name: "b", StartCommand: "/bin/true", Dependencies: []string{"a"}},
	}
	_, err := topoSort(services)
	if err == nil {
		t.Fatal("expected cycle error, got nil")
	}
	if !strings.Contains(err.Error(), "cycle") {
		t.Errorf("expected error to mention cycle, got %v", err)
	}
}

func TestTopoSort_UnknownDependencyIgnored(t *testing.T) {
	// Reference to a service not in the set — treated as unmet but
	// doesn't fail the topo (operator sees the warning in logs).
	services := []manifest.Service{
		{Name: "x", StartCommand: "/bin/true", Dependencies: []string{"nope"}},
	}
	ordered, err := topoSort(services)
	if err != nil {
		t.Fatalf("topoSort: %v", err)
	}
	if len(ordered) != 1 || ordered[0].Name != "x" {
		t.Fatalf("expected single x, got %+v", ordered)
	}
}

func TestAttachServices_WritesUnits_RunsReloadAndStart(t *testing.T) {
	dir := setUnitDir(t)
	r := &mount.RecorderRunner{}
	services := []manifest.Service{
		{Name: "redis", StartCommand: "/usr/bin/redis-server", RestartPolicy: "always"},
		{Name: "postgres", StartCommand: "/usr/bin/postgres", RestartPolicy: "always", Dependencies: []string{"redis"}},
	}

	results, err := AttachServices(context.Background(), r, "mod-x", services)
	if err != nil {
		t.Fatalf("attach: %v", err)
	}
	if len(results) != 2 {
		t.Fatalf("expected 2 results, got %d", len(results))
	}

	// Unit files exist on disk
	for _, name := range []string{"redis", "postgres"} {
		path := filepath.Join(dir, "powernode-mod-x-"+name+".service")
		if _, err := os.Stat(path); err != nil {
			t.Errorf("expected unit file %s to exist: %v", path, err)
		}
	}

	// Order asserted: daemon-reload, then start redis, then start postgres
	var ops []string
	for _, inv := range r.Invocations {
		ops = append(ops, inv.Name+" "+strings.Join(inv.Args, " "))
	}

	// Find the indexes
	var reloadIdx, redisStartIdx, postgresStartIdx int = -1, -1, -1
	for i, op := range ops {
		switch {
		case op == "systemctl daemon-reload":
			if reloadIdx < 0 {
				reloadIdx = i
			}
		case op == "systemctl start powernode-mod-x-redis.service":
			redisStartIdx = i
		case op == "systemctl start powernode-mod-x-postgres.service":
			postgresStartIdx = i
		}
	}
	if reloadIdx < 0 {
		t.Errorf("expected daemon-reload; ops: %v", ops)
	}
	if !(reloadIdx < redisStartIdx && redisStartIdx < postgresStartIdx) {
		t.Errorf("expected reload<redis<postgres order; reload=%d redis=%d postgres=%d", reloadIdx, redisStartIdx, postgresStartIdx)
	}
}

func TestAttachServices_Idempotent_NoReloadOnUnchangedContent(t *testing.T) {
	_ = setUnitDir(t)
	services := []manifest.Service{
		{Name: "redis", StartCommand: "/usr/bin/redis-server", RestartPolicy: "always"},
	}

	// First attach
	r1 := &mount.RecorderRunner{}
	if _, err := AttachServices(context.Background(), r1, "mod-x", services); err != nil {
		t.Fatalf("attach1: %v", err)
	}
	// Second attach — content unchanged, expect no daemon-reload
	r2 := &mount.RecorderRunner{}
	if _, err := AttachServices(context.Background(), r2, "mod-x", services); err != nil {
		t.Fatalf("attach2: %v", err)
	}
	for _, inv := range r2.Invocations {
		if inv.Name == "systemctl" && len(inv.Args) > 0 && inv.Args[0] == "daemon-reload" {
			t.Errorf("expected no daemon-reload on second attach (idempotent), got %+v", r2.Invocations)
		}
	}
}

func TestDetachServices_ReverseOrder_ReloadsAfter(t *testing.T) {
	dir := setUnitDir(t)
	// Pre-create the unit files so detach has something to remove
	for _, name := range []string{"redis", "postgres"} {
		path := filepath.Join(dir, "powernode-mod-x-"+name+".service")
		if err := os.WriteFile(path, []byte("dummy"), 0o644); err != nil {
			t.Fatalf("setup: %v", err)
		}
	}

	r := &mount.RecorderRunner{}
	services := []manifest.Service{
		{Name: "redis", StartCommand: "/usr/bin/redis-server"},
		{Name: "postgres", StartCommand: "/usr/bin/postgres", Dependencies: []string{"redis"}},
	}
	if _, err := DetachServices(context.Background(), r, "mod-x", services); err != nil {
		t.Fatalf("detach: %v", err)
	}

	// Order: stop postgres, stop redis, daemon-reload (reverse topo + cleanup)
	var stopPgIdx, stopRedisIdx, reloadIdx int = -1, -1, -1
	for i, inv := range r.Invocations {
		joined := inv.Name + " " + strings.Join(inv.Args, " ")
		switch joined {
		case "systemctl stop powernode-mod-x-postgres.service":
			stopPgIdx = i
		case "systemctl stop powernode-mod-x-redis.service":
			stopRedisIdx = i
		case "systemctl daemon-reload":
			reloadIdx = i
		}
	}
	if stopPgIdx < 0 || stopRedisIdx < 0 || reloadIdx < 0 {
		t.Fatalf("missing stop/reload ops; invocations: %+v", r.Invocations)
	}
	if !(stopPgIdx < stopRedisIdx && stopRedisIdx < reloadIdx) {
		t.Errorf("expected postgres-stop < redis-stop < reload; pg=%d redis=%d reload=%d", stopPgIdx, stopRedisIdx, reloadIdx)
	}

	// Unit files removed
	for _, name := range []string{"redis", "postgres"} {
		path := filepath.Join(dir, "powernode-mod-x-"+name+".service")
		if _, err := os.Stat(path); !os.IsNotExist(err) {
			t.Errorf("expected %s to be removed after detach", path)
		}
	}
}

func TestAttachServices_NilRunner_Error(t *testing.T) {
	_, err := AttachServices(context.Background(), nil, "x", []manifest.Service{{Name: "a", StartCommand: "/bin/true"}})
	if err == nil {
		t.Fatal("expected nil-runner error")
	}
}

func TestAttachServices_EmptyServices_NoOp(t *testing.T) {
	r := &mount.RecorderRunner{}
	results, err := AttachServices(context.Background(), r, "x", nil)
	if err != nil {
		t.Fatalf("expected nil err, got %v", err)
	}
	if results != nil {
		t.Errorf("expected nil results on empty input, got %+v", results)
	}
	if len(r.Invocations) != 0 {
		t.Errorf("expected no shell-outs on empty input, got %+v", r.Invocations)
	}
}
