package handlers

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"time"
	"unicode/utf8"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/runtime/tasks"
	"github.com/nodealchemy/powernode-system/agent/internal/taskguard"
)

// ProbeNodeInspectHandler is the routine, READ-ONLY node inspection task
// (IMP-52762a704a3d). It answers "what is this node doing" (wireguard state,
// routes and VRFs, the nft ruleset, a unit's journal and unit file, a unit's
// capabilities, a file's stat) without anyone needing a root shell.
//
// It is the routine sibling of system_out_of_band_exec (IMP-9ce0ed39c557) and
// shares nothing with it: that verb runs an operator's arbitrary command over
// ssh behind an approval, this one runs one of seven FIXED collectors and is
// governed auto_approve. It does not touch ssh.go, and takes no command, no
// flag and no path except the validated few below. The commands go through the
// same injected mount.Runner probe.module_smoke uses, so a test can never
// execute a real wg, ip, nft, journalctl or systemctl.
//
// Arguments, all validated here because the agent must not assume the control
// plane is honest (package taskguard states why): every collector declares the
// option keys it accepts and any other key is REFUSED, not ignored, so a
// payload cannot smuggle a flag or a command past a collector that would
// otherwise never read it.
//
// A refused argument is a task error (nothing runs). A collector whose TOOL
// fails (nft absent, wireguard not loaded) is an honest ok:false result.
//
// Everything that leaves the node is bounded (inspectMaxOutputBytes per
// collector) and passes through scrubSecrets, the same scrubber ci.module_build
// applies to a job's log: see inspectScrub for how its secret list is built.
type ProbeNodeInspectHandler struct {
	deps tasks.Dependencies
}

// RegisterProbeNodeInspect binds the probe.node_inspect command.
func RegisterProbeNodeInspect(r *tasks.Registry, deps tasks.Dependencies) {
	r.Register("probe.node_inspect", &ProbeNodeInspectHandler{deps: deps})
}

const (
	// inspectMaxOutputBytes bounds the text of one collector's result. It is a
	// budget over ALL of a collector's sections, split evenly between them.
	inspectMaxOutputBytes = 64 * 1024

	inspectDefaultJournalLines = 100
	inspectMaxJournalLines     = 500

	// inspectStatusReadBytes bounds a /proc/<pid>/status read (it is ~1.5 KiB).
	inspectStatusReadBytes = 64 * 1024

	// inspectReadCapBytes is how much of a command's stdout is ever read. It is
	// four times the result budget so that scrubbing, which needs the whole text
	// a secret could straddle, has room to work before the result is bounded; the
	// command is killed once it is exceeded (mount.BoundedRunner).
	inspectReadCapBytes = 4 * inspectMaxOutputBytes

	// inspectProbeReadBytes bounds the one-word answers (LoadState, MainPID).
	inspectProbeReadBytes = 4096
)

// The host locations file_stat and caps read directly rather than through a
// command. Vars with a Set...ForTest seam, never consts: agent tests have
// mutated a live /persist before, and these are the only two places this
// handler reads the machine itself. inspectFSRoot is the directory standing in
// for "/", so a test points both at a sandbox and can never see the real host.
var (
	inspectFSRoot   = "/"
	inspectProcRoot = "/proc"

	// inspectHashMaxBytes is the largest file file_stat will hash: a module
	// image can be gigabytes, and hashing it would stall the task loop.
	inspectHashMaxBytes int64 = 256 << 20
)

// inspectCommandTimeout bounds each command, and the whole of a file_stat: a
// wedged nft or journalctl, or a file on an unreachable mount, must not hold the
// agent's only task slot (the runtime runs Concurrency 1 with no per-handler
// deadline). A var so a test can shorten it.
var inspectCommandTimeout = 20 * time.Second

// SetInspectDeadlineForTest shortens the per-command and file_stat deadline.
func SetInspectDeadlineForTest(d time.Duration) (restore func()) {
	prev := inspectCommandTimeout
	inspectCommandTimeout = d
	return func() { inspectCommandTimeout = prev }
}

// inspectFileStatFn is the seam the deadline wrapper calls, so a test can
// install one that never returns (a read stuck in D-state on a dead export).
var inspectFileStatFn = inspectFileStat

// SetInspectFileStatForTest replaces the file_stat implementation.
func SetInspectFileStatForTest(fn func(string) (tasks.Result, error)) (restore func()) {
	prev := inspectFileStatFn
	inspectFileStatFn = fn
	return func() { inspectFileStatFn = prev }
}

// inspectBeforeOpenHook runs between the path being resolved and judged and the
// open, the window a swap would exploit. Nil in production.
var inspectBeforeOpenHook func()

// SetInspectBeforeOpenHookForTest installs a function that runs in that window,
// so a test can swap a path component there deterministically.
func SetInspectBeforeOpenHookForTest(fn func()) (restore func()) {
	prev := inspectBeforeOpenHook
	inspectBeforeOpenHook = fn
	return func() { inspectBeforeOpenHook = prev }
}

// inspectMaxWedged bounds the goroutines file_stat may leak. A read stuck in
// D-state cannot be interrupted, so the deadline abandons it rather than stops
// it; past this many still-blocked ones a new call is refused at once instead of
// adding another.
const inspectMaxWedged = 4

