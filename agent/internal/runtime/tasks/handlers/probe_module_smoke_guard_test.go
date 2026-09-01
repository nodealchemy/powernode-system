package handlers

import (
	"context"
	"strings"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/runtime/tasks"
)

// probe.module_smoke allow-lists the CHECK NAMES but not their ARGUMENTS, and
// the verb is auto_approve. These tests are the refusal oracle for the
// arguments.
//
// The oracle has TWO halves, and both matter. A refused argument must (a) stop
// the command from ever being executed, and (b) fail only ITS OWN check — the
// handler's stated contract is that a failing check is an honest result, not a
// task error, so refusing at parse time would abort the sibling checks too and
// turn a partial-signal probe into a no-signal one.

func probeGuardRunner() *mount.RecorderRunner { return &mount.RecorderRunner{} }

// runProbeChecks executes the handler and returns the per-check results.
func runProbeChecks(t *testing.T, rec *mount.RecorderRunner, opts map[string]any) []moduleSmokeCheckResult {
	t.Helper()
	h := &ProbeModuleSmokeHandler{deps: tasks.Dependencies{MountRunner: rec}}
	res, err := h.Execute(context.Background(), &tasks.Task{Command: "probe.module_smoke", Options: opts})
	if err != nil {
		t.Fatalf("probe returned a TASK error; a bad argument must fail its own check instead: %v", err)
	}
	checks, ok := res["checks"].([]moduleSmokeCheckResult)
	if !ok {
		t.Fatalf("result carried no checks array: %+v", res)
	}
	return checks
}

func checkNamed(t *testing.T, checks []moduleSmokeCheckResult, name string) moduleSmokeCheckResult {
	t.Helper()
	for _, c := range checks {
		if c.Name == name {
			return c
		}
	}
	t.Fatalf("no check named %q in %+v", name, checks)
	return moduleSmokeCheckResult{}
}

// assertRefusedCheck pins both halves: the named check failed, the sibling
// checks still ran, and the runner was never asked to execute the command.
func assertRefusedCheck(t *testing.T, rec *mount.RecorderRunner, checks []moduleSmokeCheckResult, name, forbiddenCmd string) {
	t.Helper()
	c := checkNamed(t, checks, name)
	if c.OK {
		t.Fatalf("expected check %q to fail on a refused argument, got %+v", name, c)
	}
	if !strings.Contains(c.Detail, "refused") {
		t.Fatalf("expected the refusal in check %q's detail, got %q", name, c.Detail)
	}
	for _, inv := range rec.Invocations {
		if inv.Name == forbiddenCmd {
			t.Fatalf("expected %s never to run, got %+v", forbiddenCmd, rec.Invocations)
		}
	}
	if len(checks) != len(probeModuleSmokeChecks) {
		t.Fatalf("a refused argument aborted sibling checks: got %d of %d", len(checks), len(probeModuleSmokeChecks))
	}
}

func TestProbeRefusesFlagLikeHealthEndpoint(t *testing.T) {
	opts := validProbeOptions()
	// curl reads a leading-dash argv element as an option, not a URL.
	opts["health_checks"] = []map[string]any{{"service": "nginx", "endpoint": "-ZZ-not-a-url"}}

	rec := probeGuardRunner()
	assertRefusedCheck(t, rec, runProbeChecks(t, rec, opts), "health_endpoint", "curl")
}

func TestProbeRefusesNonHTTPHealthEndpointScheme(t *testing.T) {
	opts := validProbeOptions()
	opts["health_checks"] = []map[string]any{{"service": "nginx", "endpoint": "file:///etc/shadow"}}

	rec := probeGuardRunner()
	assertRefusedCheck(t, rec, runProbeChecks(t, rec, opts), "health_endpoint", "curl")
}

func TestProbeRefusesArbitraryHTTPMethod(t *testing.T) {
	opts := validProbeOptions()
	opts["health_checks"] = []map[string]any{
		{"service": "nginx", "endpoint": "http://127.0.0.1:8080/healthz", "method": "ZZDESTROY"},
	}

	rec := probeGuardRunner()
	assertRefusedCheck(t, rec, runProbeChecks(t, rec, opts), "health_endpoint", "curl")
}

func TestProbeRefusesFlagLikeElfCandidate(t *testing.T) {
	opts := validProbeOptions()
	opts["elf_candidates"] = []string{"--zz-option"}

	rec := probeGuardRunner()
	assertRefusedCheck(t, rec, runProbeChecks(t, rec, opts), "ldd_closure", "chroot")
}

func TestProbeRefusesRelativeElfCandidate(t *testing.T) {
	opts := validProbeOptions()
	opts["elf_candidates"] = []string{"../../usr/sbin/nginx"}

	rec := probeGuardRunner()
	assertRefusedCheck(t, rec, runProbeChecks(t, rec, opts), "ldd_closure", "chroot")
}

func TestProbeRefusesServiceNameThatIsNotAUnitComponent(t *testing.T) {
	opts := validProbeOptions()
	// Concatenated into "powernode-<moduleID>-<svc>.service" for systemctl.
	opts["services"] = []string{"nginx --zz"}

	rec := probeGuardRunner()
	assertRefusedCheck(t, rec, runProbeChecks(t, rec, opts), "unit_active", "systemctl")
}

