package handlers

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/runtime/tasks"
)

// ci.lint_discovery — improvement discovery's runner half (campaign 01a08c9b
// D1b). The platform leases a runner from the account's OWN pool and sends
// this task to that exact instance. For each repository the task names, the
// handler clones the repository and runs its linters with the repository's
// own bundle, then posts the RAW linter output to the lease-gated result
// endpoint. The platform parses it and files the findings. The platform never
// runs a repository's code in its own process.
//
// TWO PHASES, TWO PROCESSES, NEITHER PRIVILEGED. Repository code runs in the
// lint phase: a Gemfile evaluated by `bundle install`, rubocop plugins, an
// eslint config, node_modules/.bin. So:
//   - the credential exists ONLY in the clone phase's environment. git runs
//     no repository code during a clone (no hooks or filters apply, because
//     no config names any), and that process has exited before the lint
//     phase starts. An `unset` inside one process would not do: a child can
//     still read the parent's original environment from /proc;
//   - both phases run as the unprivileged sandbox uid/gid, with an
//     environment built from scratch (never os.Environ()), so repository code
//     cannot read the agent's root-only mTLS key or any root process's
//     environment, cannot fetch other repositories' credentials as this
//     instance, and cannot write /persist;
//   - each phase runs in its own PID namespace (and process group). When the
//     phase's first process exits or is killed, the kernel kills every
//     process left in that namespace, one that called setsid or
//     double-forked included, before the phase's exit is reported. So
//     nothing the repository started outlives its phase, and no process of
//     repository N is alive to read repository N+1's clone-phase environment.
//
// The credential reaches git ONLY as environment variables answered by the
// GIT_ASKPASS helper, for the one host the platform named. Every error and log
// text sent back is scrubbed of it (raw and encoded forms, before truncation),
// and a result whose output contains it is withheld rather than sent.
//
// The task result carries COUNTS ONLY: System::Task stores a completed task's
// result in its events JSONB, which is no place for a repository's findings.
const (
	lintCloneScript      = "/usr/local/bin/lint-discovery-clone.sh"
	lintDiscoveryScript  = "/usr/local/bin/lint-discovery.sh"
	lintDiscoveryAskpass = "/usr/local/bin/lint-discovery-askpass.sh"
	lintContextPath      = "/api/v1/system/node_api/config/ci_lint_context"
	lintResultPath       = "/api/v1/system/node_api/config/ci_lint_result"

	// Each repository gets its own empty directory under the workdir base,
	// removed when the repository is done. The base is disk-backed: bundle
	// install and npm ci need hundreds of MB, and a fleet node's / is a small
	// RAM-backed overlay (see lintWorkdirBase).
	lintWorkdirPrefix = "lint-discovery-"
	// The clone lands in this subdirectory; linter paths are relative to it.
	lintCloneDir = "src"

	// The unprivileged uid/gid both phases run as ("nobody").
	lintSandboxUID = 65534
	lintSandboxGID = 65534

	// The whole PATH repository code sees.
	lintSandboxPath = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

	// Upper bounds on one repository's phases. The real bounds come from the
	// lease deadline the platform hands out: each repository gets an equal
	// share of the time left (repoBudget), less lintPostMargin for results.
	lintCloneTimeout = 10 * time.Minute
	lintPhaseTimeout = 30 * time.Minute
	lintWaitDelay    = 10 * time.Second

	// The lint phase runs at most lintStepsPerPhase timed steps (bundle
	// install, rubocop, npm ci, tsc, eslint), each under `timeout -k`, so the
	// script always ends, and reports the linters that finished, before the
	// phase's own bound kills it (lintStepTimeout).
	lintStepsPerPhase = 5
	lintKillAfter     = 10 * time.Second
	lintPhaseSlack    = 30 * time.Second
	lintPostMargin    = time.Minute
	// A repository is not started with less than this left of its share.
	lintMinRepoBudget = 2 * time.Minute

	// Where the workdir base goes when the platform names none: the node's
	// persistent data mount when it is a filesystem of its own (see
	// lintPersistMount), else /var/lib (a host whose / is a real disk).
	// module-forge-build.sh resolves its build scratch the same way.
	lintPersistBase = "/persist/lint-discovery"
	lintVarLibBase  = "/var/lib/lint-discovery"

	// Repository code controls both streams, so neither may grow without
	// bound in the agent. The clone phase prints next to nothing on stdout.
	// The lint phase's stdout carries only the result line: at most
	// lintLinterCount linters, each at most the platform's output limit raw
	// (the script reports a bigger one as output_truncated and sends none of
	// it), JSON-escaped at up to lintEscapeFactor times its raw size. So that
	// bound follows the limit the platform hands out (lintResultStdoutMax).
	// stderr keeps its tail.
	lintCloneStdoutMaxBytes = 256 << 10
	lintStderrMaxBytes      = 256 << 10
	lintLinterCount         = 3
	lintEscapeFactor        = 2
	lintResultOverheadBytes = 64 << 10

	// Bounds on failure text, which ends up in the task record on the
	// all-failed path.
	lintFailureMaxBytes  = 2048
	lintFailuresMaxBytes = 8192
)

