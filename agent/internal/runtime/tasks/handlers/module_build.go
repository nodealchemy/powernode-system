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
	"regexp"
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
// for operator diagnosis without bloating System::Task#events JSONB. Every
// headed private-key block is removed from the WHOLE stream first (the same
// scrub-then-bound principle as scrubbedLogTail), so no cut can land inside
// one; the window cut then falls back to dropCutKeyBody for a body whose
// header was never in the stream. Shared by module_build, package_build and
// lint_discovery, which all get both.
func logTail(stdout, stderr []byte) string {
	return "stdout: " + tailBytes(removeKeyBlocks(stdout), logTailMaxBytes) + "\nstderr: " + tailBytes(removeKeyBlocks(stderr), logTailStderrMaxBytes)
}

func tailBytes(b []byte, max int) string {
	if len(b) <= max {
		return strings.TrimSpace(string(b))
	}
	return strings.TrimSpace(dropCutKeyBody(string(b[len(b)-max:])))
}

const (
	// logTailKeyBlockMarker stands in for a whole private-key block (BEGIN
	// through END, or a clipped BEGIN with its body) removed from a stream
	// before the window is cut (IMP-33ab99763220).
	logTailKeyBlockMarker = "[key material removed]"
	// logTailKeyBodyMarker stands in for a run of PEM-body-shaped lines that
	// a window cut left at its start, the header already outside the stream.
	logTailKeyBodyMarker = "[truncated key material removed]"
	// pemBlockMaxSpan bounds how far past a BEGIN header the END footer it
	// pairs with may sit. A real key must always fit, because one that does
	// not and cannot be clipped (every line prefixed, or an armor header
	// line) passes through WHOLE: RSA-16384 is ~12 KB bare and ~34 KB with a
	// 105-char per-line prefix, and a PGP private-key block with a photo ID
	// runs past 32 KiB, so the bound is 128 KiB. A header that merely
	// MENTIONS a key, with an unrelated footer further away, is treated as
	// clipped instead, so at most this much of the diagnostics between them
	// is lost (lost, not leaked).
	pemBlockMaxSpan = 128 << 10
)

var (
	// A private-key header / footer, in the RFC 7468 five-dash form (the
	// server sanitizer's class, so neither can span a line) and the RFC 4716
	// SSH2 four-dash-and-space form.
	pemHeaderRe = regexp.MustCompile(`-----BEGIN[A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----|---- BEGIN [A-Z0-9 ]*PRIVATE KEY ----`)
	pemFooterRe = regexp.MustCompile(`-----END[A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----|---- END [A-Z0-9 ]*PRIVATE KEY ----`)

	// One full line of a PEM body: 16..76 base64 characters and nothing else
	// (RFC 7468 wraps at 64, OpenSSH at 70), an RFC 1421 encryption header,
	// or a blank line. The lower bound is the server sanitizer's own: shorter
	// runs are ordinary words. Lines are matched after TrimSpace, so
	// indentation and trailing whitespace do not break a run.
	pemBodyLineRe = regexp.MustCompile(`^(?:[A-Za-z0-9+/=]{16,76}|(?:Proc-Type|DEK-Info):.*)?$`)
	// A body's LAST line is the base64 remainder, 4..64 chars: a short one
	// counts only when the END footer is the very next line.
	pemShortLineRe = regexp.MustCompile(`^[A-Za-z0-9+/=]{1,15}$`)
	// The window's first line is a FRAGMENT (the cut landed mid-line): any
	// length of base64 alphabet, including none, can be the end of a body line.
	pemFragmentRe = regexp.MustCompile(`^[A-Za-z0-9+/=]*$`)
	// The four-dash form is restricted to PRIVATE KEY like pemFooterRe, so a
	// log banner ("---- END OF BUILD LOG ----") is never taken for a footer.
	pemEndLineRe = regexp.MustCompile(`^(?:-----END[A-Z0-9 ]*-----|---- END [A-Z0-9 ]*PRIVATE KEY ----)$`)
)

