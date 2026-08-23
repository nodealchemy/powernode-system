package probe

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// ---------------------------------------------------------------------------
// THE INCIDENT TEST.
//
// A REAL shadowed binary, caught by a REAL bash, through the login/non-login
// divergence that is the whole reason this probe runs two shells.
//
// The fixture reproduces VM-9000 exactly: two identically-named executables on
// two different paths, with a login-shell profile that puts the WRONG one
// first. A non-login shell resolves the right one; a login shell resolves the
// shadow. An existence check ("is there a `pnprobefixture` on PATH?") is TRUE
// in both, which is precisely why an existence check could not see this.
// ---------------------------------------------------------------------------

func TestRun_CatchesShadowedBinaryInLoginShellOnly(t *testing.T) {
	requireBash(t)

	fx := newShadowFixture(t)
	fx.assertDivergence(t)

	report := Run(context.Background(), fx.runner(), Probe{
		Name:       "fixture-binary",
		Command:    fixtureCommand,
		ResolvesTo: fx.realPath,
	})

	if len(report.Shells) != 2 {
		t.Fatalf("probe must run BOTH shells; got %d results: %+v", len(report.Shells), report.Shells)
	}
	byShell := map[string]ShellResult{}
	for _, s := range report.Shells {
		byShell[s.Shell] = s
	}
	for _, want := range Shells {
		if _, ok := byShell[want]; !ok {
			t.Fatalf("no result for shell %q — a one-shell probe reproduces the VM-9000 bug", want)
		}
	}

	if got := byShell[ShellNonLogin]; got.Status != StatusPass || got.Resolved != fx.realPath {
		t.Errorf("non-login shell: want pass at %s, got status=%s resolved=%s msg=%s",
			fx.realPath, got.Status, got.Resolved, got.Message)
	}

	// The finding. This is the assertion the whole feature exists for: the
	// name resolved (so every existence check passed) and it resolved to the
	// WRONG file, and the probe says so, naming both paths.
	login := byShell[ShellLogin]
	if login.Status != StatusFail {
		t.Fatalf("login shell resolved a SHADOWED binary and the probe did not fail it: %+v", login)
	}
	if login.Resolved != fx.shadowPath {
		t.Errorf("login shell: want resolved=%s (the shadow), got %s", fx.shadowPath, login.Resolved)
	}
	if !strings.Contains(login.Message, fx.realPath) {
		t.Errorf("failure message must name the declared path %s; got %q", fx.realPath, login.Message)
	}
}

// The counter-oracle. Without this, the test above would also pass if the
// probe simply failed everything. Same fixture, same real bash, but the probe
// declares the path the SHADOW sits at — so the login shell now agrees and the
// non-login one does not.
func TestRun_FailsTheOtherShellWhenTheDeclaredPathIsTheShadow(t *testing.T) {
	requireBash(t)

	fx := newShadowFixture(t)
	fx.assertDivergence(t)

	report := Run(context.Background(), fx.runner(), Probe{
		Name:       "fixture-binary",
		Command:    fixtureCommand,
		ResolvesTo: fx.shadowPath,
	})

	byShell := map[string]ShellResult{}
	for _, s := range report.Shells {
		byShell[s.Shell] = s
	}
	if got := byShell[ShellLogin]; got.Status != StatusPass {
		t.Errorf("login shell should now pass: %+v", got)
	}
	if got := byShell[ShellNonLogin]; got.Status != StatusFail {
		t.Errorf("non-login shell should now fail: %+v", got)
	}
}

// A binary that is simply GONE — the gitleaks v4 empty-artifact whiteout
// shape. Must be a FAIL (the manifest says this path answers this name and
// nothing does), never an error and never a skip.
func TestRun_FailsWhenCommandDoesNotResolveAtAll(t *testing.T) {
	requireBash(t)

	fx := newShadowFixture(t)
	report := Run(context.Background(), fx.runner(), Probe{
		Name:       "missing",
		Command:    "pnprobe-definitely-not-installed",
		ResolvesTo: "/usr/local/bin/pnprobe-definitely-not-installed",
	})
	for _, s := range report.Shells {
		if s.Status != StatusFail {
			t.Errorf("shell %s: unresolved command must FAIL, got %+v", s.Shell, s)
		}
	}
}

// Both shells agreeing with the declared path is the only passing shape.
func TestRun_PassesWhenBothShellsAgree(t *testing.T) {
	requireBash(t)

	fx := newShadowFixtureWithoutProfile(t)
	report := Run(context.Background(), fx.runner(), Probe{
		Name:       "fixture-binary",
		Command:    fixtureCommand,
		ResolvesTo: fx.realPath,
	})
	for _, s := range report.Shells {
		if s.Status != StatusPass {
			t.Errorf("shell %s: want pass, got %+v", s.Shell, s)
		}
	}
}

// ---------------------------------------------------------------------------
// Deterministic (no-bash) coverage of the same rules, so the contract is
// asserted even where the fixture above cannot construct a real divergence.
// ---------------------------------------------------------------------------

