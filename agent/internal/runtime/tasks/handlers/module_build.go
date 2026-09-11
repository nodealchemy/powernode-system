package handlers

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"os/exec"
	"sort"
	"strings"

	"github.com/nodealchemy/powernode-system/agent/internal/runtime/tasks"
)

// moduleForgeBuildScript is the entrypoint the module-forge NodeModule ships
// (campaign 019f5885 inc7, Part A). Invoked with ZERO CLI arguments — every
// input (including secrets) travels as an environment variable, per the
// platform's cryptographic material safety rule (never pass secrets as
// function/CLI arguments visible in `ps`, shell history, or logs).
const moduleForgeBuildScript = "/usr/local/bin/module-forge-build.sh"

// logTailMaxBytes bounds how much of the script's stdout/stderr rides along
// on the task result (System::Task#events is JSONB on a shared table — an
// unbounded build log would bloat it for every failed/succeeded build).
// stdout carries essentially just the one result-JSON line, so it stays small;
// stderr carries every stage's build diagnostics (apt, curl, the Stage 1.5
// node-install + npm/Vite build output), so it gets a far larger budget —
// enough to reach a mid-build failure whose error would otherwise be pushed out
// of the tail by later stages' output. Tune down if event-table growth bites.
const (
	logTailMaxBytes       = 4096
	logTailStderrMaxBytes = 131072
)

// Execer runs the module-forge-build.sh entrypoint with an explicit
// environment. Secrets travel ONLY via env (never args, never logged) — see
// moduleForgeBuildScript's doc. A production ModuleBuildHandler defaults to
// execRunner{}; tests substitute a stub that records the env passed and
// returns canned stdout/stderr, so the env-wiring + result-parsing +
// failure-path logic is unit-testable without a real build.
type Execer interface {
	Run(ctx context.Context, name string, env []string) (stdout, stderr []byte, err error)
}

// execRunner shells out via os/exec. cmd.Env is the ambient environment
// (PATH, HOME, etc. — the script needs these to find git/oras/mmdebstrap)
// PLUS the build-specific vars appended; never JUST the build vars, and
// never the build vars merged into anything that gets logged.
type execRunner struct{}

func (execRunner) Run(ctx context.Context, name string, env []string) (stdout, stderr []byte, err error) {
	cmd := exec.CommandContext(ctx, name)
	cmd.Env = append(os.Environ(), env...)
	var outBuf, errBuf bytes.Buffer
	cmd.Stdout = &outBuf
	cmd.Stderr = &errBuf
	err = cmd.Run()
	return outBuf.Bytes(), errBuf.Bytes(), err
}

// ModuleBuildHandler runs a native NodeModule build (campaign 019f5885
// inc7) on a leased module-forge builder:
//  1. fetch this build's secrets from the lease-gated node_api endpoint
//     (GET config/ci_build_context?module=<slug>);
//  2. exec module-forge-build.sh with the CONTRACT env vars (MODULE,
//     BUILD_SHA, OCI_REF, MODULE_SOURCE_URL, PARENT_PAT (Class-B only),
//     CORE_REF (the batch's pinned core commit; always set, empty when the
//     platform sent no pin),
//     ORAS_REGISTRY, ORAS_REGISTRY_USER, ORAS_REGISTRY_PASSWORD,
//     APT_SNAPSHOT (optional drift-guard assertion)) — matching Part A's
//     module-forge module EXACTLY (contract confirmed against the landed
//     module-forge-build.sh);
//  3. parse the result JSON (the last non-empty stdout line) and hand it
//     back to the loop, which reports it via Client.Complete.
//
// No handler timeout — the poll loop's processTask has none, and a real
// module build can run many minutes. Not idempotent in the "safe to run
// twice concurrently" sense (it pushes to the registry), but a crash-
// recovery re-dispatch simply rebuilds + re-pushes the same
// content-addressed digest, which is safe.
type ModuleBuildHandler struct {
	// HTTP is the typed platform transport (deps.Transport satisfies this
	// directly — *transport.SwappableClient has GetJSON/PostJSON). Stored
	// as the interface (not deps.Transport.Get()'s concrete *transport.Client)
	// so tests can substitute a fake without a live mTLS connection.
	HTTP tasks.HTTPClient
	// Exec runs the build entrypoint. Defaults to execRunner{} when nil.
	Exec Execer
	// Lint runs ci.lint_discovery's two phases in the sandbox. Defaults to
	// sandboxRunner{} when nil.
	Lint LintExecer
	// LintWorkdirBase, set only by tests, is used as the workdir base as is.
	// Production resolves and checks one per task (lintWorkdirBase).
	LintWorkdirBase string
}

