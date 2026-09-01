package handlers

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"strings"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/runtime/tasks"
	"github.com/nodealchemy/powernode-system/agent/internal/taskguard"
)

// sysrootPath is where the agent's composed module union lives — see
// mount.DefaultLayout().SysRoot (agent/internal/mount/layout.go). Hardcoded
// (not threaded through tasks.Dependencies) because every other
// RootDirectory=/sysroot reference in this codebase (service unit
// rendering, boot pivot) treats it as the fixed canonical path, never a
// per-node override.
const sysrootPath = "/sysroot"

// defaultHealthCheckTimeoutSeconds bounds each curl call — a health
// endpoint check should be near-instant; a hung endpoint must not block
// the whole probe. Overridable per-task via
// options.health_check_timeout_seconds.
const defaultHealthCheckTimeoutSeconds = 5

// probeModuleSmokeChecks is the full, ordered set of health checks
// probe.module_smoke can run — MUST mirror System::ModuleSmokeProbe::CHECKS
// (extensions/system/server/app/services/system/module_smoke_probe.rb)
// exactly: same three names, same order, so a completed task's checks
// array lines up with what the platform expects to parse.
var probeModuleSmokeChecks = []string{"unit_active", "health_endpoint", "ldd_closure"}

// ProbeModuleSmokeHandler runs campaign 019f6084 inc-E's structured smoke
// checks against a freshly-composed module on THIS instance — the agent
// side of System::ModuleSmokeProbe's dispatch/poll (mirrors
// ci.module_build's dispatch/poll shape; see that handler's doc). Every
// check shells out through the SAME mount.Runner exec substrate ssh.go
// uses (systemctl, curl, chroot+ldd) — no new remote-exec channel.
//
// System::ModuleSmokeProbe computes every concrete input SERVER-SIDE
// (service names + health endpoints straight from system_module_services
// rows; ldd candidates from the module's own file_spec, filtered to
// non-glob concrete paths — see that class's doc for why glob-pattern
// file_spec entries are out of scope for this increment) and threads it
// all through task.Options, exactly like
// System::NativeModuleBuildOrchestrator#package_task_options does for
// ci.package_build: this handler has no independent knowledge of "the
// module" beyond what's in options — it never reads a local manifest
// cache or walks the mounted layer itself. That keeps every side effect
// behind the ONE mockable Runner interface, same as every other handler
// in this package.
//
// A failing check is a HONEST RESULT, not a handler error: Execute only
// returns an error when the task itself can't be attempted (bad options,
// no mount runner). Once the probe runs, the task completes with
// ok:false and the failing check's detail — mirrors the parked stub's
// "well-formed, honestly-failing report" philosophy (see
// System::ModuleSmokeProbe's pre-wiring doc).
type ProbeModuleSmokeHandler struct {
	deps tasks.Dependencies
}

// RegisterProbeModuleSmoke binds the probe.module_smoke command.
func RegisterProbeModuleSmoke(r *tasks.Registry, deps tasks.Dependencies) {
	r.Register("probe.module_smoke", &ProbeModuleSmokeHandler{deps: deps})
}

// moduleSmokeCheckResult is one entry of the task's "checks" result array —
// shaped so System::ModuleSmokeProbe can map it straight onto its
// CheckResult struct (name/pass/detail; "ok" here becomes "pass" there —
// the JSON key doesn't need to match 1:1, the Ruby wiring translates it).
type moduleSmokeCheckResult struct {
	Name   string `json:"name"`
	OK     bool   `json:"ok"`
	Detail string `json:"detail"`
}

// healthCheckOption is one options.health_checks[] entry.
type healthCheckOption struct {
	Service  string
	Endpoint string
	Method   string
}

// probeModuleSmokeOptions is the parsed, validated view of task.Options for
// a probe.module_smoke task — computed server-side by
// System::ModuleSmokeProbe#dispatch_task! (never by a human).
type probeModuleSmokeOptions struct {
	Module                    string
	ModuleID                  string
	BaseOS                    string
	Checks                    []string
	Services                  []string
	HealthChecks              []healthCheckOption
	ElfCandidates             []string
	HealthCheckTimeoutSeconds int
}

