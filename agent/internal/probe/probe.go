// Package probe runs a module's manifest-declared `verify:` probes on the
// node and reports what it found.
//
// IMP-3855ff9908f2. A deploy today proves the platform SERVED an artifact and
// the agent MOUNTED it. Neither answers the only question the deploy is for:
// is the capability the module exists to provide actually reachable here now?
// That answer exists on the node and nowhere else. This package computes it;
// runtime.buildHeartbeat ships it as `module_verify_state`; the platform's
// System::ModuleVerifyStateWriter persists it and
// System::Fleet::Sensors::ModuleVerifyFailedSensor raises a failure to an
// operator.
//
// # The two rules that are the whole point
//
// Both come from the settled design (docs/operations/autonomous-
// infrastructure-readiness-2026-08-12.md §2):
//
//  1. A probe asserts a RESOLVED PATH, never mere existence. `command -v foo`
//     answering ANYTHING is not evidence — the VM-9000 incident was a binary
//     that resolved fine, to the wrong file. So the probe compares the
//     resolved path against the manifest's `resolves_to` string, and the
//     manifest side (System::ModuleVerify) refuses to import a probe without
//     one.
//
//  2. Every probe runs in BOTH a login and a non-login shell. That incident
//     was precisely a DIVERGENCE between the two: a login shell sources
//     /etc/profile, /etc/profile.d/* and ~/.bash_profile, which is where a
//     PATH gets reordered, so the same name can resolve to two different
//     files depending on how you asked. A probe that ran one shell would
//     reproduce that bug rather than catch it. There is deliberately no way
//     to configure this — see Shells.
//
// A probe is PASSING only when both shells resolved to the declared path.
// Anything else — a mismatch, a failure to resolve, a shell that could not be
// run — is reported per shell as the fact it is. This package never emits a
// roll-up verdict: the server derives that, so that a report covering one
// shell can never be mistaken for a pass.
package probe

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"sort"
	"strings"
	"time"
)