// ciJob is one entry in the handler's allowlist: a task command this handler
// runs, with its own platform-owned script, its own lease-gated context
// endpoint and its own result handling. Every job passes secrets to its script
// ONLY as environment variables, and scrubs them from any error or log text it
// sends back.
type ciJob interface {
	run(ctx context.Context, h *ModuleBuildHandler, task *tasks.Task) (tasks.Result, error)
}

// ciJobs is the allowlist, keyed by task command (campaign 01a08c9b D1b). A
// command absent here is refused before anything is fetched or executed.
var ciJobs = map[string]ciJob{
	"ci.module_build":   moduleBuildJob{},
	"ci.lint_discovery": lintDiscoveryJob{},
}

func ciJobCommands() []string {
	commands := make([]string, 0, len(ciJobs))
	for command := range ciJobs {
		commands = append(commands, command)
	}
	sort.Strings(commands)
	return commands
}

// RegisterModuleBuild binds every allowlisted command to one handler.
func RegisterModuleBuild(r *tasks.Registry, deps tasks.Dependencies) {
	h := &ModuleBuildHandler{HTTP: deps.Transport, Exec: execRunner{}, Lint: sandboxRunner{},
		LintWorkdirBase: deps.LintWorkdirBase}
	for _, command := range ciJobCommands() {
		r.Register(command, h)
	}
	// D1b security R2: once, at agent start, remove lint workdirs an earlier
	// agent process left behind (a configured base is swept before each lint
	// task). In the background: a large stale tree must not hold up start.
	go func() {
		n, err := h.sweepLintWorkdirsAtStart()
		if err != nil && deps.OnError != nil {
			deps.OnError("lint_workdir_sweep", err)
		}
		lintStartSweepDone(n, err)
	}()
}

// scrubSecrets replaces every secret value in text, in each form it can take
// on the way out: raw, percent-encoded (a clone URL) and JSON-escaped. It is
// applied to any error or log text a job sends back, because a script's stderr
// can echo what it was given (git prints a credential-bearing URL on a failed
// clone). Values shorter than four bytes are left alone: they cannot be told
// apart from ordinary text.
func scrubSecrets(text string, secrets ...string) string {
	for _, s := range secrets {
		for _, v := range secretVariants(s) {
			text = strings.ReplaceAll(text, v, "[REDACTED]")
		}
	}
	return text
}

func containsSecret(text string, secrets []string) bool {
	for _, s := range secrets {
		for _, v := range secretVariants(s) {
			if strings.Contains(text, v) {
				return true
			}
		}
	}
	return false
}

func secretVariants(s string) []string {
	if len(s) < 4 {
		return nil
	}
	variants := []string{s}
	add := func(v string) {
		if v == "" {
			return
		}
		for _, have := range variants {
			if have == v {
				return
			}
		}
		variants = append(variants, v)
	}
	add(url.QueryEscape(s))
	add(url.PathEscape(s))
	// Both JSON escapings: Go's (which also escapes <, > and &) and the
	// minimal one Ruby and Node linters write (only quotes, backslashes and
	// control characters).
	if b, err := json.Marshal(s); err == nil && len(b) >= 2 {
		add(string(b[1 : len(b)-1]))
	}
	var minimal bytes.Buffer
	enc := json.NewEncoder(&minimal)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(s); err == nil {
		if b := bytes.TrimSuffix(minimal.Bytes(), []byte("\n")); len(b) >= 2 {
			add(string(b[1 : len(b)-1]))
		}
	}
	return variants
}