// parseProbeModuleSmokeOptions validates task.Options. Pure (no I/O) so the
// validation logic is unit-testable without a mount runner — mirrors
// parseModuleBuildOptions / parsePackageBuildOptions.
//
// This is the SINGLE validation seam for probe.module_smoke, and it is where
// the ARGUMENTS get bounded, not just the check names. The three checks are
// allow-listed by name (probeModuleSmokeChecks) but each one shells out with a
// payload-supplied argument: curl takes the endpoint and the method, chroot+ldd
// takes the ELF path, systemctl takes a unit name built from module_id and a
// service name. The verb is auto_approve precisely because those primitives are
// read-only and cannot be extended by payload — which only holds while the
// arguments are bounded. The rules come from package taskguard; see its doc for
// why the agent, not the control plane, is where they have to be true.
func parseProbeModuleSmokeOptions(task *tasks.Task) (probeModuleSmokeOptions, error) {
	str := func(key string) string {
		v, _ := task.Options[key].(string)
		return v
	}

	opts := probeModuleSmokeOptions{
		Module:                    str("module"),
		ModuleID:                  str("module_id"),
		BaseOS:                    str("base_os"),
		Services:                  toStringSlice(task.Options["services"]),
		ElfCandidates:             toStringSlice(task.Options["elf_candidates"]),
		HealthCheckTimeoutSeconds: toInt(task.Options["health_check_timeout_seconds"], defaultHealthCheckTimeoutSeconds),
	}

	if opts.Module == "" {
		return probeModuleSmokeOptions{}, errors.New("probe.module_smoke: options.module is required")
	}
	if opts.ModuleID == "" {
		return probeModuleSmokeOptions{}, errors.New("probe.module_smoke: options.module_id is required")
	}
	// module_id and every service name are concatenated into the unit name
	// handed to `systemctl is-active`; a value carrying a space or a leading
	// dash stops being one argv element naming one unit.
	if err := taskguard.Identifier("module_id", opts.ModuleID); err != nil {
		return probeModuleSmokeOptions{}, err
	}
	for i, svc := range opts.Services {
		if err := taskguard.Identifier(fmt.Sprintf("services[%d]", i), svc); err != nil {
			return probeModuleSmokeOptions{}, err
		}
	}
	// Each candidate becomes the argument of `chroot /sysroot ldd <path>`. It
	// must be an absolute, canonical path inside the union — a leading dash
	// would be read by ldd as an option instead.
	for i, p := range opts.ElfCandidates {
		if err := taskguard.AbsPath(fmt.Sprintf("elf_candidates[%d]", i), p); err != nil {
			return probeModuleSmokeOptions{}, err
		}
	}
	if opts.HealthCheckTimeoutSeconds <= 0 {
		// Absent or zero would become `curl -m 0`, which disables the timeout
		// and lets one hung endpoint stall the whole probe.
		return probeModuleSmokeOptions{}, fmt.Errorf(
			"probe.module_smoke: %w: health_check_timeout_seconds: must be positive", taskguard.ErrRefused)
	}

	checks := toStringSlice(task.Options["checks"])
	if len(checks) == 0 {
		checks = append([]string(nil), probeModuleSmokeChecks...)
	}
	for _, c := range checks {
		if !containsString(probeModuleSmokeChecks, c) {
			return probeModuleSmokeOptions{}, fmt.Errorf("probe.module_smoke: unknown check %q", c)
		}
	}
	opts.Checks = checks

	healthChecks, err := toHealthChecks(task.Options["health_checks"])
	if err != nil {
		return probeModuleSmokeOptions{}, err
	}
	opts.HealthChecks = healthChecks

	return opts, nil
}

func (h *ProbeModuleSmokeHandler) Execute(ctx context.Context, task *tasks.Task) (tasks.Result, error) {
	opts, err := parseProbeModuleSmokeOptions(task)
	if err != nil {
		return nil, err
	}
	if h.deps.MountRunner == nil {
		return nil, errors.New("probe.module_smoke: no mount runner")
	}
	runner := h.deps.MountRunner

	results := make([]moduleSmokeCheckResult, 0, len(opts.Checks))
	for _, name := range probeModuleSmokeChecks { // canonical order, regardless of options.checks order
		if !containsString(opts.Checks, name) {
			continue
		}
		switch name {
		case "unit_active":
			results = append(results, checkUnitActive(ctx, runner, opts.ModuleID, opts.Services))
		case "health_endpoint":
			results = append(results, checkHealthEndpoint(ctx, runner, opts.HealthChecks, opts.HealthCheckTimeoutSeconds))
		case "ldd_closure":
			results = append(results, checkLddClosure(ctx, runner, opts.ElfCandidates))
		}
	}

	ok := true
	for _, r := range results {
		if !r.OK {
			ok = false
			break
		}
	}

	return tasks.Result{
		"module":  opts.Module,
		"base_os": opts.BaseOS,
		"ok":      ok,
		"checks":  results,
	}, nil
}