type scriptedRunner struct {
	byShell map[string]string // "-lc" / "-c" -> stdout
	err     map[string]error
}

func (r scriptedRunner) Output(_ context.Context, _ string, args ...string) (string, error) {
	key := args[0]
	return r.byShell[key], r.err[key]
}

func TestRun_AlwaysRunsBothShellsAndNeverShortCircuits(t *testing.T) {
	r := scriptedRunner{byShell: map[string]string{
		"-lc": "/opt/shadow/foo",
		"-c":  "/usr/local/bin/foo",
	}}
	report := Run(context.Background(), r, Probe{
		Name: "foo", Command: "foo", ResolvesTo: "/usr/local/bin/foo",
	})
	if len(report.Shells) != len(Shells) {
		t.Fatalf("want %d shell results, got %d", len(Shells), len(report.Shells))
	}
	if report.Shells[0].Shell != ShellLogin || report.Shells[0].Status != StatusFail {
		t.Errorf("login result wrong: %+v", report.Shells[0])
	}
	// The second shell must still have RUN after the first failed. A
	// short-circuit here would lose the fact that the two disagree, which is
	// the diagnosis an operator needs.
	if report.Shells[1].Shell != ShellNonLogin || report.Shells[1].Status != StatusPass {
		t.Errorf("non-login result wrong (short-circuited?): %+v", report.Shells[1])
	}
}

func TestFromConfig(t *testing.T) {
	cases := []struct {
		name string
		yaml string
		want int
		why  string
	}{
		{"well formed", `{"verify":{"probes":[{"name":"a","command":"gh","resolves_to":"/usr/local/bin/gh"}]}}`, 1, ""},
		{"no verify block", `{"skills":[]}`, 0, ""},
		{"empty probes", `{"verify":{"probes":[]}}`, 0, ""},
		// The load-bearing drops. Each of these would produce a probe that
		// LOOKS like verification and proves nothing.
		{"missing resolves_to is an existence check", `{"verify":{"probes":[{"name":"a","command":"gh"}]}}`, 0,
			"a probe with no declared path is the existence check that passed while VM-9000 was broken"},
		{"command with a slash cannot see a shadow", `{"verify":{"probes":[{"name":"a","command":"/usr/local/bin/gh","resolves_to":"/usr/local/bin/gh"}]}}`, 0,
			"an absolute command resolves itself and never exercises the PATH lookup"},
		{"relative resolves_to", `{"verify":{"probes":[{"name":"a","command":"gh","resolves_to":"bin/gh"}]}}`, 0, ""},
		{"duplicate names collapse", `{"verify":{"probes":[{"name":"a","command":"gh","resolves_to":"/a"},{"name":"a","command":"jq","resolves_to":"/b"}]}}`, 1, ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var cfg map[string]any
			if err := json.Unmarshal([]byte(tc.yaml), &cfg); err != nil {
				t.Fatal(err)
			}
			got := FromConfig(cfg)
			if len(got) != tc.want {
				t.Errorf("want %d probes, got %d (%+v) — %s", tc.want, len(got), got, tc.why)
			}
		})
	}
}

func TestFromConfig_CapsProbeCount(t *testing.T) {
	entries := make([]any, 0, MaxProbes+10)
	for i := 0; i < MaxProbes+10; i++ {
		entries = append(entries, map[string]any{
			"name": string(rune('a'+i%26)) + time.Duration(i).String(), "command": "gh", "resolves_to": "/usr/local/bin/gh",
		})
	}
	got := FromConfig(map[string]any{"verify": map[string]any{"probes": entries}})
	if len(got) > MaxProbes {
		t.Errorf("want at most %d probes, got %d", MaxProbes, len(got))
	}
}

func TestRunModule_DeclaredCountMatchesWhatWasRun(t *testing.T) {
	r := scriptedRunner{byShell: map[string]string{"-lc": "/usr/local/bin/gh", "-c": "/usr/local/bin/gh"}}
	probes := []Probe{
		{Name: "a", Command: "gh", ResolvesTo: "/usr/local/bin/gh"},
		{Name: "b", Command: "gh", ResolvesTo: "/usr/local/bin/gh"},
	}
	rep := RunModule(context.Background(), r, "mod-1", "gh", probes)
	if rep.DeclaredCount != 2 || len(rep.Probes) != 2 {
		t.Errorf("declared=%d reported=%d, want 2/2", rep.DeclaredCount, len(rep.Probes))
	}
	if rep.ObservedAt == "" {
		t.Error("ObservedAt must be stamped — the sensor keys probe staleness on the AGENT's clock")
	}
}

// ---------------------------------------------------------------------------
// Fixture
// ---------------------------------------------------------------------------

const fixtureCommand = "pnprobefixture"

type shadowFixture struct {
	realPath   string
	shadowPath string
	env        []string
}

func (f shadowFixture) runner() Runner { return ExecRunner{Env: f.env} }

