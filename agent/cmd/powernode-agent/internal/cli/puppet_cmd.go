package cli

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// PuppetApplyOptions drives `powernode-agent puppet apply`. Fetches
// site.pp + module manifests from the platform's /node_api/puppet/*
// endpoints, stages them at the canonical Puppet path, runs
// puppet apply --noop first to check for surprises, then executes
// the real apply if the diff is within bounds.
type PuppetApplyOptions struct {
	Noop                  bool
	Tags                  []string
	Timeout               time.Duration
	AllowChangesOver      int  // refuse if --noop reports more than N changes
	AllowIdentityChanges  bool // permit changes to /etc/sudoers, /etc/passwd, /etc/ssh
	JSON                  bool
	PlatformURL           string
	PKIDir                string
	StagingRoot           string // /etc/puppetlabs/code/environments/production
	Runner                mount.Runner
}

// RunPuppetApply runs the puppet flow.
func RunPuppetApply(ctx context.Context, opts PuppetApplyOptions) (Result, error) {
	if opts.Timeout == 0 {
		opts.Timeout = 30 * time.Minute
	}
	if opts.AllowChangesOver == 0 {
		opts.AllowChangesOver = 50
	}
	if opts.StagingRoot == "" {
		opts.StagingRoot = "/etc/puppetlabs/code/environments/production"
	}
	if opts.Runner == nil {
		opts.Runner = mount.ExecRunner{}
	}

	cctx, err := BuildContext(opts.PlatformURL, opts.PKIDir)
	if err != nil {
		return errResult("puppet", ExitPlatformUnreached, "build_context", err),
			Errorf(ExitPlatformUnreached, "puppet", "%w", err)
	}

	manifestText, err := fetchPuppetManifest(cctx.Transport)
	if err != nil {
		return errResult("puppet", ExitPlatformUnreached, "fetch_manifest", err),
			Errorf(ExitPlatformUnreached, "puppet:fetch_manifest", "%w", err)
	}

	if err := stagePuppetManifest(opts.StagingRoot, manifestText); err != nil {
		return errResult("puppet", ExitGeneric, "stage_manifest", err),
			Errorf(ExitGeneric, "puppet:stage_manifest", "%w", err)
	}

	// Always run --noop first, even when the operator passed --noop
	// (idempotent — a no-op noop is fine). Captures the change-count
	// for the safety guards before any actual apply.
	noopOut, noopExit, err := runPuppet(ctx, opts.Runner, opts.StagingRoot, opts.Tags, true)
	if err != nil && noopExit < 0 {
		return errResult("puppet", ExitGeneric, "noop_run", err),
			Errorf(ExitGeneric, "puppet:noop_run", "%w", err)
	}

	changes := countChanges(noopOut)
	identityHits := scanIdentityChanges(noopOut)
	if changes > opts.AllowChangesOver {
		return errResult("puppet", ExitRefused, "too_many_changes",
				fmt.Errorf("%d changes > --allow-changes-over=%d", changes, opts.AllowChangesOver)),
			Errorf(ExitRefused, "puppet:too_many_changes",
				"refusing — %d changes (limit %d, override with --allow-changes-over)",
				changes, opts.AllowChangesOver)
	}
	if !opts.AllowIdentityChanges && len(identityHits) > 0 {
		return errResult("puppet", ExitRefused, "identity_changes",
				fmt.Errorf("manifest changes identity files: %v", identityHits)),
			Errorf(ExitRefused, "puppet:identity_changes",
				"refusing — manifest changes identity-bearing files (%s); use --allow-identity-changes to override",
				strings.Join(identityHits, ", "))
	}

	if opts.Noop {
		return Result{
			Command: "puppet",
			Status:  "ok",
			Details: map[string]any{
				"mode":      "noop",
				"changes":   changes,
				"exit_code": noopExit,
			},
		}, nil
	}

	// Real apply.
	applyOut, applyExit, applyErr := runPuppet(ctx, opts.Runner, opts.StagingRoot, opts.Tags, false)
	if applyErr != nil && applyExit < 0 {
		return errResult("puppet", ExitGeneric, "apply", applyErr),
			Errorf(ExitGeneric, "puppet:apply", "%w", applyErr)
	}

	// Map puppet --detailed-exitcodes to CLI exit codes:
	//   0 = no changes / success
	//   2 = changes applied successfully → CLI 0
	//   4 = failures → CLI 9 (ExitPuppetFailures)
	//   6 = changes + failures → CLI 10 (ExitPuppetMixed)
	cliCode := ExitOK
	switch applyExit {
	case 0, 2:
		cliCode = ExitOK
	case 4:
		cliCode = ExitPuppetFailures
	case 6:
		cliCode = ExitPuppetMixed
	default:
		cliCode = ExitGeneric
	}

	res := Result{
		Command: "puppet",
		Status:  conditional(cliCode == ExitOK, "ok", "error"),
		ExitCode: cliCode,
		Details: map[string]any{
			"mode":         "apply",
			"changes":      changes,
			"puppet_exit":  applyExit,
			"output_tail":  tail(applyOut, 8192),
		},
	}
	if cliCode != ExitOK {
		res.Error = fmt.Sprintf("puppet apply exited %d", applyExit)
		return res, Errorf(cliCode, "puppet:apply", "puppet apply exited %d", applyExit)
	}
	return res, nil
}

