package handlers

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/runtime/tasks"
)

func validProbeOptions() map[string]any {
	return map[string]any{
		"module":    "nginx-fresh",
		"module_id": "mod-123",
		"base_os":   "base-os-ubuntu-noble",
		"services":  []string{"nginx"},
		"health_checks": []map[string]any{
			{"service": "nginx", "endpoint": "http://127.0.0.1:8080/healthz", "method": "GET"},
		},
		"elf_candidates": []string{"/usr/sbin/nginx"},
	}
}

func TestParseProbeModuleSmokeOptions(t *testing.T) {
	opts, err := parseProbeModuleSmokeOptions(&tasks.Task{Options: validProbeOptions()})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if opts.Module != "nginx-fresh" || opts.ModuleID != "mod-123" || opts.BaseOS != "base-os-ubuntu-noble" {
		t.Fatalf("parsed: %+v", opts)
	}
	if len(opts.Services) != 1 || opts.Services[0] != "nginx" {
		t.Fatalf("services: %+v", opts.Services)
	}
	if len(opts.HealthChecks) != 1 || opts.HealthChecks[0].Endpoint != "http://127.0.0.1:8080/healthz" {
		t.Fatalf("health checks: %+v", opts.HealthChecks)
	}
	if len(opts.ElfCandidates) != 1 || opts.ElfCandidates[0] != "/usr/sbin/nginx" {
		t.Fatalf("elf candidates: %+v", opts.ElfCandidates)
	}
	// checks omitted -> defaults to all three, canonical order.
	if len(opts.Checks) != 3 {
		t.Fatalf("default checks: %+v", opts.Checks)
	}
	if opts.HealthCheckTimeoutSeconds != defaultHealthCheckTimeoutSeconds {
		t.Fatalf("default timeout: %d", opts.HealthCheckTimeoutSeconds)
	}

	// missing module / module_id.
	missing := []map[string]any{
		{"module_id": "mod-123"}, // no module
		{"module": "nginx"},      // no module_id
		{},
	}
	for i, o := range missing {
		if _, err := parseProbeModuleSmokeOptions(&tasks.Task{Options: o}); err == nil {
			t.Fatalf("case %d: expected validation error for %v", i, o)
		}
	}

	// unknown check name.
	bad := validProbeOptions()
	bad["checks"] = []string{"unit_active", "not_a_real_check"}
	if _, err := parseProbeModuleSmokeOptions(&tasks.Task{Options: bad}); err == nil {
		t.Fatal("expected validation error for unknown check name")
	}

	// explicit checks subset preserved.
	subset := validProbeOptions()
	subset["checks"] = []string{"health_endpoint"}
	parsed, err := parseProbeModuleSmokeOptions(&tasks.Task{Options: subset})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(parsed.Checks) != 1 || parsed.Checks[0] != "health_endpoint" {
		t.Fatalf("checks subset: %+v", parsed.Checks)
	}

	// health_checks entry missing endpoint.
	badHealth := validProbeOptions()
	badHealth["health_checks"] = []map[string]any{{"service": "nginx"}}
	if _, err := parseProbeModuleSmokeOptions(&tasks.Task{Options: badHealth}); err == nil {
		t.Fatal("expected validation error for health_checks entry missing endpoint")
	}

	// custom timeout honored.
	withTimeout := validProbeOptions()
	withTimeout["health_check_timeout_seconds"] = 15
	parsedTimeout, err := parseProbeModuleSmokeOptions(&tasks.Task{Options: withTimeout})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if parsedTimeout.HealthCheckTimeoutSeconds != 15 {
		t.Fatalf("timeout override: %d", parsedTimeout.HealthCheckTimeoutSeconds)
	}
}