// LintExecer runs one phase of a repository's lint in the sandbox. A
// production handler uses sandboxRunner; tests substitute a recorder.
type LintExecer interface {
	// Prepare hands the empty workdir to the sandbox user.
	Prepare(workdir string) error
	// Run runs name with EXACTLY env, nothing inherited, in workdir. It keeps
	// at most stdoutMax bytes of stdout; more is an error.
	Run(ctx context.Context, name string, env []string, workdir string, stdoutMax int) (stdout, stderr []byte, err error)
}

// sandboxRunner runs each phase as the sandbox user in a PID namespace of its
// own (sandboxCommand). The zero value is the production runner.
//
// unprivileged is a TEST seam: it keeps the PID namespace, but creates it
// inside a user namespace that maps the calling uid, with no uid switch and
// no chown, so the real start, wait, namespace kill and overflow paths run in
// the gate without root. waitDelay, when set, replaces lintWaitDelay.
type sandboxRunner struct {
	unprivileged bool
	waitDelay    time.Duration
}

func (r sandboxRunner) Prepare(workdir string) error {
	if r.unprivileged {
		return nil
	}
	return os.Chown(workdir, lintSandboxUID, lintSandboxGID)
}

// Run needs no kill of its own after Wait. The phase's first process is its
// namespace's init, and the kernel kills every process left in the namespace
// before that process's exit is reported, so nothing can hold stdout open
// past it either: a WaitDelay expiry is a real failure, never forgiven.
func (r sandboxRunner) Run(ctx context.Context, name string, env []string, workdir string, stdoutMax int) ([]byte, []byte, error) {
	cmd := sandboxCommand(ctx, name, env, workdir)
	if r.unprivileged {
		unprivilegedNamespaces(cmd)
	}
	if r.waitDelay > 0 {
		cmd.WaitDelay = r.waitDelay
	}
	outBuf := &cappedBuffer{max: stdoutMax}
	errBuf := &cappedBuffer{max: lintStderrMaxBytes, keepTail: true}
	cmd.Stdout = outBuf
	cmd.Stderr = errBuf
	if err := cmd.Start(); err != nil {
		return nil, nil, err
	}
	err := cmd.Wait()
	if err == nil && outBuf.overflow {
		err = fmt.Errorf("stdout exceeded %d bytes", stdoutMax)
	}
	return outBuf.Bytes(), errBuf.Bytes(), err
}

// cappedBuffer keeps at most max bytes of one stream: the head (stdout) or
// the tail (stderr, where a failure's diagnosis lands). It never refuses a
// write, so a noisy process is not killed by a broken pipe; it only stops
// the agent's memory from growing with it.
type cappedBuffer struct {
	max      int
	keepTail bool
	buf      []byte
	overflow bool
}

func (b *cappedBuffer) Write(p []byte) (int, error) {
	n := len(p)
	if b.keepTail {
		b.buf = append(b.buf, p...)
		// Trim at twice the bound, so a long stream is copied once per max
		// bytes written rather than once per write.
		if len(b.buf) > 2*b.max {
			b.buf = append([]byte(nil), b.buf[len(b.buf)-b.max:]...)
			b.overflow = true
		}
		return n, nil
	}
	room := b.max - len(b.buf)
	if len(p) > room {
		p = p[:max(room, 0)]
		b.overflow = true
	}
	b.buf = append(b.buf, p...)
	return n, nil
}

func (b *cappedBuffer) Bytes() []byte {
	if b.keepTail && len(b.buf) > b.max {
		b.overflow = true
		return b.buf[len(b.buf)-b.max:]
	}
	return b.buf
}

// sandboxCommand builds one phase's command: exactly env (never
// os.Environ()), the sandbox uid/gid with no supplementary groups, its own
// PID namespace and process group, and the group killed when ctx ends, which
// kills the namespace's init and with it the whole namespace.
func sandboxCommand(ctx context.Context, name string, env []string, workdir string) *exec.Cmd {
	cmd := exec.CommandContext(ctx, name)
	cmd.Env = append([]string{}, env...)
	cmd.Dir = workdir
	cmd.SysProcAttr = &syscall.SysProcAttr{
		Setpgid:    true,
		Cloneflags: syscall.CLONE_NEWPID,
		Credential: &syscall.Credential{Uid: lintSandboxUID, Gid: lintSandboxGID, Groups: []uint32{}},
	}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
	cmd.WaitDelay = lintWaitDelay
	return cmd
}