// checkUnitActive runs `systemctl is-active <unit>` for every declared
// service, one unit per service, named exactly the way the agent's own
// internal/lifecycle package names them at attach time: see
// manifest.Manifest.UnitNames ("powernode-"+moduleID+"-"+serviceName+
// ".service"). Vacuously passes when no services are declared (a
// config-variety module may ship none).
func checkUnitActive(ctx context.Context, runner mount.Runner, moduleID string, services []string) moduleSmokeCheckResult {
	if len(services) == 0 {
		return moduleSmokeCheckResult{Name: "unit_active", OK: true, Detail: "no services declared"}
	}

	ok := true
	parts := make([]string, 0, len(services))
	for _, svc := range services {
		unit := "powernode-" + moduleID + "-" + svc + ".service"
		out, err := runner.Output(ctx, "systemctl", "is-active", unit)
		unitOK, detail := classifyUnitActive(out, err)
		if !unitOK {
			ok = false
		}
		parts = append(parts, unit+"="+detail)
	}
	return moduleSmokeCheckResult{Name: "unit_active", OK: ok, Detail: strings.Join(parts, "; ")}
}

// classifyUnitActive trusts the exit code, not stdout parsing: `systemctl
// is-active` exits 0 IFF the unit is active, and mount.Runner.Output
// deliberately drops stdout on any non-zero exit (see runner.go) — so a
// non-nil err is itself the authoritative "not active" signal, carrying
// systemctl's own status word (active/inactive/failed/unknown) via
// stderr in the wrapped error text.
func classifyUnitActive(out []byte, err error) (ok bool, detail string) {
	if err != nil {
		return false, err.Error()
	}
	status := strings.TrimSpace(string(out))
	if status == "" {
		status = "active"
	}
	return true, status
}

// checkHealthEndpoint curls each declared health endpoint from the HOST
// network namespace (RootDirectory=/sysroot chroots the filesystem view a
// service sees, not its network namespace, so a loopback/service port
// bound inside the chroot is still directly reachable here — no chroot
// needed for this check). Vacuously passes when no health endpoints are
// declared.
func checkHealthEndpoint(ctx context.Context, runner mount.Runner, checks []healthCheckOption, timeoutSeconds int) moduleSmokeCheckResult {
	if len(checks) == 0 {
		return moduleSmokeCheckResult{Name: "health_endpoint", OK: true, Detail: "no health endpoints declared"}
	}

	ok := true
	parts := make([]string, 0, len(checks))
	for _, c := range checks {
		method := c.Method
		if method == "" {
			method = "GET"
		}
		out, err := runner.Output(ctx, "curl",
			"-sS", "-m", strconv.Itoa(timeoutSeconds), "-o", "/dev/null", "-w", "%{http_code}", "-X", method, c.Endpoint)
		checkOK, detail := classifyHealthCheck(out, err)
		if !checkOK {
			ok = false
		}
		label := c.Service
		if label == "" {
			label = c.Endpoint
		}
		parts = append(parts, label+"="+detail)
	}
	return moduleSmokeCheckResult{Name: "health_endpoint", OK: ok, Detail: strings.Join(parts, "; ")}
}

func classifyHealthCheck(out []byte, err error) (ok bool, detail string) {
	if err != nil {
		return false, err.Error()
	}
	trimmed := strings.TrimSpace(string(out))
	code, convErr := strconv.Atoi(trimmed)
	if convErr != nil {
		return false, fmt.Sprintf("unparseable http status %q", trimmed)
	}
	ok = code >= 200 && code < 400
	return ok, fmt.Sprintf("http_status=%d", code)
}

// checkLddClosure runs `chroot /sysroot ldd <path>` for each declared
// candidate — chrooted (unlike the other two checks) because a binary's
// shared-library search resolves against the COMPOSED UNION at /sysroot
// (which may include libs shipped by OTHER modules in the stack), not
// whatever root the agent process itself is running under. Vacuously
// passes when no candidates are declared.
func checkLddClosure(ctx context.Context, runner mount.Runner, paths []string) moduleSmokeCheckResult {
	if len(paths) == 0 {
		return moduleSmokeCheckResult{Name: "ldd_closure", OK: true, Detail: "no ELF candidates declared"}
	}

	ok := true
	parts := make([]string, 0, len(paths))
	for _, p := range paths {
		out, err := runner.Output(ctx, "chroot", sysrootPath, "ldd", p)
		pathOK, detail := classifyLdd(out, err)
		if !pathOK {
			ok = false
		}
		parts = append(parts, p+"="+detail)
	}
	return moduleSmokeCheckResult{Name: "ldd_closure", OK: ok, Detail: strings.Join(parts, "; ")}
}

