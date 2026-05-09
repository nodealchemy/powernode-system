package cli

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// ExecOptions drives `powernode-agent exec <script-id>`. Fetches a
// NodeScript from the platform, verifies its checksum, applies a
// privilege model (default = drop to nobody), and runs the script
// with a deadline. Captures stdout/stderr.
type ExecOptions struct {
	ScriptID       string
	Args           []string
	PlatformURL    string
	PKIDir         string
	Timeout        time.Duration
	AsUser         string // empty = use script.config.security.user, else root
	AllowUnsigned  bool   // dev/staging only
	JSON           bool
	AllowlistPath  string // /persist/var/lib/powernode/exec_allowlist.json
}

// scriptResponse mirrors the platform's
// /api/v1/system/node_api/files/scripts/:id response shape (when
// the platform serves a script via JSON envelope; some flows serve
// the script body directly).
type scriptResponse struct {
	Success bool `json:"success"`
	Data    struct {
		ID          string `json:"id"`
		Content     string `json:"content"`
		Interpreter string `json:"interpreter"`
		Checksum    string `json:"checksum"`
		Config      struct {
			Security struct {
				PrivilegeModel    string `json:"privilege_model"` // drop_to_nobody|as_user|privileged
				User              string `json:"user"`
				RequiredSignature bool   `json:"required_signature"`
			} `json:"security"`
		} `json:"config"`
	} `json:"data"`
}

// RunExec runs the script and reports the result. Hard rule: if the
// privilege drop wrapper fails, the caller MUST exit 1 — never fall
// back to running as root. The script body is always executed via
// the wrapper subprocess; a wrapper-failure path that re-execs as
// the agent's uid is the kind of footgun this command exists to
// avoid.
func RunExec(ctx context.Context, opts ExecOptions) (Result, error) {
	if opts.ScriptID == "" {
		return errResult("exec", ExitGeneric, "missing_script_id", errors.New("script-id required")),
			Errorf(ExitGeneric, "exec", "script-id required")
	}
	if opts.Timeout == 0 {
		opts.Timeout = 5 * time.Minute
	}
	if opts.AllowlistPath == "" {
		opts.AllowlistPath = "/persist/var/lib/powernode/exec_allowlist.json"
	}

	cctx, err := BuildContext(opts.PlatformURL, opts.PKIDir)
	if err != nil {
		return errResult("exec", ExitPlatformUnreached, "build_context", err),
			Errorf(ExitPlatformUnreached, "exec", "%w", err)
	}

	script, err := fetchScript(cctx.Transport, opts.ScriptID)
	if err != nil {
		return errResult("exec", ExitPlatformUnreached, "fetch_script", err),
			Errorf(ExitPlatformUnreached, "exec:fetch_script", "%w", err)
	}

	if err := verifyChecksum(script.Data.Content, script.Data.Checksum); err != nil {
		return errResult("exec", ExitVerifyFailed, "checksum", err),
			Errorf(ExitVerifyFailed, "exec:checksum", "%w", err)
	}

	if script.Data.Config.Security.RequiredSignature && !opts.AllowUnsigned {
		return errResult("exec", ExitVerifyFailed, "signature_required",
				errors.New("script requires signature; cosign verification not yet implemented (use --allow-unsigned in dev only)")),
			Errorf(ExitVerifyFailed, "exec:signature_required",
				"script %s requires signature (use --allow-unsigned to bypass in dev only)", opts.ScriptID)
	}

	scriptPath, err := writeScriptToTmp(script.Data.Content, script.Data.Interpreter)
	if err != nil {
		return errResult("exec", ExitGeneric, "write_script", err),
			Errorf(ExitGeneric, "exec:write_script", "%w", err)
	}
	defer os.Remove(scriptPath)

	model := strings.ToLower(script.Data.Config.Security.PrivilegeModel)
	if model == "" {
		model = "drop_to_nobody"
	}

	// Hard rule: privileged exec requires per-instance allowlist.
	if model == "privileged" {
		if !inAllowlist(opts.AllowlistPath, opts.ScriptID) {
			return errResult("exec", ExitRefused, "privileged_not_allowlisted",
					errors.New("script requested privileged exec but is not in the operator allowlist")),
				Errorf(ExitRefused, "exec:privileged_not_allowlisted",
					"script %s requests privileged exec but is not in %s", opts.ScriptID, opts.AllowlistPath)
		}
	}

	asUser := opts.AsUser
	if asUser == "" {
		asUser = script.Data.Config.Security.User
	}

	cmd := buildExecCommand(ctx, scriptPath, model, asUser, script.Data.Interpreter, opts.Args)
	deadline, cancel := context.WithTimeout(ctx, opts.Timeout)
	defer cancel()
	cmd = exec.CommandContext(deadline, cmd.Path, cmd.Args[1:]...)

	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	runErr := cmd.Run()

	exitCode := 0
	if runErr != nil {
		if ee, ok := runErr.(*exec.ExitError); ok {
			exitCode = ee.ExitCode()
		} else {
			exitCode = -1
		}
	}

	res := Result{
		Command: "exec",
		Status:  conditional(runErr == nil, "ok", "error"),
		Details: map[string]any{
			"script_id":       opts.ScriptID,
			"privilege_model": model,
			"as_user":         asUser,
			"exit_code":       exitCode,
			"stdout_tail":     tail(stdout.Bytes(), 4096),
			"stderr_tail":     tail(stderr.Bytes(), 4096),
			"duration_ms":     0, // wall-clock filled in by caller via time.Since
		},
	}
	if runErr != nil {
		res.ExitCode = ExitGeneric
		res.Error = runErr.Error()
		return res, Errorf(ExitGeneric, "exec:run", "script exited %d: %v", exitCode, runErr)
	}
	return res, nil
}