type lintDiscoveryJob struct{}

type lintDiscoveryOptions struct {
	RunRef        string
	RepositoryIDs []string
}

// parseLintDiscoveryOptions validates task.Options. The platform sets
// run_ref (the lease id) and repository_ids when it creates the task.
func parseLintDiscoveryOptions(task *tasks.Task) (lintDiscoveryOptions, error) {
	runRef, _ := task.Options["run_ref"].(string)
	if runRef == "" {
		return lintDiscoveryOptions{}, errors.New("ci.lint_discovery: options.run_ref is required")
	}

	var ids []string
	switch raw := task.Options["repository_ids"].(type) {
	case []any:
		for _, v := range raw {
			if s, ok := v.(string); ok && s != "" {
				ids = append(ids, s)
			}
		}
	case []string:
		for _, s := range raw {
			if s != "" {
				ids = append(ids, s)
			}
		}
	}
	if len(ids) == 0 {
		return lintDiscoveryOptions{}, errors.New("ci.lint_discovery: options.repository_ids is required")
	}
	return lintDiscoveryOptions{RunRef: runRef, RepositoryIDs: ids}, nil
}

// lintRepository is one entry of GET config/ci_lint_context — see
// Api::V1::System::NodeApi::LintDiscoveryController#context.
type lintRepository struct {
	ID       string `json:"id"`
	CloneURL string `json:"clone_url"`
	Ref      string `json:"ref"`
	Username string `json:"username"`
	Token    string `json:"token"`
}

type lintContext struct {
	Repositories []lintRepository `json:"repositories"`
	// The platform's parse limit for one linter's raw output. The script
	// reports a linter over it as output_truncated instead of cutting it,
	// because the platform never parses a cut report.
	OutputLimitBytes int64 `json:"output_limit_bytes"`
	// The lease's deadline. Every phase's bound is derived from what is left
	// of it, so the runner finishes before the platform stops listening.
	DeadlineAt time.Time `json:"deadline_at"`
	// The platform's workdir base setting; empty when unset, and the agent
	// resolves a disk-backed one itself (resolveLintWorkdirBase).
	WorkdirBase string `json:"workdir_base"`
}

// lintLimits is what bounds one repository's run.
type lintLimits struct {
	outputLimit int64
	base        string
	budget      time.Duration
}

func (c *lintContext) secrets() []string {
	out := make([]string, 0, len(c.Repositories))
	for _, r := range c.Repositories {
		if r.Token != "" {
			out = append(out, r.Token)
		}
	}
	return out
}

// lintReport is one linter's entry in lint-discovery.sh's result line. The
// platform's parser (StaticAnalysisService.parse_output) reads `output` only
// when `status` is "ran"; every other status is a did-not-measure status.
type lintReport struct {
	Status     string `json:"status"`
	ExitStatus *int   `json:"exitstatus,omitempty"`
	Output     string `json:"output,omitempty"`
}

type lintScriptResult struct {
	Linters map[string]lintReport `json:"linters"`
}

func (h *ModuleBuildHandler) lintRunner() LintExecer {
	if h.Lint != nil {
		return h.Lint
	}
	return sandboxRunner{}
}