// classifyLdd distinguishes three outcomes:
//   - a real unresolved dependency ("not found" in ldd's stdout) → fail
//   - the target isn't a dynamic executable at all (a data file or
//     static binary innocently swept up in file_spec) → not a failure,
//     it has no closure to be incomplete
//   - clean resolution → pass
//
// Anything else uncertain (chroot itself failing, path missing, ldd
// erroring for an unrecognized reason) defaults to fail — a probe that
// can't confirm health must never report a false pass.
func classifyLdd(out []byte, err error) (ok bool, detail string) {
	if err != nil {
		msg := err.Error()
		if strings.Contains(msg, "not a dynamic executable") {
			return true, "skipped: not a dynamic executable"
		}
		return false, msg
	}
	text := string(out)
	if strings.Contains(text, "not found") {
		return false, strings.TrimSpace(text)
	}
	return true, "resolved"
}

// === Options parsing helpers ===

// toStringSlice accepts either a real JSON-decoded []interface{} (the
// runtime shape — task.Options comes from json.Unmarshal) or a Go-native
// []string (the shape tests conveniently construct literals with).
// Non-string elements are skipped rather than erroring — an options blob
// the platform built server-side is trusted; a stray malformed element
// shouldn't sink the whole check.
func toStringSlice(v any) []string {
	switch vv := v.(type) {
	case nil:
		return nil
	case []string:
		return append([]string(nil), vv...)
	case []any:
		out := make([]string, 0, len(vv))
		for _, e := range vv {
			if s, ok := e.(string); ok {
				out = append(out, s)
			}
		}
		return out
	default:
		return nil
	}
}

// toInt accepts a JSON-decoded float64, a Go-native int, or nil (falling
// back to def).
func toInt(v any, def int) int {
	switch vv := v.(type) {
	case float64:
		return int(vv)
	case int:
		return vv
	default:
		return def
	}
}

// toHealthChecks accepts either the runtime []interface{} of
// map[string]interface{} (real JSON decode) or the []map[string]any shape
// tests construct directly. Each entry requires a non-empty "endpoint";
// "service" and "method" are optional labels/overrides.
func toHealthChecks(v any) ([]healthCheckOption, error) {
	entries, err := toMapSlice(v)
	if err != nil {
		return nil, err
	}
	out := make([]healthCheckOption, 0, len(entries))
	for i, e := range entries {
		endpoint, _ := e["endpoint"].(string)
		if endpoint == "" {
			return nil, fmt.Errorf("probe.module_smoke: health_checks[%d].endpoint is required", i)
		}
		if err := taskguard.HTTPEndpoint(fmt.Sprintf("health_checks[%d].endpoint", i), endpoint); err != nil {
			return nil, err
		}
		service, _ := e["service"].(string)
		method, _ := e["method"].(string)
		if method != "" {
			if err := taskguard.HTTPMethod(fmt.Sprintf("health_checks[%d].method", i), method); err != nil {
				return nil, err
			}
		}
		if service != "" {
			if err := taskguard.Identifier(fmt.Sprintf("health_checks[%d].service", i), service); err != nil {
				return nil, err
			}
		}
		out = append(out, healthCheckOption{Service: service, Endpoint: endpoint, Method: method})
	}
	return out, nil
}

func toMapSlice(v any) ([]map[string]any, error) {
	switch vv := v.(type) {
	case nil:
		return nil, nil
	case []map[string]any:
		return vv, nil
	case []any:
		out := make([]map[string]any, 0, len(vv))
		for i, e := range vv {
			m, ok := e.(map[string]any)
			if !ok {
				return nil, fmt.Errorf("probe.module_smoke: health_checks[%d] is not an object", i)
			}
			out = append(out, m)
		}
		return out, nil
	default:
		return nil, errors.New("probe.module_smoke: health_checks must be an array")
	}
}

func containsString(haystack []string, needle string) bool {
	for _, s := range haystack {
		if s == needle {
			return true
		}
	}
	return false
}