// scrubbedLogTail scrubs each whole stream BEFORE bounding it, so a secret
// that straddles the cut can never leave a fragment behind.
func scrubbedLogTail(stdout, stderr []byte, secrets ...string) string {
	return logTail([]byte(scrubSecrets(string(stdout), secrets...)), []byte(scrubSecrets(string(stderr), secrets...)))
}

// moduleBuildOptions is the parsed, validated view of task.Options for a
// ci.module_build task — set at task-creation time (inc7) by whatever
// caller plans the build; the inc9 native orchestrator sets these
// programmatically.
type moduleBuildOptions struct {
	Module string
	SHA    string
	OCIRef string
}

// parseModuleBuildOptions validates task.Options. Pure (no I/O) so the
// validation logic is unit-testable without an HTTP client or exec.
func parseModuleBuildOptions(task *tasks.Task) (moduleBuildOptions, error) {
	module, _ := task.Options["module"].(string)
	sha, _ := task.Options["sha"].(string)
	ociRef, _ := task.Options["oci_ref"].(string)

	if module == "" {
		return moduleBuildOptions{}, errors.New("ci.module_build: options.module is required")
	}
	if sha == "" {
		return moduleBuildOptions{}, errors.New("ci.module_build: options.sha is required")
	}
	if ociRef == "" {
		return moduleBuildOptions{}, errors.New("ci.module_build: options.oci_ref is required")
	}
	return moduleBuildOptions{Module: module, SHA: sha, OCIRef: ociRef}, nil
}

// ciBuildContext is the parsed response body of GET
// config/ci_build_context — see
// Api::V1::System::NodeApi::ConfigController#ci_build_context.
type ciBuildContext struct {
	SourceRepoURL string `json:"source_repo_url"`
	SourceToken   string `json:"source_token"`
	ParentPAT     string `json:"parent_pat"`
	OrasRegistry  string `json:"oras_registry"`
	OrasUser      string `json:"oras_user"`
	OrasPassword  string `json:"oras_password"`
	AptSnapshot   string `json:"apt_snapshot"`
	// CoreRef is the core (parent powernode-platform) commit this batch must
	// be assembled from — the batch's own expected_core_sha, the SAME value
	// System::CoreMirrorPreflight checks the public mirror against at dispatch
	// and System::CoreProvenanceGate checks the published artifact's
	// org.powernode.core_source_sha annotation against at promote. Sent only
	// for a Class-B module (the four that clone core) whose batch recorded a
	// full 40-hex expectation; absent otherwise.
	//
	// THIS FIELD IS WHY THE AGENT HAD TO BE REBUILT. encoding/json decodes
	// into this FIXED struct and buildEnv maps a FIXED list, so a `core_ref`
	// the platform started sending would have been dropped here without a
	// single error — the build would keep taking whatever the mirror's default
	// branch pointed at while every log line read as if it were pinned. That
	// silent-drop shape is exactly the defect class the pin exists to remove,
	// so it must not be reintroduced by adding a server field without the
	// matching field here.
	CoreRef string `json:"core_ref"`
}

// moduleBuildResult is module-forge-build.sh's emitted result JSON (the
// last non-empty stdout line) — {"oci_digest","fsverity_root","size",
// "built_from_sha"}, matching Part A's contract exactly.
type moduleBuildResult struct {
	OCIDigest    string      `json:"oci_digest"`
	FsverityRoot string      `json:"fsverity_root"`
	Size         json.Number `json:"size"`
	BuiltFromSHA string      `json:"built_from_sha"`
}

// Execute runs the allowlisted job for task.Command.
func (h *ModuleBuildHandler) Execute(ctx context.Context, task *tasks.Task) (tasks.Result, error) {
	job, ok := ciJobs[task.Command]
	if !ok {
		return nil, fmt.Errorf("ci handler: command %q is not on the allowlist", task.Command)
	}
	return job.run(ctx, h, task)
}