// removeKeyBlocks replaces every headed private-key block in the stream with
// logTailKeyBlockMarker, in ONE forward pass whatever the number of headers:
// header and footer offsets are collected by two anchored regexes, each
// header is paired with the first footer after it (forward-only pointers,
// a header inside a removed span is skipped), and the span between them is
// replaced as a whole, so indentation (a YAML block scalar), a per-line
// prefix (a timestamped logger), JSON-escaped `\n`, a space-joined
// `echo $KEY`, trailing whitespace and CRLF all fall inside it and a key
// printed whole can never straddle the window cut. A header with no footer
// within pemBlockMaxSpan is CLIPPED (the stream ended mid-key, or the header
// was only mentioned): clippedBodyEnd consumes whole PEM-shaped lines after
// it and nothing else. The parsed build result is read from the raw stream by
// the caller, never from this copy.
//
// Stated residuals: a clipped key with a per-line prefix keeps its body
// (neither this pass nor the window fallback can see prefixed lines without a
// footer); a header mention with an unrelated footer within pemBlockMaxSpan
// loses the text between them (lost, not leaked); base64 of a whole PEM is
// not seen. A regex spanning header to footer was replaced by this pass
// because it cost O(headers x stream) when headers had no footer (measured:
// 65 s on 256 KiB of header lines).
func removeKeyBlocks(b []byte) []byte {
	if !bytes.Contains(b, []byte("PRIVATE KEY")) {
		return b
	}
	headers := pemHeaderRe.FindAllIndex(b, -1)
	if len(headers) == 0 {
		return b
	}
	footers := pemFooterRe.FindAllIndex(b, -1)
	out := make([]byte, 0, len(b))
	pos, fi, rejected := 0, 0, -1
	for _, h := range headers {
		if h[0] < pos {
			continue
		}
		for fi < len(footers) && footers[fi][0] < h[1] {
			fi++
		}
		var end int
		if fi < len(footers) && footers[fi][1]-h[0] <= pemBlockMaxSpan {
			end = footers[fi][1]
			fi++
		} else {
			end = clippedBodyEnd(b, h[1], &rejected)
		}
		out = append(out, b[pos:h[0]]...)
		out = append(out, logTailKeyBlockMarker...)
		pos = end
	}
	return append(out, b[pos:]...)
}

// clippedBodyEnd returns where the body of a header with no footer ends:
// from the header's end it consumes WHOLE lines (a separator plus the content
// up to, not including, the next separator) while they are PEM-shaped after
// TrimSpace: blank, an RFC 1421 header, a run of 16 or more base64
// characters with no upper bound (an unwrapped clipped body is taken whole),
// or the 4..12-character base64 remainder a wrapped body ends on when
// nothing but a line terminator follows it in the text. A separator is a
// real `\r?\n` or the literal `\n` / `\r\n` of a JSON-escaped dump that
// stopped mid-key, so a truncated one-line key is taken too. It stops at the
// first ordinary line, which stays intact, so the line after a clipped body
// is never glued to the marker or partly eaten. `rejected` remembers the
// ordinary line a previous header already stopped on, so a run of headers
// never re-reads it: every byte is examined once.
func clippedBodyEnd(b []byte, from int, rejected *int) int {
	end, prevWidth := from, 0
	for end < len(b) {
		sep := lineSeparator(b, end)
		if sep == 0 {
			break
		}
		lineStart := end + sep
		if lineStart == *rejected {
			break
		}
		lineEnd := lineStart
		for lineEnd < len(b) && b[lineEnd] != '\n' && b[lineEnd] != '\\' {
			lineEnd++
		}
		line := bytes.TrimSpace(b[lineStart:lineEnd])
		if !clippedBodyLine(line, prevWidth, onlyTerminatorFollows(b[lineEnd:])) {
			*rejected = lineStart
			break
		}
		prevWidth = len(line)
		end = lineEnd
	}
	return end
}

