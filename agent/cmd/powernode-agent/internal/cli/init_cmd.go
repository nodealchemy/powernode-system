package cli

import (
	"context"
	"errors"
	"fmt"
	"io"

	"github.com/powernode/platform/extensions/system/agent/internal/manifest"
	"github.com/powernode/platform/extensions/system/agent/internal/mount"
	"github.com/powernode/platform/extensions/system/agent/internal/systemd"
)

// InitOptions controls the `powernode-agent init <module-id> <action>`
// command. Local-only — no platform call. Reads the cached manifest
// from disk, dispatches the action verb to all units listed in
// manifest.Units().
type InitOptions struct {
	ModuleID     string
	Action       string // start|stop|restart|reload|status
	JSON         bool
	ManifestRoot string
	Runner       mount.Runner
	Out          io.Writer
}

// RunInit executes the init command.
//
// On restart, units are stopped in reverse order then started in
// forward order — matches systemd dependency direction so the unit
// graph comes down + up cleanly.
//
// Aggregates errors: a failure on one unit doesn't abort the rest.
// Returns a non-nil error iff any unit failed; the error wraps a
// stable summary so the cobra wrapper can map it to the right exit
// code.
func RunInit(ctx context.Context, opts InitOptions) (Result, error) {
	if opts.ModuleID == "" {
		return errResult("init", ExitGeneric, "missing_module_id", errors.New("module-id required")), Errorf(ExitGeneric, "init", "module-id required")
	}
	verb := systemd.ActionVerb(opts.Action)
	if !verb.IsValid() {
		return errResult("init", ExitGeneric, "invalid_verb", fmt.Errorf("invalid verb %q", opts.Action)),
			Errorf(ExitGeneric, "init", "invalid verb %q (want start|stop|restart|reload|status)", opts.Action)
	}
	if opts.ManifestRoot == "" {
		opts.ManifestRoot = manifest.DefaultRoot
	}
	if opts.Runner == nil {
		opts.Runner = mount.ExecRunner{}
	}

	mf, err := manifest.LoadFromDisk(opts.ManifestRoot, opts.ModuleID)
	if err != nil {
		return errResult("init", ExitGeneric, "load_manifest", err),
			Errorf(ExitGeneric, "init:load_manifest", "module %s not attached or manifest missing (run `attach` first): %w", opts.ModuleID, err)
	}

	units := mf.Units()
	if len(units) == 0 {
		return errResult("init", ExitGeneric, "no_units", errors.New("no units")),
			Errorf(ExitGeneric, "init:no_units", "module %s has no units declared in manifest config[\"units\"]", opts.ModuleID)
	}

	// Execution order: restart goes reverse-stop, forward-start. Other
	// verbs go forward order.
	type unitResult struct {
		Unit   string `json:"unit"`
		Status string `json:"status"`
		Error  string `json:"error,omitempty"`
	}
	var results []unitResult
	failed := 0

	switch verb {
	case systemd.Restart:
		// Stop reverse, start forward.
		for i := len(units) - 1; i >= 0; i-- {
			err := systemd.Action(ctx, opts.Runner, units[i], systemd.Stop)
			res := unitResult{Unit: units[i], Status: "stopped"}
			if err != nil {
				res.Status = "stop_failed"
				res.Error = err.Error()
				failed++
			}
			results = append(results, res)
		}
		for _, unit := range units {
			err := systemd.Action(ctx, opts.Runner, unit, systemd.Start)
			res := unitResult{Unit: unit, Status: "started"}
			if err != nil {
				res.Status = "start_failed"
				res.Error = err.Error()
				failed++
			}
			results = append(results, res)
		}
	default:
		for _, unit := range units {
			err := systemd.Action(ctx, opts.Runner, unit, verb)
			res := unitResult{Unit: unit, Status: opts.Action}
			if err != nil {
				res.Status = opts.Action + "_failed"
				res.Error = err.Error()
				failed++
			}
			results = append(results, res)
		}
	}

	details := map[string]any{
		"module_id": opts.ModuleID,
		"action":    opts.Action,
		"results":   results,
		"failed":    failed,
		"total":     len(results),
	}
	r := Result{
		Command: "init",
		Status:  "ok",
		Details: details,
	}
	if failed > 0 {
		r.Status = "error"
		r.ExitCode = ExitInitFailed
		return r, Errorf(ExitInitFailed, "init", "%d/%d units failed", failed, len(results))
	}
	return r, nil
}

// errResult is a small helper for returning a stable error result
// before the JSON output path.
func errResult(command string, code int, stage string, err error) Result {
	return Result{
		Command:  command,
		Status:   "error",
		ExitCode: code,
		Stage:    stage,
		Error:    err.Error(),
	}
}