var inspectWedged int32

func inspectWedgedCount() int { return int(atomic.LoadInt32(&inspectWedged)) }

// SetInspectRootsForTest points the handler's filesystem and /proc roots at
// sandbox directories, returning a restore func.
func SetInspectRootsForTest(fsRoot, procRoot string) (restore func()) {
	prevFS, prevProc := inspectFSRoot, inspectProcRoot
	inspectFSRoot, inspectProcRoot = fsRoot, procRoot
	return func() { inspectFSRoot, inspectProcRoot = prevFS, prevProc }
}

// SetInspectHashMaxBytesForTest lowers the file_stat hashing ceiling.
func SetInspectHashMaxBytesForTest(n int64) (restore func()) {
	prev := inspectHashMaxBytes
	inspectHashMaxBytes = n
	return func() { inspectHashMaxBytes = prev }
}

// nodeInspectCollectors is the FIXED allow-list: collector name -> the option
// keys it accepts (besides "collector"). MUST mirror
// System::NodeInspection::COLLECTORS (extensions/system/server/app/services/
// system/node_inspection.rb), same names and same keys. A collector added here
// is a new read primitive on a root agent: re-derive the auto_approve verb for
// probe.node_inspect before shipping it.
var nodeInspectCollectors = map[string][]string{
	"wg_status": {"interface"},
	"routes":    {},
	"nft":       {"scope"},
	"journal":   {"unit", "lines"},
	"unit":      {"unit"},
	"caps":      {"unit"},
	"file_stat": {"path"},
}