// module_id is different: it is concatenated into EVERY unit name, so a bad
// one is a malformed task rather than one failed check.
func TestProbeRefusesBadModuleIDAsATaskError(t *testing.T) {
	opts := validProbeOptions()
	opts["module_id"] = "mod 123; rm"

	rec := probeGuardRunner()
	h := &ProbeModuleSmokeHandler{deps: tasks.Dependencies{MountRunner: rec}}
	if _, err := h.Execute(context.Background(), &tasks.Task{Options: opts}); err == nil {
		t.Fatal("expected a task error for a malformed module_id")
	}
	if len(rec.Invocations) != 0 {
		t.Fatalf("expected nothing to run, got %+v", rec.Invocations)
	}
}

func TestProbeRefusesZeroHealthCheckTimeout(t *testing.T) {
	opts := validProbeOptions()
	// An explicit 0 becomes `curl -m 0`, which DISABLES the timeout rather
	// than tightening it. The absent case is different and stays legal.
	opts["health_check_timeout_seconds"] = float64(0)

	rec := probeGuardRunner()
	h := &ProbeModuleSmokeHandler{deps: tasks.Dependencies{MountRunner: rec}}
	if _, err := h.Execute(context.Background(), &tasks.Task{Options: opts}); err == nil {
		t.Fatal("expected probe.module_smoke to refuse a zero health-check timeout")
	}
	if len(rec.Invocations) != 0 {
		t.Fatalf("expected curl never to run, got %+v", rec.Invocations)
	}
}

func TestProbeAcceptsAbsentHealthCheckTimeout(t *testing.T) {
	opts := validProbeOptions()
	delete(opts, "health_check_timeout_seconds")

	parsed, err := parseProbeModuleSmokeOptions(&tasks.Task{Options: opts})
	if err != nil {
		t.Fatalf("absent health_check_timeout_seconds was refused: %v", err)
	}
	if parsed.HealthCheckTimeoutSeconds != defaultHealthCheckTimeoutSeconds {
		t.Fatalf("expected the default timeout, got %d", parsed.HealthCheckTimeoutSeconds)
	}
}

// --- The producer-contract half of the oracle --------------------------------
//
// These are the values System::ModuleSmokeProbe actually sends, taken from the
// shipped manifests and from System::ModuleService's own validations — NOT
// invented alongside the rule. Every one of them was refused by an earlier
// revision of this file, which is exactly the failure a rule-only oracle
// cannot see.

func TestProbeAcceptsShippedManifestHealthEndpoints(t *testing.T) {
	// extensions/system/modules/*/manifest.yaml: hub-backend "/up",
	// hub-worker + log-forwarder-vector "/health", node-exporter "/metrics",
	// reverse-proxy-traefik "/ping", hub-frontend "/".
	for _, endpoint := range []string{"/up", "/health", "/metrics", "/ping", "/"} {
		opts := validProbeOptions()
		opts["health_checks"] = []map[string]any{{"service": "svc", "endpoint": endpoint}}

		rec := probeGuardRunner()
		checks := runProbeChecks(t, rec, opts)
		if c := checkNamed(t, checks, "health_endpoint"); strings.Contains(c.Detail, "refused") {
			t.Fatalf("shipped manifest endpoint %q was refused: %s", endpoint, c.Detail)
		}
		var curled bool
		for _, inv := range rec.Invocations {
			if inv.Name == "curl" {
				curled = true
			}
		}
		if !curled {
			t.Fatalf("endpoint %q did not reach curl", endpoint)
		}
	}
}

func TestProbeAcceptsEveryPlatformHealthMethod(t *testing.T) {
	// System::ModuleService::HEALTH_METHODS = %w[GET POST PUT], and the column
	// is validated against exactly that set.
	for _, method := range []string{"GET", "POST", "PUT"} {
		opts := validProbeOptions()
		opts["health_checks"] = []map[string]any{
			{"service": "svc", "endpoint": "/up", "method": method},
		}
		rec := probeGuardRunner()
		if c := checkNamed(t, rec2checks(t, rec, opts), "health_endpoint"); strings.Contains(c.Detail, "refused") {
			t.Fatalf("platform health method %q was refused: %s", method, c.Detail)
		}
	}
}

func rec2checks(t *testing.T, rec *mount.RecorderRunner, opts map[string]any) []moduleSmokeCheckResult {
	t.Helper()
	return runProbeChecks(t, rec, opts)
}

func TestProbeAcceptsLegitimateOptions(t *testing.T) {
	rec := probeGuardRunner()
	checks := runProbeChecks(t, rec, validProbeOptions())
	for _, c := range checks {
		if strings.Contains(c.Detail, "refused") {
			t.Fatalf("legitimate probe options were refused: %+v", c)
		}
	}
	if len(rec.Invocations) == 0 {
		t.Fatal("expected the probe to actually run its checks for legitimate options")
	}
}