func (lintDiscoveryJob) run(ctx context.Context, h *ModuleBuildHandler, task *tasks.Task) (tasks.Result, error) {
	opts, err := parseLintDiscoveryOptions(task)
	if err != nil {
		return nil, err
	}
	if h.HTTP == nil {
		return nil, errors.New("ci.lint_discovery: no platform transport")
	}

	lctx, err := fetchLintContext(h.HTTP)
	if err != nil {
		return nil, fmt.Errorf("ci.lint_discovery: fetch lint context: %w", err)
	}
	if lctx.OutputLimitBytes <= 0 {
		return nil, errors.New("ci.lint_discovery: the lint context carried no output_limit_bytes")
	}
	if lctx.DeadlineAt.IsZero() {
		return nil, errors.New("ci.lint_discovery: the lint context carried no deadline_at")
	}
	base, err := h.lintWorkdirBase(lctx.WorkdirBase)
	if err != nil {
		return nil, fmt.Errorf("ci.lint_discovery: %w", err)
	}
	// D1b security R2: clear what an earlier agent process left behind.
	if _, err := sweepLintWorkdirs(base); err != nil {
		return nil, fmt.Errorf("ci.lint_discovery: %w", err)
	}
	secrets := lctx.secrets()

	byID := make(map[string]lintRepository, len(lctx.Repositories))
	for _, r := range lctx.Repositories {
		byID[r.ID] = r
	}

	// The TASK names the repositories; the context supplies how to reach
	// them. A repository the context carries but the task did not name is
	// never run.
	reported, failed := 0, 0
	var failures []string
	for i, id := range opts.RepositoryIDs {
		repo, ok := byID[id]
		if !ok {
			failed++
			failures = append(failures, id+": not in the lint context")
			continue
		}
		budget := repoBudget(lctx.DeadlineAt, len(opts.RepositoryIDs)-i)
		if budget < lintMinRepoBudget {
			failed++
			failures = append(failures, id+": not started, too little time left before the lease deadline")
			continue
		}
		lim := lintLimits{outputLimit: lctx.OutputLimitBytes, base: base, budget: budget}
		if err := lintOneRepository(ctx, h, opts.RunRef, repo, secrets, lim); err != nil {
			failed++
			failures = append(failures, id+": "+err.Error())
			continue
		}
		reported++
	}

	if reported == 0 {
		msg := "ci.lint_discovery: no repository reported: " + strings.Join(failures, "; ")
		return nil, errors.New(capText(scrubSecrets(msg, secrets...), lintFailuresMaxBytes))
	}
	return tasks.Result{"repositories": len(opts.RepositoryIDs), "reported": reported, "failed": failed}, nil
}

// lintOneRepository clones and lints one repository in a fresh temp workdir
// and posts its result. Any error it returns is scrubbed and bounded.
func lintOneRepository(ctx context.Context, h *ModuleBuildHandler, runRef string, repo lintRepository, secrets []string, lim lintLimits) error {
	cloneURL, host, err := validateCloneURL(repo.CloneURL)
	if err != nil {
		return err
	}

	workdir, err := os.MkdirTemp(lim.base, lintWorkdirPrefix+lintProcessToken+"-")
	if err != nil {
		return fmt.Errorf("workdir: %w", err)
	}
	defer os.RemoveAll(workdir)

	runner := h.lintRunner()
	if err := runner.Prepare(workdir); err != nil {
		return fmt.Errorf("workdir: %w", err)
	}

	started := time.Now()
	cloneBudget := min(lintCloneTimeout, lim.budget/4)
	cloneCtx, cancel := context.WithTimeout(ctx, cloneBudget)
	defer cancel()
	stdout, stderr, err := runner.Run(cloneCtx, lintCloneScript,
		lintCloneEnv(repo, cloneURL, host, workdir, cloneBudget-lintKillAfter), workdir, lintCloneStdoutMaxBytes)
	if err != nil {
		return phaseError("clone", err, stdout, stderr, secrets)
	}

	phaseBudget := min(lintPhaseTimeout, lim.budget-lintElapsed(started))
	step := lintStepTimeout(phaseBudget)
	if step < time.Second {
		return errors.New("too little time left before the lease deadline to lint")
	}
	lintCtx, cancelLint := context.WithTimeout(ctx, phaseBudget)
	defer cancelLint()
	stdout, stderr, err = runner.Run(lintCtx, lintDiscoveryScript, lintPhaseEnv(workdir, lim.outputLimit, step), workdir,
		lintResultStdoutMax(lim.outputLimit))
	if err != nil {
		return phaseError("lint", err, stdout, stderr, secrets)
	}

	parsed, err := parseLintScriptResult(stdout)
	if err != nil {
		return phaseError("lint result", err, stdout, stderr, secrets)
	}

	// Something printed the credential into a linter's output. Withhold the
	// whole result: the platform refuses it too, but it must not travel.
	if reportsCarrySecret(parsed.Linters, secrets) {
		return errors.New("credential found in the linter output; result withheld")
	}

	body, err := json.Marshal(map[string]any{
		"run_ref":       runRef,
		"repository_id": repo.ID,
		"base_path":     filepath.Join(workdir, lintCloneDir),
		"linters":       parsed.Linters,
	})
	if err != nil {
		return fmt.Errorf("encode result: %w", err)
	}
	if containsSecret(string(body), secrets) {
		return errors.New("credential found in the linter output; result withheld")
	}

	resp, err := h.HTTP.PostJSON(lintResultPath, body)
	if err != nil {
		return errors.New(capText(scrubSecrets("post result: "+err.Error(), secrets...), lintFailureMaxBytes))
	}
	defer resp.Body.Close()
	switch {
	case resp.StatusCode >= 200 && resp.StatusCode < 300:
		return nil
	case resp.StatusCode == http.StatusConflict:
		// Already reported for this lease (a re-dispatched task): the
		// platform has it, so this is not a failure.
		return nil
	default:
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		text := fmt.Sprintf("post result status %d: %s", resp.StatusCode, strings.TrimSpace(string(msg)))
		return errors.New(capText(scrubSecrets(text, secrets...), lintFailureMaxBytes))
	}
}