// Real JSON decode shape ([]interface{} / map[string]interface{}, float64
// numbers) must parse identically to the Go-literal shape tests use above —
// task.Options in production comes from json.Unmarshal (tasks.Client /
// loop.go), never Go-native []string literals.
func TestParseProbeModuleSmokeOptions_JSONDecodedShape(t *testing.T) {
	opts := map[string]any{
		"module":    "nginx-fresh",
		"module_id": "mod-123",
		"services":  []any{"nginx"},
		"checks":    []any{"unit_active"},
		"health_checks": []any{
			map[string]any{"service": "nginx", "endpoint": "http://127.0.0.1:8080/healthz"},
		},
		"elf_candidates":               []any{"/usr/sbin/nginx"},
		"health_check_timeout_seconds": float64(10),
	}
	parsed, err := parseProbeModuleSmokeOptions(&tasks.Task{Options: opts})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(parsed.Services) != 1 || parsed.Services[0] != "nginx" {
		t.Fatalf("services: %+v", parsed.Services)
	}
	if len(parsed.Checks) != 1 || parsed.Checks[0] != "unit_active" {
		t.Fatalf("checks: %+v", parsed.Checks)
	}
	if parsed.HealthCheckTimeoutSeconds != 10 {
		t.Fatalf("timeout: %d", parsed.HealthCheckTimeoutSeconds)
	}
}

func TestClassifyUnitActive(t *testing.T) {
	if ok, detail := classifyUnitActive([]byte("active\n"), nil); !ok || detail != "active" {
		t.Fatalf("active case: ok=%v detail=%q", ok, detail)
	}
	if ok, detail := classifyUnitActive(nil, errors.New("systemctl [is-active x]: exit status 3 (stderr: )")); ok || detail == "" {
		t.Fatalf("inactive case: ok=%v detail=%q", ok, detail)
	}
}

func TestClassifyHealthCheck(t *testing.T) {
	cases := []struct {
		out    string
		wantOK bool
	}{
		{"200", true},
		{"302", true},
		{"404", false},
		{"500", false},
	}
	for _, c := range cases {
		ok, detail := classifyHealthCheck([]byte(c.out), nil)
		if ok != c.wantOK {
			t.Errorf("status %s: ok=%v (%q), want %v", c.out, ok, detail, c.wantOK)
		}
	}
	if ok, _ := classifyHealthCheck([]byte("not-a-code"), nil); ok {
		t.Fatal("unparseable status should fail")
	}
	if ok, _ := classifyHealthCheck(nil, errors.New("curl: (7) Failed to connect")); ok {
		t.Fatal("connection error should fail")
	}
}

func TestClassifyLdd(t *testing.T) {
	if ok, detail := classifyLdd([]byte("libc.so.6 => /lib/libc.so.6 (0x1234)\n"), nil); !ok || detail != "resolved" {
		t.Fatalf("resolved case: ok=%v detail=%q", ok, detail)
	}
	if ok, detail := classifyLdd([]byte("libfoo.so => not found\n"), nil); ok || !strings.Contains(detail, "not found") {
		t.Fatalf("unresolved case: ok=%v detail=%q", ok, detail)
	}
	if ok, detail := classifyLdd(nil, errors.New("chroot [/sysroot ldd /etc/foo.conf]: exit status 1 (stderr: not a dynamic executable)")); !ok || !strings.Contains(detail, "skipped") {
		t.Fatalf("non-ELF case should be skipped-as-pass: ok=%v detail=%q", ok, detail)
	}
	if ok, _ := classifyLdd(nil, errors.New("chroot [/sysroot ldd /no/such/file]: exit status 127")); ok {
		t.Fatal("an uncertain/unknown error must default to fail, never a silent pass")
	}
}

func TestCheckUnitActive(t *testing.T) {
	r := &mount.RecorderRunner{
		StubOutput: map[string][]byte{
			"systemctl is-active powernode-mod-123-nginx.service": []byte("active\n"),
		},
	}
	result := checkUnitActive(context.Background(), r, "mod-123", []string{"nginx"})
	if !result.OK || result.Name != "unit_active" {
		t.Fatalf("result: %+v", result)
	}
	if len(r.Invocations) != 1 || r.Invocations[0].Name != "systemctl" {
		t.Fatalf("invocations: %+v", r.Invocations)
	}

	// Vacuous pass with no services declared — no shell-out at all.
	r2 := &mount.RecorderRunner{}
	vacuous := checkUnitActive(context.Background(), r2, "mod-123", nil)
	if !vacuous.OK || len(r2.Invocations) != 0 {
		t.Fatalf("vacuous case: result=%+v invocations=%+v", vacuous, r2.Invocations)
	}

	// An inactive unit fails the aggregate.
	r3 := &mount.RecorderRunner{
		StubErr: map[string]error{
			"systemctl is-active powernode-mod-123-nginx.service": errors.New("exit status 3"),
		},
	}
	failing := checkUnitActive(context.Background(), r3, "mod-123", []string{"nginx"})
	if failing.OK {
		t.Fatalf("expected failing aggregate, got: %+v", failing)
	}
}