// assertDivergence proves the FIXTURE works before the test relies on it. A
// host whose /etc/profile makes the two shells agree cannot exhibit the bug,
// and a green run there would be evidence of nothing — so it is reported as
// NOT MEASURED (skip), never as a pass.
func (f shadowFixture) assertDivergence(t *testing.T) {
	t.Helper()
	login := f.rawResolve(t, "-lc")
	nonLogin := f.rawResolve(t, "-c")
	if login == nonLogin {
		t.Skipf("fixture could not construct a login/non-login PATH divergence on this host "+
			"(both shells resolved %q) — precondition unmet, so this run measures nothing", login)
	}
}

func (f shadowFixture) rawResolve(t *testing.T, flag string) string {
	t.Helper()
	cmd := exec.Command("bash", flag, "command -v "+fixtureCommand)
	cmd.Env = f.env
	out, _ := cmd.Output()
	return strings.TrimSpace(string(out))
}

func newShadowFixture(t *testing.T) shadowFixture {
	t.Helper()
	fx := newShadowFixtureWithoutProfile(t)
	// The login shell's PATH reordering. /etc/profile runs first and may
	// rewrite PATH wholesale; ~/.bash_profile runs after it, so prepending
	// here wins in the login shell and is invisible to the non-login one.
	profile := "export PATH=" + filepath.Dir(fx.shadowPath) + ":$PATH\n"
	if err := os.WriteFile(filepath.Join(homeOf(fx.env), ".bash_profile"), []byte(profile), 0o644); err != nil {
		t.Fatal(err)
	}
	return fx
}

func newShadowFixtureWithoutProfile(t *testing.T) shadowFixture {
	t.Helper()
	base := t.TempDir()
	realDir := filepath.Join(base, "real")
	shadowDir := filepath.Join(base, "shadow")
	home := filepath.Join(base, "home")
	for _, d := range []string{realDir, shadowDir, home} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	realPath := filepath.Join(realDir, fixtureCommand)
	shadowPath := filepath.Join(shadowDir, fixtureCommand)
	for _, p := range []string{realPath, shadowPath} {
		if err := os.WriteFile(p, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	return shadowFixture{
		realPath:   realPath,
		shadowPath: shadowPath,
		env: []string{
			"HOME=" + home,
			"PATH=" + realDir + ":/usr/local/bin:/usr/bin:/bin",
		},
	}
}

func homeOf(env []string) string {
	for _, kv := range env {
		if strings.HasPrefix(kv, "HOME=") {
			return strings.TrimPrefix(kv, "HOME=")
		}
	}
	return ""
}

func requireBash(t *testing.T) {
	t.Helper()
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skip("bash not installed; the two-shell probe cannot be exercised")
	}
}

// ---------------------------------------------------------------------------
// Command injection.
//
// The declaration lives on NodeModule#config, which the operator API writes
// wholesale (node_modules#update permits `config: {}`) WITHOUT passing through
// ManifestImportService's validator. This code then runs as root on every node
// carrying the module. So the agent must refuse a hostile command on its own,
// and the runner must not give one anywhere to escape to.
// ---------------------------------------------------------------------------

func TestFromConfig_RejectsShellMetacharactersInCommand(t *testing.T) {
	hostile := []string{
		`x';id;'`, "x;id", "x`id`", "x$(id)", "x|id", "x&id", "x\"y",
		"x id", "x\tid", "x\nid", "/usr/bin/x", "-x", "",
	}
	for _, cmd := range hostile {
		cfg := map[string]any{"verify": map[string]any{"probes": []any{
			map[string]any{"name": "a", "command": cmd, "resolves_to": "/usr/local/bin/x"},
		}}}
		if got := FromConfig(cfg); len(got) != 0 {
			t.Errorf("command %q was ADMITTED (%+v) — it must be refused", cmd, got)
		}
	}
}

// Even if a hostile command somehow reached the runner, the shell must never
// evaluate it: it is bound to $1, not spliced into the script text.
func TestRunShell_PassesTheCommandAsAPositionalParameterNeverAsScriptText(t *testing.T) {
	requireBash(t)

	dir := t.TempDir()
	canary := filepath.Join(dir, "pwned")
	// A classic quote-escape payload. Under the old
	// fmt.Sprintf("command -v '%s'", cmd) this would close the quote and run
	// `touch <canary>` as whatever user the agent runs as.
	payload := `x';touch ` + canary + `;'`

	res := runShell(context.Background(), ExecRunner{Env: []string{"HOME=" + dir, "PATH=/usr/bin:/bin"}},
		ShellNonLogin, Probe{Name: "p", Command: payload, ResolvesTo: "/usr/local/bin/x"})

	if _, err := os.Stat(canary); err == nil {
		t.Fatalf("COMMAND INJECTION: %s was created — the payload was evaluated by the shell", canary)
	}
	if res.Status == StatusPass {
		t.Errorf("an injected command must never score pass: %+v", res)
	}
}