// validateCloneURL accepts an https URL with a host and no credentials in it.
// The error never repeats the URL, which could carry one.
func validateCloneURL(raw string) (cloneURL, host string, err error) {
	u, perr := url.Parse(raw)
	if perr != nil || u.Scheme != "https" || u.Host == "" || u.User != nil {
		return "", "", errors.New("clone URL rejected: it must be https, name a host and carry no credentials")
	}
	return u.String(), u.Host, nil
}

// lintBaseEnv is the whole environment the lint phase gets, and the base of
// the clone phase's: built from scratch, with HOME and every cache inside the
// workdir so nothing persists across repositories.
func lintBaseEnv(workdir string) []string {
	return []string{
		"PATH=" + lintSandboxPath,
		"LANG=C.UTF-8",
		"WORKDIR=" + workdir,
		"HOME=" + filepath.Join(workdir, "home"),
		"TMPDIR=" + filepath.Join(workdir, "tmp"),
		"XDG_CACHE_HOME=" + filepath.Join(workdir, "cache"),
	}
}

// lintPhaseEnv is the lint phase's whole environment: the base plus the
// platform's output limit, which the script needs to tell a report it may
// send from one it must report as output_truncated.
func lintPhaseEnv(workdir string, outputLimit int64, step time.Duration) []string {
	return append(lintBaseEnv(workdir),
		"LINT_MAX_OUTPUT_BYTES="+strconv.FormatInt(outputLimit, 10),
		"LINT_TIMEOUT_SECONDS="+wholeSeconds(step),
		"LINT_KILL_AFTER_SECONDS="+wholeSeconds(lintKillAfter))
}

func wholeSeconds(d time.Duration) string {
	return strconv.FormatInt(int64(d/time.Second), 10)
}

// repoBudget is one repository's share of the time left before the lease
// deadline, after lintPostMargin is set aside for the last result.
func repoBudget(deadline time.Time, reposLeft int) time.Duration {
	return (time.Until(deadline) - lintPostMargin) / time.Duration(max(reposLeft, 1))
}

// lintStepTimeout is the bound on each of the script's steps: every step at
// its bound plus its kill grace still ends inside the phase's own bound.
func lintStepTimeout(phase time.Duration) time.Duration {
	return (phase - lintPhaseSlack - lintStepsPerPhase*lintKillAfter) / lintStepsPerPhase
}

// lintWorkdirBase is where this task's per-repository workdirs go: the
// handler's test override as is, else the platform's setting, else the
// resolved default, created and checked to be disk-backed.
func (h *ModuleBuildHandler) lintWorkdirBase(configured string) (string, error) {
	if h.LintWorkdirBase != "" {
		return h.LintWorkdirBase, nil
	}
	base := resolveLintWorkdirBase(configured)
	if err := prepareLintWorkdirBase(base); err != nil {
		return "", err
	}
	return base, nil
}

func resolveLintWorkdirBase(configured string) string {
	if configured != "" {
		return configured
	}
	if distinctFilesystem(lintPersistMount, "/") {
		return lintPersistBase
	}
	return lintVarLibBase
}

func distinctFilesystem(a, b string) bool {
	var sa, sb syscall.Stat_t
	if syscall.Stat(a, &sa) != nil || syscall.Stat(b, &sb) != nil {
		return false
	}
	return sa.Dev != sb.Dev
}

// lintPersistMount is the node's persistent data mount; the default base goes
// under it when it is a filesystem of its own. Tests only override it.
var lintPersistMount = "/persist"

// lintElapsed measures how much of a repository's share a phase has used.
// Tests only override it.
var lintElapsed = time.Since

// lintProcessToken marks the workdirs this agent process creates, so a sweep
// never removes a workdir a task of this process is still using (D1b
// security R2).
var lintProcessToken = newLintProcessToken()

func newLintProcessToken() string {
	b := make([]byte, 6)
	if _, err := rand.Read(b); err != nil {
		return strconv.FormatInt(time.Now().UnixNano(), 36)
	}
	return hex.EncodeToString(b)
}

// Where a configured workdir base may live: strictly below one of these
// (D1b security R1). Tests only extend the list.
var lintBasePrefixes = []string{"/persist/", "/srv/", "/var/lib/"}