// moduleBuildJob is the ci.module_build entry: a native NodeModule build.
type moduleBuildJob struct{}

func (moduleBuildJob) run(ctx context.Context, h *ModuleBuildHandler, task *tasks.Task) (tasks.Result, error) {
	opts, err := parseModuleBuildOptions(task)
	if err != nil {
		return nil, err
	}
	if h.HTTP == nil {
		return nil, errors.New("ci.module_build: no platform transport")
	}

	bctx, err := fetchBuildContext(h.HTTP, opts.Module)
	if err != nil {
		return nil, fmt.Errorf("ci.module_build %s: fetch build context: %w", opts.Module, err)
	}

	sourceURL, err := embedCredential(bctx.SourceRepoURL, bctx.SourceToken)
	if err != nil {
		return nil, fmt.Errorf("ci.module_build %s: build source url: %w", opts.Module, err)
	}

	env := buildEnv(opts, sourceURL, bctx)

	execer := h.Exec
	if execer == nil {
		execer = execRunner{}
	}
	stdout, stderr, runErr := execer.Run(ctx, moduleForgeBuildScript, env)
	tail := scrubbedLogTail(stdout, stderr, bctx.SourceToken, bctx.ParentPAT, bctx.OrasPassword)
	if runErr != nil {
		return nil, fmt.Errorf("ci.module_build %s: %w (log_tail: %s)", opts.Module, runErr, tail)
	}

	parsed, err := parseBuildResult(stdout)
	if err != nil {
		return nil, fmt.Errorf("ci.module_build %s: %w (log_tail: %s)", opts.Module, err, tail)
	}

	result := tasks.Result{
		"oci_digest":     parsed.OCIDigest,
		"fsverity_root":  parsed.FsverityRoot,
		"built_from_sha": parsed.BuiltFromSHA,
		"log_tail":       tail,
	}
	if n, convErr := parsed.Size.Int64(); convErr == nil {
		result["size"] = n
	} else if parsed.Size != "" {
		result["size"] = parsed.Size.String()
	}
	return result, nil
}

// buildEnv assembles the env slice module-forge-build.sh expects, matching
// Part A's contract EXACTLY: MODULE, BUILD_SHA, OCI_REF, MODULE_SOURCE_URL,
// ORAS_REGISTRY, ORAS_REGISTRY_USER, ORAS_REGISTRY_PASSWORD always present;
// PARENT_PAT / APT_SNAPSHOT only when the platform supplied them (Class-B
// modules / an operator override, respectively) — an empty env value for an
// optional var the script doesn't expect is worse than simply omitting it.
// CORE_REF is the deliberate exception and is ALWAYS emitted; see the comment
// at its append below for why omission cannot clear it.
func buildEnv(opts moduleBuildOptions, sourceURL string, bctx *ciBuildContext) []string {
	env := []string{
		"MODULE=" + opts.Module,
		"BUILD_SHA=" + opts.SHA,
		"OCI_REF=" + opts.OCIRef,
		"MODULE_SOURCE_URL=" + sourceURL,
		"ORAS_REGISTRY=" + bctx.OrasRegistry,
		"ORAS_REGISTRY_USER=" + bctx.OrasUser,
		"ORAS_REGISTRY_PASSWORD=" + bctx.OrasPassword,
	}
	if bctx.ParentPAT != "" {
		env = append(env, "PARENT_PAT="+bctx.ParentPAT)
	}
	if bctx.AptSnapshot != "" {
		env = append(env, "APT_SNAPSHOT="+bctx.AptSnapshot)
	}
	// CORE_REF is ALWAYS emitted, empty included — unlike PARENT_PAT and
	// APT_SNAPSHOT above, which are omitted when unset.
	//
	// The difference is that this slice is appended to os.Environ() (see
	// execRunner.Run), so OMITTING a var does not clear it: any CORE_REF
	// already in the agent's own environment — a unit-file Environment=, an
	// operator's systemd-run --setenv — would be inherited straight through,
	// module-forge-build.sh's `export CORE_REF="${CORE_REF:-}"` would
	// faithfully forward it, and the build would pin to a commit the platform
	// never chose while stage15.sh logged "parent PINNED". That is the same
	// silently-wrong-provenance defect the pin exists to remove, running in
	// the other direction.
	//
	// Emitting it unconditionally makes the platform authoritative in both
	// states: exec dedups duplicate keys keeping the LAST, so a real pin
	// overrides an ambient one and an absent pin deterministically clears it.
	// stage15.sh reads empty as "no pin" via `[ -n "$core_ref" ]`.
	env = append(env, "CORE_REF="+bctx.CoreRef)
	return env
}