// fetchPuppetManifest retrieves the site.pp text from the platform.
func fetchPuppetManifest(t HTTPGetClient) (string, error) {
	resp, err := t.GetJSON("/api/v1/system/node_api/puppet/manifest")
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "", fmt.Errorf("puppet/manifest status %d: %s",
			resp.StatusCode, strings.TrimSpace(string(body)))
	}
	var env struct {
		Data struct {
			Manifest string `json:"manifest"`
		} `json:"data"`
	}
	if err := json.Unmarshal(body, &env); err != nil {
		// Some endpoint responses may serve the manifest as plain text.
		return string(body), nil
	}
	if env.Data.Manifest != "" {
		return env.Data.Manifest, nil
	}
	return string(body), nil
}

// stagePuppetManifest writes the site.pp text into the canonical
// Puppet manifest path. Creates parent dirs as needed.
func stagePuppetManifest(stagingRoot, manifestText string) error {
	manifestsDir := filepath.Join(stagingRoot, "manifests")
	if err := os.MkdirAll(manifestsDir, 0o755); err != nil {
		return fmt.Errorf("mkdir %s: %w", manifestsDir, err)
	}
	return os.WriteFile(filepath.Join(manifestsDir, "site.pp"), []byte(manifestText), 0o644)
}

// runPuppet invokes `puppet apply` with --detailed-exitcodes.
// Returns combined stdout+stderr, the puppet exit code, and any
// process-launch error.
func runPuppet(ctx context.Context, runner mount.Runner, stagingRoot string, tags []string, noop bool) ([]byte, int, error) {
	args := []string{"apply", "--detailed-exitcodes"}
	if noop {
		args = append(args, "--noop")
	}
	if len(tags) > 0 {
		args = append(args, "--tags", strings.Join(tags, ","))
	}
	args = append(args, filepath.Join(stagingRoot, "manifests", "site.pp"))

	out, err := runner.Output(ctx, "puppet", args...)
	if err != nil {
		// puppet --detailed-exitcodes uses 2/4/6 to signal status; the
		// runner treats non-zero exit as error. Extract the exit code
		// from the wrapped error text when present.
		exitCode := -1
		if ee, ok := err.(*exec.ExitError); ok {
			exitCode = ee.ExitCode()
		} else {
			// mount.Runner formats errors with exit status embedded.
			if m := exitCodeRegexp.FindStringSubmatch(err.Error()); len(m) > 1 {
				fmt.Sscanf(m[1], "%d", &exitCode)
			}
		}
		// 2/4/6 are "expected" puppet states with output to inspect; not a launch failure.
		if exitCode == 2 || exitCode == 4 || exitCode == 6 {
			return out, exitCode, nil
		}
		return out, exitCode, err
	}
	return out, 0, nil
}

var exitCodeRegexp = regexp.MustCompile(`exit status (\d+)`)

// countChanges counts /^Notice: .*Stage\[\w+\].*\/.*\]: .*$/ lines
// that puppet emits in --noop mode. A simpler heuristic: count
// "would have" + "would be" mentions.
func countChanges(out []byte) int {
	s := string(out)
	count := 0
	for _, marker := range []string{"would have", "would be", "Notice: /Stage"} {
		count += strings.Count(s, marker)
	}
	return count
}

var identityFilePatterns = []string{
	"/etc/sudoers",
	"/etc/passwd",
	"/etc/shadow",
	"/etc/ssh/",
}

// scanIdentityChanges returns the identity-file paths the noop
// output mentions modifying. Used to refuse high-risk apply runs
// without explicit operator override.
func scanIdentityChanges(out []byte) []string {
	s := string(out)
	var hits []string
	for _, p := range identityFilePatterns {
		if strings.Contains(s, p) {
			hits = append(hits, p)
		}
	}
	return hits
}