func TestCheckHealthEndpoint(t *testing.T) {
	r := &mount.RecorderRunner{
		StubOutput: map[string][]byte{
			"curl -sS -m 5 -o /dev/null -w %{http_code} -X GET http://127.0.0.1:8080/healthz": []byte("200"),
		},
	}
	checks := []healthCheckOption{{Service: "nginx", Endpoint: "http://127.0.0.1:8080/healthz", Method: "GET"}}
	result := checkHealthEndpoint(context.Background(), r, checks, defaultHealthCheckTimeoutSeconds)
	if !result.OK || result.Name != "health_endpoint" {
		t.Fatalf("result: %+v", result)
	}

	// Default method (empty Method -> GET) constructs the same command.
	r2 := &mount.RecorderRunner{
		StubOutput: map[string][]byte{
			"curl -sS -m 5 -o /dev/null -w %{http_code} -X GET http://127.0.0.1:8080/healthz": []byte("503"),
		},
	}
	failing := checkHealthEndpoint(context.Background(), r2, []healthCheckOption{{Endpoint: "http://127.0.0.1:8080/healthz"}}, defaultHealthCheckTimeoutSeconds)
	if failing.OK {
		t.Fatalf("503 should fail the check: %+v", failing)
	}

	// Vacuous pass with no health checks declared.
	r3 := &mount.RecorderRunner{}
	vacuous := checkHealthEndpoint(context.Background(), r3, nil, defaultHealthCheckTimeoutSeconds)
	if !vacuous.OK || len(r3.Invocations) != 0 {
		t.Fatalf("vacuous case: result=%+v invocations=%+v", vacuous, r3.Invocations)
	}
}

func TestCheckLddClosure(t *testing.T) {
	r := &mount.RecorderRunner{
		StubOutput: map[string][]byte{
			"chroot /sysroot ldd /usr/sbin/nginx": []byte("libc.so.6 => /lib/libc.so.6 (0x1234)\n"),
		},
	}
	result := checkLddClosure(context.Background(), r, []string{"/usr/sbin/nginx"})
	if !result.OK || result.Name != "ldd_closure" {
		t.Fatalf("result: %+v", result)
	}
	if len(r.Invocations) != 1 || r.Invocations[0].Name != "chroot" {
		t.Fatalf("invocations: %+v", r.Invocations)
	}

	// Unresolved dependency fails the aggregate.
	r2 := &mount.RecorderRunner{
		StubOutput: map[string][]byte{
			"chroot /sysroot ldd /usr/sbin/nginx": []byte("libfoo.so.1 => not found\n"),
		},
	}
	failing := checkLddClosure(context.Background(), r2, []string{"/usr/sbin/nginx"})
	if failing.OK {
		t.Fatalf("expected failing aggregate: %+v", failing)
	}

	// Vacuous pass with no ELF candidates declared.
	r3 := &mount.RecorderRunner{}
	vacuous := checkLddClosure(context.Background(), r3, nil)
	if !vacuous.OK || len(r3.Invocations) != 0 {
		t.Fatalf("vacuous case: result=%+v invocations=%+v", vacuous, r3.Invocations)
	}
}