func fetchScript(t HTTPGetClient, id string) (*scriptResponse, error) {
	resp, err := t.GetJSON(fmt.Sprintf("/api/v1/system/node_api/files/scripts/%s", id))
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("script %s status %d: %s", id, resp.StatusCode, strings.TrimSpace(string(body)))
	}
	var sr scriptResponse
	if err := json.Unmarshal(body, &sr); err != nil {
		return nil, fmt.Errorf("decode script: %w", err)
	}
	return &sr, nil
}

// HTTPGetClient is the minimal interface fetchScript needs. Both
// *transport.Client and *transport.SwappableClient satisfy it.
type HTTPGetClient interface {
	GetJSON(path string) (*http.Response, error)
}

func verifyChecksum(content, expected string) error {
	if expected == "" {
		return errors.New("server response missing checksum")
	}
	got := sha256.Sum256([]byte(content))
	gotHex := hex.EncodeToString(got[:])
	if !strings.EqualFold(gotHex, strings.TrimPrefix(expected, "sha256:")) {
		return fmt.Errorf("checksum mismatch: got %s, expected %s", gotHex, expected)
	}
	return nil
}

func writeScriptToTmp(content, interpreter string) (string, error) {
	dir := "/run/powernode/exec"
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}
	f, err := os.CreateTemp(dir, "script-*")
	if err != nil {
		return "", err
	}
	defer f.Close()
	if _, err := f.WriteString(content); err != nil {
		os.Remove(f.Name())
		return "", err
	}
	mode := os.FileMode(0o700)
	if interpreter != "" {
		mode = 0o700
	}
	if err := os.Chmod(f.Name(), mode); err != nil {
		os.Remove(f.Name())
		return "", err
	}
	return f.Name(), nil
}

// buildExecCommand returns an *exec.Cmd that runs scriptPath under
// the requested privilege model. When the model is drop_to_nobody
// or as_user, the command is wrapped in setpriv. The wrapper's
// failure is observable as a non-zero exit on the wrapper itself
// — there is NO fallback to root execution.
func buildExecCommand(ctx context.Context, scriptPath, model, asUser, interpreter string, args []string) *exec.Cmd {
	scriptInvocation := []string{}
	if interpreter != "" {
		scriptInvocation = append(scriptInvocation, interpreter, scriptPath)
	} else {
		scriptInvocation = append(scriptInvocation, scriptPath)
	}
	scriptInvocation = append(scriptInvocation, args...)

	switch model {
	case "drop_to_nobody":
		setprivArgs := []string{
			"--reuid=nobody", "--regid=nogroup", "--clear-groups",
			"--bounding-set=-all", "--inh-caps=-all",
		}
		setprivArgs = append(setprivArgs, scriptInvocation...)
		return exec.CommandContext(ctx, "setpriv", setprivArgs...)
	case "as_user":
		if asUser == "" {
			asUser = "nobody"
		}
		setprivArgs := []string{
			"--reuid=" + asUser, "--regid=" + asUser, "--clear-groups",
		}
		setprivArgs = append(setprivArgs, scriptInvocation...)
		return exec.CommandContext(ctx, "setpriv", setprivArgs...)
	case "privileged":
		// No wrapper — runs as agent (root).
		return exec.CommandContext(ctx, scriptInvocation[0], scriptInvocation[1:]...)
	default:
		// Unknown model = treat as drop_to_nobody (safer default).
		setprivArgs := []string{
			"--reuid=nobody", "--regid=nogroup", "--clear-groups",
			"--bounding-set=-all", "--inh-caps=-all",
		}
		setprivArgs = append(setprivArgs, scriptInvocation...)
		return exec.CommandContext(ctx, "setpriv", setprivArgs...)
	}
}

// inAllowlist returns true iff scriptID is present in the
// JSON allowlist file at path. The allowlist is operator-managed
// (no platform-write path); a missing file = empty allowlist.
func inAllowlist(path, scriptID string) bool {
	body, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	var entries []string
	if err := json.Unmarshal(body, &entries); err != nil {
		return false
	}
	for _, e := range entries {
		if e == scriptID {
			return true
		}
	}
	return false
}

func tail(b []byte, n int) string {
	if len(b) <= n {
		return string(b)
	}
	return string(b[len(b)-n:])
}

var _ = filepath.Join // reserved for future temp-dir construction