// lintBaseOwnerUID must own a base that already exists: root, which the agent
// runs as. Tests only override it.
var lintBaseOwnerUID uint32

// prepareLintWorkdirBase makes sure the base is safe to hand workdirs out of
// (D1b security R1). The agent runs as root and the path comes from platform
// configuration, so every check runs BEFORE anything is created or changed:
// the path is clean and below an allowed prefix, no component is a symlink,
// and the nearest existing directory is disk-backed. An existing base is used
// exactly as it is, and only if it is already safe (usableLintWorkdirBase). A
// missing one is created by the agent, checked again, and only then set to
// 0711 (each repository's workdir inside it is 0700, handed to the sandbox
// user).
func prepareLintWorkdirBase(base string) error {
	if err := validLintWorkdirBase(base); err != nil {
		return err
	}
	info, deepest, err := walkLintWorkdirBase(base)
	if err != nil {
		return err
	}
	if err := diskBackedDir(base, deepest); err != nil {
		return err
	}
	if info != nil {
		return usableLintWorkdirBase(base, info)
	}
	return createLintWorkdirBase(base)
}

// validLintWorkdirBase refuses a base that is not a clean absolute path
// strictly below an allowed prefix. It is lexical: nothing is looked up yet.
// A clean path never ends in "/", so it can never equal a prefix itself.
func validLintWorkdirBase(base string) error {
	if filepath.IsAbs(base) && filepath.Clean(base) == base {
		for _, prefix := range lintBasePrefixes {
			if strings.HasPrefix(base, prefix) {
				return nil
			}
		}
	}
	return fmt.Errorf("workdir base %q must be a clean absolute path strictly below one of %s",
		base, strings.Join(lintBasePrefixes, ", "))
}

// walkLintWorkdirBase Lstats each component of base from the root down and
// refuses a symlink or a non-directory anywhere on the way. It returns the
// base's own info (nil when the base does not exist yet) and the deepest
// directory that does exist.
func walkLintWorkdirBase(base string) (os.FileInfo, string, error) {
	deepest := "/"
	var info os.FileInfo
	for cur, rest := "/", strings.TrimPrefix(base, "/"); rest != ""; {
		part, after, _ := strings.Cut(rest, "/")
		cur, rest = filepath.Join(cur, part), after
		fi, err := os.Lstat(cur)
		if errors.Is(err, os.ErrNotExist) {
			return nil, deepest, nil
		}
		if err != nil {
			return nil, "", fmt.Errorf("workdir base: %w", err)
		}
		if fi.Mode()&os.ModeSymlink != 0 {
			return nil, "", fmt.Errorf("workdir base %s: %s is a symlink", base, cur)
		}
		if !fi.IsDir() {
			return nil, "", fmt.Errorf("workdir base %s: %s is not a directory", base, cur)
		}
		deepest, info = cur, fi
	}
	return info, deepest, nil
}

// diskBackedDir refuses a base whose filesystem, read on the deepest
// directory that exists, lives in RAM. For a missing base, that is the
// filesystem it would be created on.
func diskBackedDir(base, deepest string) error {
	var fs syscall.Statfs_t
	if err := syscall.Statfs(deepest, &fs); err != nil {
		return fmt.Errorf("workdir base: %w", err)
	}
	if !diskBackedFS(int64(fs.Type)) {
		return fmt.Errorf("workdir base %s is on a RAM-backed filesystem (type %#x); "+
			"set system.lint_discovery.workdir_base to a disk-backed path", base, fs.Type)
	}
	return nil
}

// usableLintWorkdirBase accepts an existing base without changing it: owned
// by root (lintBaseOwnerUID), with no mode bits beyond 0711 and no setuid,
// setgid or sticky bit, and traversable by the sandbox user.
func usableLintWorkdirBase(base string, info os.FileInfo) error {
	st, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return fmt.Errorf("workdir base %s: no owner to check", base)
	}
	if st.Uid != lintBaseOwnerUID {
		return fmt.Errorf("workdir base %s exists and is owned by uid %d, not root; it was left untouched",
			base, st.Uid)
	}
	switch mode := info.Mode(); {
	case mode&(os.ModeSetuid|os.ModeSetgid|os.ModeSticky) != 0, mode.Perm()&^0o711 != 0:
		return fmt.Errorf("workdir base %s exists with mode %v, more open than 0711; it was left untouched",
			base, mode)
	case mode.Perm()&0o001 == 0:
		return fmt.Errorf("workdir base %s exists with mode %v, which the sandbox user cannot traverse; "+
			"it was left untouched", base, mode)
	}
	return nil
}