func TestProbeModuleSmokeHandler_Execute_Success(t *testing.T) {
	r := &mount.RecorderRunner{
		StubOutput: map[string][]byte{
			"systemctl is-active powernode-mod-123-nginx.service":                             []byte("active\n"),
			"curl -sS -m 5 -o /dev/null -w %{http_code} -X GET http://127.0.0.1:8080/healthz": []byte("200"),
			"chroot /sysroot ldd /usr/sbin/nginx":                                             []byte("libc.so.6 => /lib/libc.so.6 (0x1234)\n"),
		},
	}
	h := &ProbeModuleSmokeHandler{deps: tasks.Dependencies{MountRunner: r}}

	task := &tasks.Task{ID: "t1", Command: "probe.module_smoke", Options: validProbeOptions()}
	result, err := h.Execute(context.Background(), task)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result["ok"] != true {
		t.Fatalf("result ok: %+v", result)
	}
	checks, ok := result["checks"].([]moduleSmokeCheckResult)
	if !ok || len(checks) != 3 {
		t.Fatalf("checks: %+v (%T)", result["checks"], result["checks"])
	}
	names := []string{checks[0].Name, checks[1].Name, checks[2].Name}
	want := []string{"unit_active", "health_endpoint", "ldd_closure"}
	for i := range want {
		if names[i] != want[i] {
			t.Fatalf("checks order: %+v", names)
		}
		if !checks[i].OK {
			t.Fatalf("check %s should pass: %+v", names[i], checks[i])
		}
	}
}

func TestProbeModuleSmokeHandler_Execute_ChecksFilter(t *testing.T) {
	r := &mount.RecorderRunner{
		StubOutput: map[string][]byte{
			"curl -sS -m 5 -o /dev/null -w %{http_code} -X GET http://127.0.0.1:8080/healthz": []byte("200"),
		},
	}
	h := &ProbeModuleSmokeHandler{deps: tasks.Dependencies{MountRunner: r}}

	opts := validProbeOptions()
	opts["checks"] = []string{"health_endpoint"}
	task := &tasks.Task{Options: opts}
	result, err := h.Execute(context.Background(), task)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	checks := result["checks"].([]moduleSmokeCheckResult)
	if len(checks) != 1 || checks[0].Name != "health_endpoint" {
		t.Fatalf("checks: %+v", checks)
	}
	// The filtered-out checks (unit_active, ldd_closure) must not shell out at all.
	if len(r.Invocations) != 1 {
		t.Fatalf("expected exactly one invocation, got: %+v", r.Invocations)
	}
}

func TestProbeModuleSmokeHandler_Execute_FailingCheckIsNotAHandlerError(t *testing.T) {
	r := &mount.RecorderRunner{
		StubOutput: map[string][]byte{
			"systemctl is-active powernode-mod-123-nginx.service":                             []byte("active\n"),
			"curl -sS -m 5 -o /dev/null -w %{http_code} -X GET http://127.0.0.1:8080/healthz": []byte("503"),
			"chroot /sysroot ldd /usr/sbin/nginx":                                             []byte("libc.so.6 => /lib/libc.so.6 (0x1234)\n"),
		},
	}
	h := &ProbeModuleSmokeHandler{deps: tasks.Dependencies{MountRunner: r}}

	task := &tasks.Task{Options: validProbeOptions()}
	result, err := h.Execute(context.Background(), task)
	// A failing health check is an honest report, not an execution failure —
	// the task must still complete (never fail) so the platform sees the
	// structured checks array.
	if err != nil {
		t.Fatalf("a failing check must not error the task, got: %v", err)
	}
	if result["ok"] != false {
		t.Fatalf("result ok should be false: %+v", result)
	}
}

func TestProbeModuleSmokeHandler_Execute_MissingOptions(t *testing.T) {
	r := &mount.RecorderRunner{}
	h := &ProbeModuleSmokeHandler{deps: tasks.Dependencies{MountRunner: r}}

	_, err := h.Execute(context.Background(), &tasks.Task{Options: map[string]any{"module": "nginx"}})
	if err == nil {
		t.Fatal("expected error for missing module_id")
	}
	if len(r.Invocations) != 0 {
		t.Fatalf("mount runner must not be called before options validate, invocations: %+v", r.Invocations)
	}
}

func TestProbeModuleSmokeHandler_Execute_NoMountRunner(t *testing.T) {
	h := &ProbeModuleSmokeHandler{}
	_, err := h.Execute(context.Background(), &tasks.Task{Options: validProbeOptions()})
	if err == nil {
		t.Fatal("expected error when MountRunner is nil")
	}
}