func nodeInspectCollectorNames() []string {
	names := make([]string, 0, len(nodeInspectCollectors))
	for name := range nodeInspectCollectors {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}

// nftScopes are the two things `nft list` is asked for.
var nftScopes = map[string][]string{
	"ruleset": {"list", "ruleset"},
	"chains":  {"list", "chains"},
}

type nodeInspectRequest struct {
	Collector string
	Interface string
	Unit      string
	Scope     string
	Path      string
	Lines     int
}

// parseNodeInspectOptions validates task.Options. Pure (no I/O), so every
// refusal is unit-testable without a runner.
func parseNodeInspectOptions(task *tasks.Task) (nodeInspectRequest, error) {
	var req nodeInspectRequest
	collector, err := inspectStringOption(task.Options, "collector", true)
	if err != nil {
		return req, err
	}
	declared, known := nodeInspectCollectors[collector]
	if !known {
		return req, taskguard.Refused("collector", "is not one of "+strings.Join(nodeInspectCollectorNames(), ", "), collector)
	}
	req.Collector = collector

	// Refuse, do not ignore, a key this collector does not declare.
	for key := range task.Options {
		if key != "collector" && !containsString(declared, key) {
			return req, taskguard.Refused("options."+key, "is not accepted by the "+collector+" collector", "")
		}
	}

	switch collector {
	case "wg_status":
		if req.Interface, err = inspectStringOption(task.Options, "interface", true); err != nil {
			return req, err
		}
		if err = taskguard.InterfaceName("interface", req.Interface); err != nil {
			return req, err
		}
	case "nft":
		req.Scope = "ruleset"
		if _, present := task.Options["scope"]; present {
			if req.Scope, err = inspectStringOption(task.Options, "scope", true); err != nil {
				return req, err
			}
		}
		if _, ok := nftScopes[req.Scope]; !ok {
			return req, taskguard.Refused("scope", "must be ruleset or chains", req.Scope)
		}
	case "journal", "unit", "caps":
		if req.Unit, err = inspectStringOption(task.Options, "unit", true); err != nil {
			return req, err
		}
		if err = taskguard.SystemdUnit("unit", req.Unit); err != nil {
			return req, err
		}
		if collector == "journal" {
			if req.Lines, err = inspectLinesOption(task.Options); err != nil {
				return req, err
			}
		}
	case "file_stat":
		if req.Path, err = inspectStringOption(task.Options, "path", true); err != nil {
			return req, err
		}
		if err = taskguard.InspectFilePath("path", req.Path); err != nil {
			return req, err
		}
	}
	return req, nil
}

// inspectStringOption reads a string option. A value of any other type is a
// refusal: a JSON number or object must not be coerced into an argv element.
func inspectStringOption(opts map[string]any, key string, required bool) (string, error) {
	raw, present := opts[key]
	if !present || raw == nil {
		if required {
			return "", taskguard.Refused("options."+key, "is required", "")
		}
		return "", nil
	}
	s, ok := raw.(string)
	if !ok {
		return "", taskguard.Refused("options."+key, "must be a string", "")
	}
	return s, nil
}

// inspectLinesOption reads the journal line count: a whole number in
// 1..inspectMaxJournalLines, defaulting to inspectDefaultJournalLines when
// absent. JSON decoding yields float64; a Go-native int is accepted too.
func inspectLinesOption(opts map[string]any) (int, error) {
	raw, present := opts["lines"]
	if !present || raw == nil {
		return inspectDefaultJournalLines, nil
	}
	var n float64
	switch v := raw.(type) {
	case float64:
		n = v
	case int:
		n = float64(v)
	default:
		return 0, taskguard.Refused("options.lines", "must be a whole number", "")
	}
	if n != math.Trunc(n) || math.IsInf(n, 0) || math.IsNaN(n) {
		return 0, taskguard.Refused("options.lines", "must be a whole number", "")
	}
	if n < 1 || n > inspectMaxJournalLines {
		return 0, taskguard.Refused("options.lines", fmt.Sprintf("must be between 1 and %d", inspectMaxJournalLines), strconv.FormatFloat(n, 'f', -1, 64))
	}
	return int(n), nil
}

// Execute runs the requested collector.
func (h *ProbeNodeInspectHandler) Execute(ctx context.Context, task *tasks.Task) (tasks.Result, error) {
	req, err := parseNodeInspectOptions(task)
	if err != nil {
		return nil, fmt.Errorf("probe.node_inspect: %w", err)
	}
	// file_stat reads the filesystem directly and needs no runner; every other
	// collector does, and a missing one is a wiring bug, not a refusal.
	if req.Collector != "file_stat" && h.deps.MountRunner == nil {
		return nil, errors.New("probe.node_inspect: no mount runner")
	}
	runner := h.deps.MountRunner

	var res tasks.Result
	switch req.Collector {
	case "wg_status":
		res = inspectSections(ctx, runner, req.Collector, []inspectStep{
			{argv: []string{"wg", "show", req.Interface}, post: dropWgKeyLines},
		})
		res["interface"] = req.Interface
	case "routes":
		res = inspectSections(ctx, runner, req.Collector, []inspectStep{
			{argv: []string{"ip", "vrf", "show"}},
			{argv: []string{"ip", "-4", "route", "show", "table", "all"}},
			{argv: []string{"ip", "-6", "route", "show", "table", "all"}},
			{argv: []string{"ip", "-4", "rule", "show"}},
			{argv: []string{"ip", "-6", "rule", "show"}},
		})
	case "nft":
		res = inspectSections(ctx, runner, req.Collector, []inspectStep{
			{argv: append([]string{"nft"}, nftScopes[req.Scope]...)},
		})
	case "journal":
		if err := requireUnitExists(ctx, runner, req.Unit); err != nil {
			return nil, err
		}
		lines := req.Lines
		res = inspectSections(ctx, runner, req.Collector, []inspectStep{{
			// -r prints the newest line first, so the bounded read below keeps the
			// newest lines and the cut loses the oldest.
			argv:        []string{"journalctl", "-u", req.Unit, "-n", strconv.Itoa(lines), "-r", "--no-pager", "-o", "short-iso"},
			maxLines:    lines,
			fromEnd:     true,
			newestFirst: true,
		}})
		res["unit"] = req.Unit
	case "unit":
		if err := requireUnitExists(ctx, runner, req.Unit); err != nil {
			return nil, err
		}
		res = inspectSections(ctx, runner, req.Collector, []inspectStep{
			{argv: []string{"systemctl", "--no-pager", "cat", req.Unit}},
		})
		res["unit"] = req.Unit
	case "caps":
		if err := requireUnitExists(ctx, runner, req.Unit); err != nil {
			return nil, err
		}
		res = inspectCaps(ctx, runner, req.Unit)
	case "file_stat":
		res, err = inspectFileStatBounded(req.Path)
		if err != nil {
			return nil, fmt.Errorf("probe.node_inspect: %w", err)
		}
	}
	return res, nil
}

// requireUnitExists refuses a well-formed unit name that is not a unit on this
// node. `systemctl show -p LoadState` answers "not-found" for one and does not
// glob or expand shorthand, and the name has already passed SystemdUnit.
func requireUnitExists(ctx context.Context, runner mount.Runner, unit string) error {
	out, _, err := inspectRun(ctx, runner, inspectProbeReadBytes, "systemctl", "show", "-p", "LoadState", "--value", unit)
	if err != nil {
		// The runner error echoes the tool's stderr, which can echo a secret.
		msg, _ := inspectBound(inspectScrub(err.Error()), 2048, false)
		return fmt.Errorf("probe.node_inspect: cannot confirm unit %q exists: %s", unit, msg)
	}
	state := strings.TrimSpace(string(out))
	if state == "" || state == "not-found" {
		return fmt.Errorf("probe.node_inspect: %w", taskguard.Refused("unit", "is not a unit on this node", unit))
	}
	return nil
}

// inspectRun runs one command through the runner's BOUNDED read when it has
// one (mount.ExecRunner does), and reports whether the output was cut at max.
// A runner without it falls back to Output, whose result is cut after the fact,
// so the result stays bounded either way.
func inspectRun(ctx context.Context, runner mount.Runner, max int, name string, args ...string) ([]byte, bool, error) {
	cctx, cancel := context.WithTimeout(ctx, inspectCommandTimeout)
	defer cancel()
	if bounded, ok := runner.(mount.BoundedRunner); ok {
		return bounded.OutputBounded(cctx, max, name, args...)
	}
	out, err := runner.Output(cctx, name, args...)
	if err != nil {
		return nil, false, err
	}
	if len(out) > max {
		return out[:max], true, nil
	}
	return out, false, nil
}

// === command collectors ===

// inspectStep is one command of a collector: its argv (fixed by the collector,
// never assembled from a free-form option), an optional transform applied to
// the raw output BEFORE scrubbing, and the journal's line cap.
type inspectStep struct {
	argv     []string
	post     func(string) (string, []string)
	maxLines int
	// fromEnd keeps the newest text when a bound cuts: a log's tail is what an
	// operator wants, a static dump's head is.
	fromEnd bool
	// newestFirst says the command prints newest first (journalctl -r), so a
	// read cut at the cap loses the OLDEST lines; the text is put back into
	// chronological order before it is returned.
	newestFirst bool
}

type inspectSection struct {
	Name      string `json:"name"`
	Command   string `json:"command"`
	OK        bool   `json:"ok"`
	Output    string `json:"output"`
	Truncated bool   `json:"truncated"`
	Error     string `json:"error,omitempty"`
}

func inspectSections(ctx context.Context, runner mount.Runner, collector string, steps []inspectStep) tasks.Result {
	budget := inspectMaxOutputBytes / len(steps)
	out := make([]inspectSection, 0, len(steps))
	allOK := true
	for _, step := range steps {
		sec := inspectStepResult(ctx, runner, step, budget)
		if !sec.OK {
			allOK = false
		}
		out = append(out, sec)
	}
	return tasks.Result{"collector": collector, "ok": allOK, "sections": out}
}

func inspectStepResult(ctx context.Context, runner mount.Runner, step inspectStep, budget int) inspectSection {
	command := strings.Join(step.argv, " ")
	sec := inspectSection{Name: command, Command: command}
	raw, cutRead, err := inspectRun(ctx, runner, inspectReadCapBytes, step.argv[0], step.argv[1:]...)
	if err != nil {
		// Runner errors echo the tool's stderr, which can echo a secret.
		sec.Error, _ = inspectBound(inspectScrub(err.Error()), 2048, false)
		return sec
	}
	text := string(raw)
	if cutRead {
		// The cut can land mid-line, and a partial line is worse than none: it
		// can hold half a secret the patterns no longer see whole.
		if i := strings.LastIndexByte(text, '\n'); i >= 0 {
			text = text[:i+1]
		}
	}
	var extra []string
	if step.post != nil {
		text, extra = step.post(text)
	}
	// Scrub the WHOLE text, then bound it, so a secret that straddles the cut
	// cannot leave a fragment behind.
	text = inspectScrub(text, extra...)
	if step.newestFirst {
		// Newest first: the first maxLines lines ARE the newest.
		if step.maxLines > 0 {
			text = firstLines(text, step.maxLines)
		}
		text = reverseLines(text)
	} else if step.maxLines > 0 {
		text = lastLines(text, step.maxLines)
	}
	bounded, cutText := inspectBound(text, budget, step.fromEnd)
	sec.Output, sec.Truncated = bounded, cutText
	if cutRead && !cutText {
		sec.Truncated = true
		if step.fromEnd {
			sec.Output = "[truncated: older output omitted]\n" + bounded
		} else {
			sec.Output = bounded + "\n[truncated]"
		}
	}
	sec.OK = true
	return sec
}

// reverseLines reverses the line order of text (a trailing newline is kept).
func reverseLines(text string) string {
	if text == "" {
		return text
	}
	lines := strings.Split(strings.TrimSuffix(text, "\n"), "\n")
	for i, j := 0, len(lines)-1; i < j; i, j = i+1, j-1 {
		lines[i], lines[j] = lines[j], lines[i]
	}
	return strings.Join(lines, "\n") + "\n"
}

// firstLines keeps the first n lines.
func firstLines(text string, n int) string {
	lines := strings.Split(strings.TrimRight(text, "\n"), "\n")
	if len(lines) <= n {
		return text
	}
	return strings.Join(lines[:n], "\n") + "\n"
}

// lastLines keeps the final n lines. The cap holds on what comes BACK, so a
// journalctl that ignored -n cannot widen the result.
func lastLines(text string, n int) string {
	lines := strings.Split(strings.TrimRight(text, "\n"), "\n")
	if len(lines) <= n {
		return text
	}
	return strings.Join(lines[len(lines)-n:], "\n") + "\n"
}

// inspectBound cuts text to at most max bytes on a UTF-8 boundary, keeping the
// head or (fromEnd) the tail, and marks the cut.
func inspectBound(text string, max int, fromEnd bool) (string, bool) {
	if len(text) <= max {
		return text, false
	}
	if fromEnd {
		cut := text[len(text)-max:]
		for len(cut) > 0 && !utf8.RuneStart(cut[0]) {
			cut = cut[1:]
		}
		if i := strings.IndexByte(cut, '\n'); i >= 0 && i < len(cut)-1 {
			cut = cut[i+1:] // start on a whole line
		}
		return "[truncated: older output omitted]\n" + cut, true
	}
	cut := text[:max]
	for len(cut) > 0 && !utf8.ValidString(cut) {
		cut = cut[:len(cut)-1]
	}
	if i := strings.LastIndexByte(cut, '\n'); i > 0 {
		cut = cut[:i+1] // end on a whole line
	}
	return cut + "\n[truncated]", true
}

// === secret handling ===

// A wg key line: `wg show` prints "(hidden)" for these, but a private key must
// not depend on that, so the line is dropped whatever it holds.
var wgKeyLine = regexp.MustCompile(`(?im)^[ \t]*(?:private|preshared)[ _-]?key[ \t]*[:=][ \t]*(\S*)[^\n]*(?:\n|\z)`)

// dropWgKeyLines removes every private-key and preshared-key line from `wg
// show` output and returns the values it saw, so inspectScrub can also remove
// them wherever else they were echoed. Public keys, which `wg show` prints on
// "public key:" and "peer:" lines, are not secret and stay.
func dropWgKeyLines(text string) (string, []string) {
	var values []string
	for _, m := range wgKeyLine.FindAllStringSubmatch(text, -1) {
		if v := m[1]; v != "" && v != "(hidden)" && v != "(none)" {
			values = append(values, v)
		}
	}
	return wgKeyLine.ReplaceAllString(text, ""), values
}

// inspectSecretPattern finds secret VALUES in text: the value is capture group 1,
// or the whole match when the pattern has no group. minLen drops short matches
// that are more likely words than secrets (scrubSecrets itself ignores values
// under four bytes).
type inspectSecretPattern struct {
	re     *regexp.Regexp
	minLen int
	// skipIf drops a match whose text contains it (case-insensitive): a public
	// key is not a secret.
	skipIf string
}

// nameValue is a name-then-value tail: an optionally quoted delimiter, then a
// quoted string or a bare run.
const nameValue = `["']?[ \t]*[:=][ \t]*("[^"\n]*"|'[^'\n]*'|[^\s"',;]+)`

// inspectSecretPatterns MIRRORS the credential shapes of the server's
// System::ShellOutputSanitizer (server/app/services/system/
// shell_output_sanitizer.rb), so the node and the control plane agree on what a
// secret looks like. The agent must scrub BEFORE sending, because the raw result
// is stored in the task's completed event; a shape only the server catches is a
// shape stored in the clear. What differs from the server is only that these
// yield the VALUES for scrubSecrets, the scrubber this node already has, rather
// than replacing text themselves. Keep the two in step.
//
// Two of the server's patterns have no counterpart here on purpose: the
// x-vault-token header and aws_secret_access_key are both name-then-value, which
// the first pattern already matches, so a separate arm could never fire.
var inspectSecretPatterns = []inspectSecretPattern{
	// name=value where the NAME says secret: DB_PASSWORD=x, client_secret: x, "api_key": "x".
	{re: regexp.MustCompile(`(?i)[\w.-]*(?:password|passwd|passphrase|secret|token|credential|api[_-]?key|access[_-]?key|private[_-]?key)[\w.-]*` + nameValue)},
	// any *_key / *-key name: RAILS_MASTER_KEY, JWT_SIGNING_KEY, ENCRYPTION_KEY.
	// The delimiter in front of "key" is what keeps "public key: <wg key>" out.
	{re: regexp.MustCompile(`(?i)[\w.]*[_-]key` + nameValue), minLen: 8, skipIf: "public"},
	// UPPER_SNAKE env names whose keyword is not adjacent to the "=": SECRET_KEY_BASE.
	{re: regexp.MustCompile(`\b[A-Z][A-Z0-9_]*(?:KEY|SECRET|TOKEN|PASSWORD|PASSWD|CREDENTIAL)[A-Z0-9_]*[ \t]*=[ \t]*("[^"\n]*"|'[^'\n]*'|\S+)`)},
	// {"auth": "..."} — a docker config or registry 401 body.
	{re: regexp.MustCompile(`(?i)\bauth` + nameValue), minLen: 8},
	// Credentials embedded in a URL's userinfo (scheme://user:pass@host).
	{re: regexp.MustCompile(`[a-zA-Z][a-zA-Z0-9+.-]*://[^\s:@/]+:([^\s@/]+)@`)},
	// HTTP Authorization headers — Bearer / Basic / Token.
	{re: regexp.MustCompile(`(?i)\b(?:Authorization|Bearer|Basic|Token)\s+([A-Za-z0-9\-._~+/=]{16,})`)},
	// A credential passed as a SPACE-separated flag: --password v, --token v.
	{re: regexp.MustCompile(`(?i)--(?:password|passwd|token|secret|api[_-]?key|access[_-]?key)[=\s]+(\S+)`)},
	// -p on a login invocation (never a bare -p, which is mkdir -p and cp -p).
	{re: regexp.MustCompile(`(?i)\blogin\b[^\n]{0,120}?\s-p\s+(\S+)`)},
	// curl -u user:token — the colon separates it from sort -u file.
	{re: regexp.MustCompile(`\s-u\s+[^\s:]+:(\S+)`)},
	// .netrc line.
	{re: regexp.MustCompile(`(?i)\bmachine\s+\S+\s+login\s+\S+\s+password\s+(\S+)`)},
	// Bare JWTs.
	{re: regexp.MustCompile(`\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b`)},
	// Provider tokens: AWS key ids, GitHub PATs, sk-* keys, Vault hvs.* tokens.
	{re: regexp.MustCompile(`\b(?:AKIA|ASIA|AROA|AIDA|AGPA)[0-9A-Z]{16}\b`)},
	{re: regexp.MustCompile(`\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36,}\b`)},
	{re: regexp.MustCompile(`\bgithub_pat_[A-Za-z0-9_]{82}\b`)},
	{re: regexp.MustCompile(`\bsk-(?:ant-)?[A-Za-z0-9\-_]{32,}\b`)},
	{re: regexp.MustCompile(`\bhvs\.[A-Za-z0-9_-]{20,}\b`)},
	// PEM private keys, whole or clipped (the END footer never arrived).
	{re: regexp.MustCompile(`(?s)-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?(?:-----END [A-Z0-9 ]*PRIVATE KEY-----|\z)`)},
}

// inspectSecretValues finds the secret VALUES in text: scrubSecrets replaces
// values it is given, it does not recognise them, and this handler has no
// task-supplied secret list the way ci.module_build does.
func inspectSecretValues(text string) []string {
	var values []string
	for _, p := range inspectSecretPatterns {
		for _, m := range p.re.FindAllStringSubmatch(text, -1) {
			v := m[0]
			if p.re.NumSubexp() > 0 {
				v = m[1]
			}
			v = strings.Trim(v, `"'`)
			v = strings.TrimRight(v, ")]}>.")
			if v == "" || len(v) < p.minLen {
				continue
			}
			if p.skipIf != "" && strings.Contains(strings.ToLower(m[0]), p.skipIf) {
				continue
			}
			values = append(values, v)
		}
	}
	return values
}

// inspectScrub is the one exit for collector text: secrets found in it, plus
// any the caller already knows, go through scrubSecrets. Longest first, so a
// value that contains another is not left half-replaced.
func inspectScrub(text string, known ...string) string {
	secrets := append(inspectSecretValues(text), known...)
	sort.SliceStable(secrets, func(i, j int) bool { return len(secrets[i]) > len(secrets[j]) })
	return scrubSecrets(text, secrets...)
}

// === caps ===

var capNames = []string{
	"CAP_CHOWN", "CAP_DAC_OVERRIDE", "CAP_DAC_READ_SEARCH", "CAP_FOWNER", "CAP_FSETID", "CAP_KILL",
	"CAP_SETGID", "CAP_SETUID", "CAP_SETPCAP", "CAP_LINUX_IMMUTABLE", "CAP_NET_BIND_SERVICE",
	"CAP_NET_BROADCAST", "CAP_NET_ADMIN", "CAP_NET_RAW", "CAP_IPC_LOCK", "CAP_IPC_OWNER",
	"CAP_SYS_MODULE", "CAP_SYS_RAWIO", "CAP_SYS_CHROOT", "CAP_SYS_PTRACE", "CAP_SYS_PACCT",
	"CAP_SYS_ADMIN", "CAP_SYS_BOOT", "CAP_SYS_NICE", "CAP_SYS_RESOURCE", "CAP_SYS_TIME",
	"CAP_SYS_TTY_CONFIG", "CAP_MKNOD", "CAP_LEASE", "CAP_AUDIT_WRITE", "CAP_AUDIT_CONTROL",
	"CAP_SETFCAP", "CAP_MAC_OVERRIDE", "CAP_MAC_ADMIN", "CAP_SYSLOG", "CAP_WAKE_ALARM",
	"CAP_BLOCK_SUSPEND", "CAP_AUDIT_READ", "CAP_PERFMON", "CAP_BPF", "CAP_CHECKPOINT_RESTORE",
}

var (
	capHex     = regexp.MustCompile(`^[0-9a-fA-F]{16}$`)
	pidDigits  = regexp.MustCompile(`^[0-9]{1,9}$`)
	capStatusK = map[string]string{
		"CapInh": "cap_inh", "CapPrm": "cap_prm", "CapEff": "cap_eff", "CapBnd": "cap_bnd", "CapAmb": "cap_amb",
	}
)

// capsFromHex names the bits set in a /proc capability mask.
func capsFromHex(mask string) []string {
	v, err := strconv.ParseUint(mask, 16, 64)
	if err != nil {
		return nil
	}
	names := []string{}
	for bit := 0; bit < 64; bit++ {
		if v&(1<<uint(bit)) == 0 {
			continue
		}
		if bit < len(capNames) {
			names = append(names, capNames[bit])
		} else {
			names = append(names, "CAP_"+strconv.Itoa(bit))
		}
	}
	return names
}

// inspectCaps reports the capability sets of a unit's main PID. The PID comes
// from systemctl and is spliced into a /proc path, so only a short run of digits
// is accepted; only the Cap* and NoNewPrivs lines leave the status file, and
// /proc/<pid>/environ and cmdline are never opened.
func inspectCaps(ctx context.Context, runner mount.Runner, unit string) tasks.Result {
	res := tasks.Result{"collector": "caps", "ok": false, "unit": unit}
	fail := func(msg string) tasks.Result {
		res["error"], _ = inspectBound(inspectScrub(msg), 2048, false)
		return res
	}
	out, _, err := inspectRun(ctx, runner, inspectProbeReadBytes, "systemctl", "show", "-p", "MainPID", "--value", unit)
	if err != nil {
		return fail(err.Error())
	}
	pidText := strings.TrimSpace(string(out))
	if !pidDigits.MatchString(pidText) {
		return fail("systemctl reported an unusable MainPID")
	}
	pid, _ := strconv.Atoi(pidText)
	if pid == 0 {
		return fail("unit has no main PID (not running)")
	}
	res["main_pid"] = pid

	f, err := os.Open(filepath.Join(inspectProcRoot, strconv.Itoa(pid), "status"))
	if err != nil {
		return fail("cannot read the process status: " + err.Error())
	}
	defer f.Close()
	found := false
	scanner := bufio.NewScanner(io.LimitReader(f, inspectStatusReadBytes))
	for scanner.Scan() {
		key, value, ok := strings.Cut(scanner.Text(), ":")
		if !ok {
			continue
		}
		value = strings.TrimSpace(value)
		if field, isCap := capStatusK[key]; isCap && capHex.MatchString(value) {
			res[field] = value
			if field == "cap_eff" || field == "cap_prm" {
				res[field+"_names"] = capsFromHex(value)
			}
			found = true
		} else if key == "NoNewPrivs" {
			res["no_new_privs"] = value == "1"
		}
	}
	if !found {
		return fail("the process status carried no capability lines")
	}
	res["ok"] = true
	return res
}

// === file_stat ===

// inspectFileStatBounded runs file_stat under a DEADLINE. The agent runs one
// task at a time with no per-handler deadline, and file_stat's allow-list
// includes /var/lib/powernode, which hosts NFS storage mounts: a read on an
// unreachable export blocks in D-state, and every later task for the node
// (deploys included) would queue behind it forever. The call therefore runs in
// a goroutine and is abandoned at the deadline. A D-state read cannot be
// interrupted, so the goroutine leaks until the mount answers; that is
// accepted, and bounded by inspectMaxWedged.
func inspectFileStatBounded(path string) (tasks.Result, error) {
	if atomic.AddInt32(&inspectWedged, 1) > inspectMaxWedged {
		atomic.AddInt32(&inspectWedged, -1)
		return nil, taskguard.Refused("path",
			fmt.Sprintf("cannot be inspected: %d earlier file_stat calls are still blocked on unresponsive paths", inspectMaxWedged), path)
	}
	type outcome struct {
		res tasks.Result
		err error
	}
	done := make(chan outcome, 1)
	fn := inspectFileStatFn
	go func() {
		defer atomic.AddInt32(&inspectWedged, -1)
		res, err := fn(path)
		done <- outcome{res, err}
	}()

	timer := time.NewTimer(inspectCommandTimeout)
	defer timer.Stop()
	select {
	case o := <-done:
		return o.res, o.err
	case <-timer.C:
		return nil, taskguard.Refused("path",
			fmt.Sprintf("did not answer within %s (a stalled or network filesystem?); refusing to wait", inspectCommandTimeout), path)
	}
}

// inspectNetworkFS reports whether a filesystem type is a network or FUSE one:
// nfs*, cifs, smb*, fuse* (fuse.sshfs, fuse.glusterfs, fuseblk...), 9p, ceph,
// glusterfs, sshfs. A stat or read on one can block indefinitely when the
// remote end is gone.
func inspectNetworkFS(fstype string) bool {
	t := strings.ToLower(fstype)
	for _, prefix := range []string{"nfs", "smb", "fuse"} {
		if strings.HasPrefix(t, prefix) {
			return true
		}
	}
	switch t {
	case "cifs", "9p", "ceph", "glusterfs", "sshfs":
		return true
	}
	return false
}

// inspectMountEntry is one line of /proc/self/mountinfo, reduced to what the
// network check needs.
type inspectMountEntry struct{ point, fstype string }

// inspectReadMounts parses the mount table through the /proc seam.
func inspectReadMounts() ([]inspectMountEntry, error) {
	f, err := os.Open(filepath.Join(inspectProcRoot, "self", "mountinfo"))
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var entries []inspectMountEntry
	scanner := bufio.NewScanner(io.LimitReader(f, 8<<20))
	scanner.Buffer(make([]byte, 64*1024), 1<<20)
	for scanner.Scan() {
		line := scanner.Text()
		// id parent maj:min root mountpoint options [optional...] - fstype source superopts
		sep := strings.Index(line, " - ")
		if sep < 0 {
			continue
		}
		pre := strings.Fields(line[:sep])
		post := strings.Fields(line[sep+3:])
		if len(pre) < 5 || len(post) < 1 {
			continue
		}
		entries = append(entries, inspectMountEntry{point: unescapeMountinfo(pre[4]), fstype: post[0]})
	}
	return entries, scanner.Err()
}

// unescapeMountinfo decodes the \NNN octal escapes the kernel writes for a
// space, tab, newline or backslash in a mountpoint.
func unescapeMountinfo(s string) string {
	if !strings.Contains(s, `\`) {
		return s
	}
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] == '\\' && i+3 < len(s) {
			if n, err := strconv.ParseUint(s[i+1:i+4], 8, 8); err == nil {
				b.WriteByte(byte(n))
				i += 3
				continue
			}
		}
		b.WriteByte(s[i])
	}
	return b.String()
}

// inspectRefuseNetworkMount refuses a path held by a network or FUSE mount. The
// DEEPEST mount containing the path decides, and for equal mountpoints the LAST
// line does (an overmount hides what is beneath it). If the mount table cannot
// be read, whether the path is on such a mount is unknown, and unknown is a
// refusal.
func inspectRefuseNetworkMount(field, logical string) error {
	mounts, err := inspectReadMounts()
	if err != nil {
		return taskguard.Refused(field, "cannot be checked against the mount table ("+err.Error()+"); refusing", logical)
	}
	best := -1
	fstype := ""
	for _, m := range mounts {
		if m.point == "/" || logical == m.point || strings.HasPrefix(logical, strings.TrimSuffix(m.point, "/")+"/") {
			if len(m.point) >= best {
				best, fstype = len(m.point), m.fstype
			}
		}
	}
	if best >= 0 && inspectNetworkFS(fstype) {
		return taskguard.Refused(field, "is on a "+fstype+" mount, a network or FUSE filesystem file_stat will not touch (it can block indefinitely)", logical)
	}
	return nil
}

// inspectFileStat returns a file's stat, sha256 and mtime. NEVER its contents.
//
// The requested path has passed taskguard.InspectFilePath textually. It is then
// checked against the mount table BEFORE anything touches it (so resolving a
// component of a dead export is never attempted), resolved through symlinks, and
// the RESOLVED path is judged again by the same rule and the mount check, and
// must still lie under the node root: a link inside an allowed tree points
// anywhere, and a textual rule alone follows it out (a link from /etc to
// /proc/1/environ, or into an NFS mount).
func inspectFileStat(path string) (tasks.Result, error) {
	if err := inspectRefuseNetworkMount("path", path); err != nil {
		return nil, err
	}
	realRoot, err := filepath.EvalSymlinks(inspectFSRoot)
	if err != nil {
		return nil, fmt.Errorf("cannot resolve the node root: %w", err)
	}
	resolved, err := filepath.EvalSymlinks(filepath.Join(realRoot, path))
	if errors.Is(err, fs.ErrNotExist) {
		return tasks.Result{"collector": "file_stat", "ok": true, "path": inspectScrub(path), "exists": false}, nil
	}
	if err != nil {
		return nil, taskguard.Refused("path", "cannot be resolved (symlink loop or unreadable component)", path)
	}
	rel, err := filepath.Rel(realRoot, resolved)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return nil, taskguard.Refused("path", "resolves outside the node root", path)
	}
	logical := "/" + filepath.ToSlash(rel)
	if rel == "." {
		logical = "/"
	}
	if err := taskguard.InspectFilePath("path (symlink target)", logical); err != nil {
		return nil, err
	}
	if err := inspectRefuseNetworkMount("path (symlink target)", logical); err != nil {
		return nil, err
	}

	// Lstat first: opening a FIFO or device to hash it can block or have side
	// effects, so only a regular file is ever opened.
	st, err := os.Lstat(resolved)
	if err != nil {
		return nil, fmt.Errorf("stat %s: %w", logical, err)
	}
	res := tasks.Result{
		"collector": "file_stat", "ok": true, "exists": true,
		"path": inspectScrub(path), "resolved_path": inspectScrub(logical),
	}
	switch {
	case st.Mode().IsRegular():
		res["type"] = "file"
	case st.IsDir():
		res["type"] = "dir"
	default:
		res["type"] = "other"
	}
	if st.Mode().IsRegular() {
		st, err = inspectHashFile(res, realRoot, rel, logical)
		if err != nil {
			return nil, err
		}
	}
	res["size"] = st.Size()
	res["mode"] = fmt.Sprintf("%04o", inspectMode(st.Mode()))
	res["mtime"] = st.ModTime().UTC().Format(time.RFC3339)
	res["mtime_unix"] = st.ModTime().Unix()
	if sys, ok := st.Sys().(*syscall.Stat_t); ok {
		res["uid"] = sys.Uid
		res["gid"] = sys.Gid
	}
	return res, nil
}

func inspectMode(m os.FileMode) uint32 {
	bits := uint32(m.Perm())
	if m&os.ModeSetuid != 0 {
		bits |= 0o4000
	}
	if m&os.ModeSetgid != 0 {
		bits |= 0o2000
	}
	if m&os.ModeSticky != 0 {
		bits |= 0o1000
	}
	return bits
}

// inspectHashFile records the sha256 of a regular file into res and returns the
// descriptor's own stat (the file the hash is of, not the one Lstat saw). The
// open is inspectOpenBeneath (openat2, RESOLVE_BENEATH|RESOLVE_NO_SYMLINKS), so a
// symlink swapped in for ANY component after the resolution above is refused by
// the kernel instead of followed.
func inspectHashFile(res tasks.Result, root, rel, logical string) (os.FileInfo, error) {
	if hook := inspectBeforeOpenHook; hook != nil {
		hook()
	}
	f, err := inspectOpenBeneath(root, rel)
	if err != nil {
		if inspectOpenRaced(err) {
			return nil, taskguard.Refused("path", "changed while it was being opened (a symlink or a moved component); refusing to follow it", logical)
		}
		return nil, fmt.Errorf("open %s: %w", logical, err)
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return nil, fmt.Errorf("stat %s: %w", logical, err)
	}
	if !st.Mode().IsRegular() {
		res["type"] = "other"
		return st, nil
	}
	if st.Size() > inspectHashMaxBytes {
		res["sha256_skipped"] = fmt.Sprintf("file is larger than %d bytes", inspectHashMaxBytes)
		return st, nil
	}
	h := sha256.New()
	if _, err := io.Copy(h, io.LimitReader(f, inspectHashMaxBytes)); err != nil {
		return nil, fmt.Errorf("hash %s: %w", logical, err)
	}
	res["sha256"] = hex.EncodeToString(h.Sum(nil))
	return st, nil
}