// createLintWorkdirBase creates a missing base, checks the new path again,
// and sets 0711 through a descriptor opened without following a symlink, on
// the very directory it created.
func createLintWorkdirBase(base string) error {
	if err := os.MkdirAll(filepath.Dir(base), 0o755); err != nil {
		return fmt.Errorf("workdir base: %w", err)
	}
	// Mkdir, not MkdirAll: an entry that appeared since the check fails here.
	if err := os.Mkdir(base, 0o700); err != nil {
		return fmt.Errorf("workdir base: %w", err)
	}
	info, _, err := walkLintWorkdirBase(base)
	if err != nil {
		return err
	}
	if info == nil {
		return fmt.Errorf("workdir base %s vanished while it was being created", base)
	}
	fd, err := syscall.Open(base, syscall.O_RDONLY|syscall.O_DIRECTORY|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0)
	if err != nil {
		return fmt.Errorf("workdir base: %w", err)
	}
	defer syscall.Close(fd)
	var st syscall.Stat_t
	if err := syscall.Fstat(fd, &st); err != nil {
		return fmt.Errorf("workdir base: %w", err)
	}
	if created, ok := info.Sys().(*syscall.Stat_t); !ok || st.Dev != created.Dev || st.Ino != created.Ino {
		return fmt.Errorf("workdir base %s changed while it was being created", base)
	}
	if err := syscall.Fchmod(fd, 0o711); err != nil {
		return fmt.Errorf("workdir base: %w", err)
	}
	return nil
}

// sweepLintWorkdirs removes the workdirs earlier agent processes left under
// base (D1b security R2): a crash mid-repository would otherwise leave the
// account's source on persistent disk for good. It removes only directories
// named like a workdir and not marked with this process's token (a symlink
// or file carrying the name is not one the agent made, and stays), never the
// base, and never through a symlink: the base's path is walked first, and
// RemoveAll removes a stale workdir's own symlinks without following them.
func sweepLintWorkdirs(base string) (int, error) {
	info, _, err := walkLintWorkdirBase(base)
	if err != nil || info == nil {
		return 0, err
	}
	entries, err := os.ReadDir(base)
	if err != nil {
		return 0, fmt.Errorf("workdir base: %w", err)
	}
	mine := lintWorkdirPrefix + lintProcessToken + "-"
	removed := 0
	for _, e := range entries {
		name := e.Name()
		if !e.IsDir() || !strings.HasPrefix(name, lintWorkdirPrefix) || strings.HasPrefix(name, mine) {
			continue
		}
		if err := os.RemoveAll(filepath.Join(base, name)); err != nil {
			return removed, fmt.Errorf("workdir base: sweep %s: %w", name, err)
		}
		removed++
	}
	return removed, nil
}

// sweepLintWorkdirsAtStart is the sweep run once when the agent starts: only
// on a base that already exists and passes every check prepareLintWorkdirBase
// makes of an existing base (the allowlist, the walk, disk backing and
// usableLintWorkdirBase). It never creates the base.
func sweepLintWorkdirsAtStart(base string) (int, error) {
	if err := validLintWorkdirBase(base); err != nil {
		return 0, err
	}
	info, deepest, err := walkLintWorkdirBase(base)
	if err != nil || info == nil {
		return 0, err
	}
	if err := diskBackedDir(base, deepest); err != nil {
		return 0, err
	}
	if err := usableLintWorkdirBase(base, info); err != nil {
		return 0, err
	}
	return sweepLintWorkdirs(base)
}

// lintStartSweepDone is told when the start-up sweep has finished. Tests
// only override it, to wait for the sweep.
var lintStartSweepDone = func(int, error) {}

// sweepLintWorkdirsAtStart is the start-up sweep of the handler's base: the
// test override when one is set, else the default base. A configured base is
// swept before each lint task, since only the task's context names it.
func (h *ModuleBuildHandler) sweepLintWorkdirsAtStart() (int, error) {
	base := h.LintWorkdirBase
	if base == "" {
		base = resolveLintWorkdirBase("")
	}
	return sweepLintWorkdirsAtStart(base)
}

// Filesystem magic numbers (statfs f_type) that live in RAM: tmpfs, ramfs,
// and the overlay a pivot-booted node's / is.
const (
	fsTmpfsMagic   = 0x01021994
	fsRamfsMagic   = 0x858458f6
	fsOverlayMagic = 0x794c7630
)

func diskBackedFS(fsType int64) bool {
	switch fsType {
	case fsTmpfsMagic, fsRamfsMagic, fsOverlayMagic:
		return false
	}
	return true
}