// fetchBuildContext calls GET config/ci_build_context?module=<slug> and
// decodes the {success, data} envelope every node_api endpoint uses. A
// non-2xx response (403 on either gate, 404/503 on resolution failures)
// surfaces its body text in the error — never a secret, since the
// controller returns those failures BEFORE resolving any credential.
func fetchBuildContext(client tasks.HTTPClient, module string) (*ciBuildContext, error) {
	resp, err := client.GetJSON("/api/v1/system/node_api/config/ci_build_context?module=" + url.QueryEscape(module))
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("ci_build_context status %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}

	var env struct {
		Success bool           `json:"success"`
		Data    ciBuildContext `json:"data"`
	}
	if err := json.Unmarshal(body, &env); err != nil {
		return nil, fmt.Errorf("decode ci_build_context: %w", err)
	}
	return &env.Data, nil
}

// embedCredential builds the token-authenticated MODULE_SOURCE_URL from the
// bare source_repo_url + source_token the platform returned as two separate
// JSON fields (deliberately never combined server-side — see the
// controller's CryptoMaterialSafety note). Uses url.URL.String(), which DOES
// include the plaintext password — that's required here (the script needs
// a working clone URL) but means this value must NEVER be logged; use
// url.URL.Redacted() if a masked form is ever needed for diagnostics.
func embedCredential(rawURL, token string) (string, error) {
	if token == "" {
		return rawURL, nil
	}
	u, err := url.Parse(rawURL)
	if err != nil {
		return "", fmt.Errorf("parse source_repo_url: %w", err)
	}
	u.User = url.UserPassword("x-access-token", token)
	return u.String(), nil
}

// parseBuildResult scans stdout from the LAST line backward for the first
// non-empty line and decodes it as the result JSON. CONFIRMED against Part
// A's landed module-forge-build.sh: it never uses --result-file unless
// asked (this handler doesn't pass that flag — the script's own doc header
// notes every diagnostic line is intentionally sent to stderr via `log()`,
// so stdout carries EXACTLY one line, the result JSON, in the success
// case). Scanning backward is therefore just defensive belt-and-suspenders,
// not load-bearing against any known script behavior.
func parseBuildResult(stdout []byte) (*moduleBuildResult, error) {
	lines := strings.Split(strings.TrimRight(string(stdout), "\n"), "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		line := strings.TrimSpace(lines[i])
		if line == "" {
			continue
		}
		dec := json.NewDecoder(strings.NewReader(line))
		dec.UseNumber()
		var r moduleBuildResult
		if err := dec.Decode(&r); err != nil {
			return nil, fmt.Errorf("last non-empty stdout line is not valid result JSON: %w", err)
		}
		return &r, nil
	}
	return nil, errors.New("module-forge-build.sh produced no output")
}

// logTail bounds stdout/stderr for inclusion in the task result — enough
// for operator diagnosis without bloating System::Task#events JSONB.
func logTail(stdout, stderr []byte) string {
	return "stdout: " + tailBytes(stdout, logTailMaxBytes) + "\nstderr: " + tailBytes(stderr, logTailStderrMaxBytes)
}

func tailBytes(b []byte, max int) string {
	if len(b) > max {
		b = b[len(b)-max:]
	}
	return strings.TrimSpace(string(b))
}