// lineSeparator is the width of the line separator at b[at]: a real LF or
// CRLF, or the escaped `\n` / `\r\n` of a JSON string; 0 if none.
func lineSeparator(b []byte, at int) int {
	switch {
	case b[at] == '\n':
		return 1
	case b[at] == '\r' && at+1 < len(b) && b[at+1] == '\n':
		return 2
	case b[at] == '\\' && at+1 < len(b) && b[at+1] == 'n':
		return 2
	case b[at] == '\\' && at+3 < len(b) && b[at+1] == 'r' && b[at+2] == '\\' && b[at+3] == 'n':
		return 4
	}
	return 0
}

// onlyTerminatorFollows: nothing after the line but at most one terminator.
// A stream clipped mid-key ends on its remainder; finished tool output ends
// with a newline; either way the remainder is the last thing in the text.
func onlyTerminatorFollows(rest []byte) bool {
	return len(rest) == 0 || string(rest) == "\n" || string(rest) == "\r\n"
}

// clippedBodyLine: a short remainder counts only after a line of a standard
// PEM wrap width (RFC 7468 64, OpenSSH 70, MIME 76) and at a base64 length
// (a multiple of 4), so a final short word after an unwrapped body ("next")
// is never taken.
func clippedBodyLine(line []byte, prevWidth int, last bool) bool {
	if len(line) == 0 || bytes.HasPrefix(line, []byte("Proc-Type:")) || bytes.HasPrefix(line, []byte("DEK-Info:")) {
		return true
	}
	for _, c := range line {
		if !(c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '+' || c == '/' || c == '=') {
			return false
		}
	}
	if len(line) >= 16 {
		return true
	}
	return last && len(line)%4 == 0 && (prevWidth == 64 || prevWidth == 70 || prevWidth == 76)
}

// dropCutKeyBody handles a window whose cut landed inside a PEM body whose
// BEGIN header was never in the stream (removeKeyBlocks has already taken
// every headed block), so the body lines at its start match no header-keyed
// pattern downstream (System::ShellOutputSanitizer keys on the header;
// System::StoredOutputRedactor strips a headerless body only at the start of
// ITS window, which is not where `stdout: ` / `\nstderr: ` put it).
//
// The run of leading body-shaped lines is dropped THROUGH the END footer, or
// to the first ordinary line when no footer appears, and replaced with
// logTailKeyBodyMarker. Conservative by construction: the run must be anchored
// by a full body-shaped line AFTER the first, or by an END footer — the first
// line is a fragment and never anchors alone, so a cut that lands on a
// base64-looking word or digest fragment of an ordinary line followed by
// ordinary lines is left exactly as it was, and the marker is never written
// for a lone fragment with a body still standing behind it. A first line that
// is not base64 (the cut landed in a Proc-Type header, or in a BEGIN line the
// block pass could not pair with a footer) is kept and the body after it is
// still stripped. Only ever called on a cut window.
func dropCutKeyBody(window string) string {
	lines := strings.SplitAfter(window, "\n")
	start, end, anchored := 0, 0, false
	for i, raw := range lines {
		line := strings.TrimSpace(raw)
		switch {
		case pemEndLineRe.MatchString(line):
			end, anchored = i+1, true
		case i == 0:
			if !pemFragmentRe.MatchString(line) {
				start = 1
			}
			end = 1
			continue
		case pemBodyLineRe.MatchString(line):
			anchored = anchored || line != ""
			end = i + 1
			continue
		case pemShortLineRe.MatchString(line) && i+1 < len(lines) && pemEndLineRe.MatchString(strings.TrimSpace(lines[i+1])):
			end = i + 1
			continue
		}
		break
	}
	if !anchored {
		return window
	}
	return strings.Join(lines[:start], "") + logTailKeyBodyMarker + "\n" + strings.Join(lines[end:], "")
}