// commandRx mirrors System::ModuleVerify::COMMAND_RX. Kept in lockstep with
// it deliberately: the server refuses to IMPORT anything else, and this is
// the agent's independent refusal to RUN anything else.
var commandRx = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$`)

// Shell names. These strings are the wire contract with the platform
// (System::ModuleVerify::REQUIRED_SHELLS) — the server drops a shell entry it
// does not recognize, and scores a probe missing either of these as NOT
// MEASURED rather than as passing.
const (
	ShellLogin    = "login"
	ShellNonLogin = "non_login"
)

// Shells is the fixed set every probe runs in. A var of a package-private
// type rather than a config field, deliberately: the login/non-login
// divergence IS the bug class this feature exists to catch, so "which shells"
// is not a per-module choice. Adding a shell here is a wire-contract change
// that must land on the server's REQUIRED_SHELLS at the same time.
var Shells = []string{ShellLogin, ShellNonLogin}

// Per-shell outcome statuses. Mirrors
// System::ModuleVerifyStateWriter::SHELL_STATUSES; anything else the server
// coerces to "error", never to "pass".
const (
	StatusPass  = "pass"
	StatusFail  = "fail"
	StatusError = "error"
)

// Bounds. The declarations arrive from the platform, so they are trusted more
// than a node payload — but a runaway manifest must not be able to make every
// heartbeat spawn an unbounded number of subshells.
const (
	MaxProbes      = 32
	DefaultTimeout = 10 * time.Second
)

// Probe is one declared assertion: the bare command Command, resolved through
// PATH, must be exactly ResolvesTo.
type Probe struct {
	Name       string
	Command    string
	ResolvesTo string
}

// ShellResult is what one shell answered. Resolved is the path that shell
// actually produced — the difference between it and the declared path IS the
// finding, so it is reported verbatim rather than reduced to a boolean.
type ShellResult struct {
	Shell    string `json:"shell"`
	Status   string `json:"status"`
	Resolved string `json:"resolved,omitempty"`
	Message  string `json:"message,omitempty"`
}

// ProbeReport is one probe's per-shell facts. There is no roll-up field here
// on purpose: see the package doc.
type ProbeReport struct {
	Name     string        `json:"name"`
	Command  string        `json:"command"`
	Expected string        `json:"expected"`
	Shells   []ShellResult `json:"shells"`
}

// ModuleReport is one module's probe run. DeclaredCount is what the agent was
// ASKED to run; the server compares it against the number of entries in
// Probes, so probes that were dropped cannot vanish silently.
type ModuleReport struct {
	ModuleID      string        `json:"module_id"`
	ModuleName    string        `json:"module_name"`
	DeclaredCount int           `json:"declared_count"`
	ObservedAt    string        `json:"observed_at"`
	Probes        []ProbeReport `json:"probes"`
}

// Runner executes one shell invocation and returns its stdout. Injected so the
// shadowing test can build a REAL divergence between the two shells (a
// temporary HOME with a .bash_profile that reorders PATH) without touching the
// host's /etc/profile.
type Runner interface {
	Output(ctx context.Context, name string, args ...string) (string, error)
}

// ExecRunner is the production Runner: real bash, the agent's own environment.
type ExecRunner struct {
	// Env, when non-nil, replaces the process environment for the child.
	// Production leaves it nil (inherit); tests set it to construct the
	// login/non-login divergence the probe exists to detect.
	Env []string
}

func (r ExecRunner) Output(ctx context.Context, name string, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	if r.Env != nil {
		cmd.Env = r.Env
	} else {
		cmd.Env = os.Environ()
	}
	out, err := cmd.Output()
	if err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			// A non-zero exit from `command -v` means the name did not
			// resolve. That is a probe FAILURE, not a runner error, and the
			// caller distinguishes them — so return the (empty) stdout with
			// the exit error rather than swallowing one into the other.
			return strings.TrimSpace(string(out)), err
		}
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

// FromConfig extracts the probes a module declares, out of the `config` blob
// the platform serializes onto every manifest (NodeModule#config, which
// ManifestImportService mirrors the manifest's `verify:` block into).
//
// Anything malformed is DROPPED, never guessed at. The server-side validator
// is the gate that rejects a bad declaration at import time, so a malformed
// survivor here is corrupt data; dropping it fails CLOSED (the module declares
// no probe, so nothing claims it was verified) rather than open. In
// particular a probe with an empty ResolvesTo is dropped: that is the
// existence check the whole feature exists to refuse, and running it would
// produce a green result that means nothing.
func FromConfig(config map[string]any) []Probe {
	block, ok := config["verify"].(map[string]any)
	if !ok {
		return nil
	}
	raw, ok := block["probes"].([]any)
	if !ok {
		return nil
	}
	seen := map[string]bool{}
	probes := make([]Probe, 0, len(raw))
	for _, entry := range raw {
		if len(probes) >= MaxProbes {
			break
		}
		m, ok := entry.(map[string]any)
		if !ok {
			continue
		}
		p := Probe{
			Name:       stringField(m, "name"),
			Command:    stringField(m, "command"),
			ResolvesTo: stringField(m, "resolves_to"),
		}
		if p.Name == "" || p.Command == "" || p.ResolvesTo == "" {
			continue
		}
		// Mirrors System::ModuleVerify::COMMAND_RX exactly — an ALLOWLIST,
		// not a blocklist. A blocklist here was wrong twice over: a command
		// containing a slash names a path instead of exercising the PATH
		// lookup (so it is structurally incapable of seeing a shadow), and a
		// command containing a quote or a shell metacharacter is a command
		// INJECTION, because NodeModule#config is writable through the
		// operator API (node_modules#update permits `config: {}` wholesale)
		// and that path never passes through ManifestImportService's
		// validator. The runner no longer interpolates the command into the
		// shell word at all (see runShell), so this is defence in depth
		// rather than the only guard — but it must actually be equivalent to
		// the server's rule, or the comment claiming so is a lie.
		if !commandRx.MatchString(p.Command) {
			continue
		}
		if !strings.HasPrefix(p.ResolvesTo, "/") {
			continue
		}
		if seen[p.Name] {
			continue
		}
		seen[p.Name] = true
		probes = append(probes, p)
	}
	return probes
}

func stringField(m map[string]any, key string) string {
	s, _ := m[key].(string)
	return strings.TrimSpace(s)
}

// RunModule runs every probe for one module and returns its report.
// DeclaredCount is set from len(probes) — the count the agent was handed after
// FromConfig dropped anything unusable — so a report can be compared against
// what actually reported.
func RunModule(ctx context.Context, runner Runner, moduleID, moduleName string, probes []Probe) ModuleReport {
	return RunModuleWithTimeout(ctx, runner, moduleID, moduleName, probes, DefaultTimeout)
}

// RunModuleWithTimeout is RunModule with an explicit per-shell budget.
func RunModuleWithTimeout(ctx context.Context, runner Runner, moduleID, moduleName string,
	probes []Probe, timeout time.Duration) ModuleReport {
	report := ModuleReport{
		ModuleID:      moduleID,
		ModuleName:    moduleName,
		DeclaredCount: len(probes),
		ObservedAt:    time.Now().UTC().Format(time.RFC3339),
		Probes:        make([]ProbeReport, 0, len(probes)),
	}
	for _, p := range probes {
		report.Probes = append(report.Probes, RunWithTimeout(ctx, runner, p, timeout))
	}
	return report
}

// Run executes one probe in EVERY shell in Shells and returns the per-shell
// facts. It never short-circuits after a failing shell: "login says
// /usr/bin/foo, non-login says /usr/local/bin/foo" is a materially different
// diagnosis from "both say /usr/bin/foo", and only reporting both can tell
// them apart.
func Run(ctx context.Context, runner Runner, p Probe) ProbeReport {
	return RunWithTimeout(ctx, runner, p, DefaultTimeout)
}

// RunWithTimeout is Run with an explicit PER-SHELL budget. Per shell, not per
// module: one hung invocation must not starve the probe's other shell (which
// would collapse a real answer into "not measured") nor the module's other
// probes.
func RunWithTimeout(ctx context.Context, runner Runner, p Probe, timeout time.Duration) ProbeReport {
	report := ProbeReport{
		Name:     p.Name,
		Command:  p.Command,
		Expected: p.ResolvesTo,
		Shells:   make([]ShellResult, 0, len(Shells)),
	}
	for _, shell := range Shells {
		shellCtx := ctx
		cancel := context.CancelFunc(func() {})
		if timeout > 0 {
			shellCtx, cancel = context.WithTimeout(ctx, timeout)
		}
		report.Shells = append(report.Shells, runShell(shellCtx, runner, shell, p))
		cancel()
	}
	return report
}

// runShell asks ONE shell where the name resolves.
//
// `command -v` is the resolution oracle, not `test -x` and not `[ -e ]`:
// those answer "is there a file at this path", which is the existence check
// that passed while VM-9000 was broken. `command -v` performs the PATH search
// the way the shell itself would, which is the thing whose answer we doubt.
//
// The command word is a shell single-quoted literal. Command is validated
// server-side to a bare token and re-checked in FromConfig, so this is belt
// and braces rather than the only guard.
func runShell(ctx context.Context, runner Runner, shell string, p Probe) ShellResult {
	res := ShellResult{Shell: shell}

	flag := "-c"
	if shell == ShellLogin {
		// -l sources /etc/profile, /etc/profile.d/* and ~/.bash_profile —
		// which is exactly where a PATH gets reordered, and therefore where
		// the two shells can disagree.
		flag = "-lc"
	}
	// The command is passed as a POSITIONAL PARAMETER, never interpolated
	// into the script text. `bash -c <script> <argv0> <arg1>` binds arg1 to
	// $1, so no quoting exists for a hostile `command` value to escape.
	// This matters because NodeModule#config — where the declaration lives —
	// is writable through the operator API without passing
	// ManifestImportService's validator, and this code runs as root on every
	// node carrying the module. `--` ends `command`'s own option parsing so
	// a name beginning with `-` is treated as a name.
	args := []string{flag, `command -v -- "$1"`, "bash", p.Command}

	out, err := runner.Output(ctx, "bash", args...)
	resolved := firstLine(out)
	res.Resolved = resolved

	switch {
	case resolved == "" && err != nil:
		// Did not resolve at all. A FAILURE, not an error: the manifest says
		// this path must answer this name and nothing did. (The gitleaks v4
		// empty-artifact whiteout is this case.) A genuine inability to run
		// the shell is separated below by the absence of an exit status.
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			res.Status = StatusFail
			res.Message = "command did not resolve on PATH"
			return res
		}
		res.Status = StatusError
		res.Message = truncate(err.Error())
		return res
	case resolved == "":
		res.Status = StatusFail
		res.Message = "command did not resolve on PATH"
		return res
	case resolved == p.ResolvesTo:
		res.Status = StatusPass
		return res
	default:
		// THE FINDING. The name resolved — every existence check on this node
		// passes — and it resolved to the wrong file.
		res.Status = StatusFail
		res.Message = fmt.Sprintf("resolved to %s, manifest declares %s", resolved, p.ResolvesTo)
		return res
	}
}

func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		s = s[:i]
	}
	return strings.TrimSpace(s)
}

func truncate(s string) string {
	const max = 500
	if len(s) > max {
		return s[:max]
	}
	return s
}

// SortReports gives the heartbeat a stable module order so an unchanged fleet
// does not produce a different payload on every tick.
func SortReports(reports []ModuleReport) {
	sort.Slice(reports, func(i, j int) bool { return reports[i].ModuleID < reports[j].ModuleID })
}