// unprivilegedNamespaces swaps the uid switch for a user namespace mapping
// the calling uid and gid to root inside it, which is what lets an
// unprivileged process create the PID namespace. Tests only.
func unprivilegedNamespaces(cmd *exec.Cmd) {
	attr := cmd.SysProcAttr
	attr.Credential = nil
	attr.Cloneflags |= syscall.CLONE_NEWUSER
	attr.UidMappings = []syscall.SysProcIDMap{{ContainerID: 0, HostID: os.Getuid(), Size: 1}}
	attr.GidMappings = []syscall.SysProcIDMap{{ContainerID: 0, HostID: os.Getgid(), Size: 1}}
	attr.GidMappingsEnableSetgroups = false
}

// lintResultStdoutMax bounds the lint phase's stdout: every linter at the
// limit, JSON-escaped, plus the line's own framing.
func lintResultStdoutMax(outputLimit int64) int {
	return int(outputLimit)*lintLinterCount*lintEscapeFactor + lintResultOverheadBytes
}

// lintCloneEnv adds the clone's inputs. Only the platform's settings apply:
// no system or user git config (a credential.helper there could store the
// token), https only, no redirects, no credential helper, and a stall bound.
func lintCloneEnv(repo lintRepository, cloneURL, host, workdir string, timeout time.Duration) []string {
	return append(lintBaseEnv(workdir),
		"LINT_CLONE_TIMEOUT_SECONDS="+wholeSeconds(timeout),
		"LINT_KILL_AFTER_SECONDS="+wholeSeconds(lintKillAfter),
		"REPO_URL="+cloneURL,
		"REPO_REF="+repo.Ref,
		"GIT_ASKPASS="+lintDiscoveryAskpass,
		"GIT_TERMINAL_PROMPT=0",
		"LINT_GIT_HOST="+host,
		"LINT_GIT_USERNAME="+repo.Username,
		"LINT_GIT_TOKEN="+repo.Token,
		"GIT_CONFIG_NOSYSTEM=1",
		"GIT_CONFIG_GLOBAL=/dev/null",
		"GIT_ALLOW_PROTOCOL=https",
		"GIT_CONFIG_COUNT=2",
		"GIT_CONFIG_KEY_0=http.followRedirects",
		"GIT_CONFIG_VALUE_0=false",
		"GIT_CONFIG_KEY_1=credential.helper",
		"GIT_CONFIG_VALUE_1=",
		"GIT_HTTP_LOW_SPEED_LIMIT=1000",
		"GIT_HTTP_LOW_SPEED_TIME=60",
	)
}

// phaseError reports a failed phase: scrubbed first, then bounded.
func phaseError(phase string, err error, stdout, stderr []byte, secrets []string) error {
	text := fmt.Sprintf("%s: %s (log_tail: %s)", phase, scrubSecrets(err.Error(), secrets...),
		scrubbedLogTail(stdout, stderr, secrets...))
	return errors.New(capText(text, lintFailureMaxBytes))
}

func reportsCarrySecret(linters map[string]lintReport, secrets []string) bool {
	for key, r := range linters {
		if containsSecret(key, secrets) || containsSecret(r.Status, secrets) || containsSecret(r.Output, secrets) {
			return true
		}
	}
	return false
}

func capText(s string, max int) string {
	if len(s) <= max {
		return s
	}
	return s[:max] + " …(truncated)"
}

// fetchLintContext calls GET config/ci_lint_context. The platform refuses
// (403) unless this instance holds an active lint_discovery lease, and
// answers a refusal before it resolves any credential, so an error body
// carries no secret.
func fetchLintContext(client tasks.HTTPClient) (*lintContext, error) {
	resp, err := client.GetJSON(lintContextPath)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("ci_lint_context status %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}

	var env struct {
		Success bool        `json:"success"`
		Data    lintContext `json:"data"`
	}
	if err := json.Unmarshal(body, &env); err != nil {
		return nil, fmt.Errorf("decode ci_lint_context: %w", err)
	}
	return &env.Data, nil
}

// parseLintScriptResult decodes the last non-empty stdout line. The script
// sends every diagnostic to stderr, so stdout carries exactly that line.
func parseLintScriptResult(stdout []byte) (*lintScriptResult, error) {
	lines := strings.Split(strings.TrimRight(string(stdout), "\n"), "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		line := strings.TrimSpace(lines[i])
		if line == "" {
			continue
		}
		var r lintScriptResult
		if err := json.Unmarshal([]byte(line), &r); err != nil {
			return nil, fmt.Errorf("last non-empty stdout line is not valid result JSON: %w", err)
		}
		if r.Linters == nil {
			r.Linters = map[string]lintReport{}
		}
		return &r, nil
	}
	return nil, errors.New("lint-discovery.sh produced no output")
}
