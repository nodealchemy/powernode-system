package handlers

import (
	"context"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/runtime/tasks"
)

// probe.module_smoke allow-lists the CHECK NAMES but not their ARGUMENTS, and
// the verb is auto_approve. These tests are the refusal oracle for the
// arguments: each fixture is a value that ESCAPES the intended shape (an argv
// element that curl or ldd would read as an option, a non-HTTP scheme), not a
// merely odd string. The assertion is that the runner is never asked to
// execute anything — a handler that runs the command and then reports a failed
// check has still made the request.

func probeGuardRunner() *mount.RecorderRunner { return &mount.RecorderRunner{} }

func runProbe(t *testing.T, rec *mount.RecorderRunner, opts map[string]any) error {
	t.Helper()
	h := &ProbeModuleSmokeHandler{deps: tasks.Dependencies{MountRunner: rec}}
	_, err := h.Execute(context.Background(), &tasks.Task{Command: "probe.module_smoke", Options: opts})
	return err
}

func TestProbeRefusesFlagLikeHealthEndpoint(t *testing.T) {
	opts := validProbeOptions()
	// curl reads a leading-dash argv element as an option, not a URL — the
	// endpoint is the LAST argument, so it lands in curl's option parser.
	opts["health_checks"] = []map[string]any{{"service": "nginx", "endpoint": "-ZZ-not-a-url"}}

	rec := probeGuardRunner()
	if err := runProbe(t, rec, opts); err == nil {
		t.Fatal("expected probe.module_smoke to refuse a flag-like health endpoint")
	}
	if len(rec.Invocations) != 0 {
		t.Fatalf("expected curl never to run, got %+v", rec.Invocations)
	}
}

func TestProbeRefusesNonHTTPHealthEndpointScheme(t *testing.T) {
	opts := validProbeOptions()
	opts["health_checks"] = []map[string]any{{"service": "nginx", "endpoint": "file:///etc/shadow"}}

	rec := probeGuardRunner()
	if err := runProbe(t, rec, opts); err == nil {
		t.Fatal("expected probe.module_smoke to refuse a non-http(s) health endpoint")
	}
	if len(rec.Invocations) != 0 {
		t.Fatalf("expected curl never to run, got %+v", rec.Invocations)
	}
}

func TestProbeRefusesArbitraryHTTPMethod(t *testing.T) {
	opts := validProbeOptions()
	opts["health_checks"] = []map[string]any{
		{"service": "nginx", "endpoint": "http://127.0.0.1:8080/healthz", "method": "ZZDESTROY"},
	}

	rec := probeGuardRunner()
	if err := runProbe(t, rec, opts); err == nil {
		t.Fatal("expected probe.module_smoke to refuse an HTTP method outside the allow-list")
	}
	if len(rec.Invocations) != 0 {
		t.Fatalf("expected curl never to run, got %+v", rec.Invocations)
	}
}

func TestProbeRefusesFlagLikeElfCandidate(t *testing.T) {
	opts := validProbeOptions()
	opts["elf_candidates"] = []string{"--zz-option"}

	rec := probeGuardRunner()
	if err := runProbe(t, rec, opts); err == nil {
		t.Fatal("expected probe.module_smoke to refuse a flag-like ELF candidate")
	}
	if len(rec.Invocations) != 0 {
		t.Fatalf("expected chroot/ldd never to run, got %+v", rec.Invocations)
	}
}

func TestProbeRefusesRelativeElfCandidate(t *testing.T) {
	opts := validProbeOptions()
	// Resolved inside `chroot /sysroot`, so a relative path resolves against
	// the agent's own working directory expectations rather than the union.
	opts["elf_candidates"] = []string{"../../usr/sbin/nginx"}

	rec := probeGuardRunner()
	if err := runProbe(t, rec, opts); err == nil {
		t.Fatal("expected probe.module_smoke to refuse a non-absolute ELF candidate")
	}
	if len(rec.Invocations) != 0 {
		t.Fatalf("expected chroot/ldd never to run, got %+v", rec.Invocations)
	}
}

func TestProbeRefusesServiceNameThatIsNotAUnitComponent(t *testing.T) {
	opts := validProbeOptions()
	// Concatenated into "powernode-<moduleID>-<svc>.service" and handed to
	// systemctl; a leading dash makes the whole thing an option.
	opts["services"] = []string{"nginx --zz"}

	rec := probeGuardRunner()
	if err := runProbe(t, rec, opts); err == nil {
		t.Fatal("expected probe.module_smoke to refuse a service name that is not a unit component")
	}
	if len(rec.Invocations) != 0 {
		t.Fatalf("expected systemctl never to run, got %+v", rec.Invocations)
	}
}

func TestProbeRefusesZeroHealthCheckTimeout(t *testing.T) {
	opts := validProbeOptions()
	// An explicit 0 becomes `curl -m 0`, which DISABLES the timeout rather
	// than tightening it, so one hung endpoint stalls the whole probe. The
	// absent case is different and stays legal — see the next test.
	opts["health_check_timeout_seconds"] = float64(0)

	rec := probeGuardRunner()
	if err := runProbe(t, rec, opts); err == nil {
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

func TestProbeAcceptsLegitimateOptions(t *testing.T) {
	rec := probeGuardRunner()
	if err := runProbe(t, rec, validProbeOptions()); err != nil {
		t.Fatalf("legitimate probe options were refused: %v", err)
	}
	if len(rec.Invocations) == 0 {
		t.Fatal("expected the probe to actually run its checks for legitimate options")
	}
}
