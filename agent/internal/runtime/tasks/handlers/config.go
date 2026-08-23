package handlers

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/nodealchemy/powernode-system/agent/internal/runtime/tasks"
)

// SyncHandler drives the module reconciler synchronously. Used for
// platform-initiated "force a reconcile now" tasks (sync_modules,
// apply_config). The handler runs the same RunOnce path the
// long-loop reconciler uses on its 60s tick.
type SyncHandler struct {
	deps tasks.Dependencies
}

// Execute runs Reconciler.RunOnce. Returns ok on success; the error
// is propagated to the platform's fail endpoint when reconcile fails.
//
// With options.force_resync set, the attached-state stamps are cleared FIRST so
// the reconcile re-materializes files rather than concluding there is nothing
// to do. That distinction is the whole point of the flag: a plain reconcile
// cannot repair a root whose files were removed underneath an unchanged digest
// (the 2026-08-07 whiteout shape), because in that state nothing has drifted.
// options.module_id narrows it to one module; omitting it resyncs every module.
func (h *SyncHandler) Execute(ctx context.Context, task *tasks.Task) (tasks.Result, error) {
	if h.deps.Reconciler == nil {
		return nil, errors.New("sync: Reconciler not configured")
	}

	forced := false
	moduleID := ""
	if task != nil && task.Options != nil {
		forced = optionTrue(task.Options["force_resync"])
		if v, ok := task.Options["module_id"].(string); ok {
			moduleID = v
		}
	}

	if forced {
		if err := h.deps.Reconciler.ClearAttachedManifestHashes(moduleID); err != nil {
			return nil, fmt.Errorf("resync: %w", err)
		}
	}

	if err := h.deps.Reconciler.RunOnce(ctx); err != nil {
		return nil, fmt.Errorf("reconciler: %w", err)
	}

	// IMP-f1c1e6d61104 — a pass that did not converge the desired set must FAIL
	// the task, not complete it. RunOnce returns nil for per-module failures
	// (they report through OnError, a stderr printf in service mode), so
	// without this an apply_config that materialized nothing still reported
	// success — and the server suppresses config_drift for a node on a
	// COMPLETED apply_config, turning a vacuous completion into silence.
	//
	// Type assertion rather than a RunOnceAPI method so existing fakes keep
	// compiling; a reconciler that cannot report is treated as before.
	if reporter, ok := h.deps.Reconciler.(tasks.ConvergenceReporter); ok {
		if failures := reporter.ConvergenceFailures(); len(failures) > 0 {
			return nil, fmt.Errorf("reconcile did not converge %d module(s): %s",
				len(failures), strings.Join(failures, "; "))
		}
	}

	if forced {
		return tasks.Result{"status": "resynced", "module_id": moduleID, "scope": resyncScope(moduleID)}, nil
	}
	return tasks.Result{"status": "reconciled"}, nil
}

// JSON options arrive as bool or string depending on how the platform encoded
// them; accept both rather than silently ignoring "true".
func optionTrue(v any) bool {
	switch t := v.(type) {
	case bool:
		return t
	case string:
		return t == "true" || t == "1"
	default:
		return false
	}
}

func resyncScope(moduleID string) string {
	if moduleID == "" {
		return "all_modules"
	}
	return "single_module"
}

// RegisterConfig binds the sync / config commands.
func RegisterConfig(r *tasks.Registry, deps tasks.Dependencies) {
	h := &SyncHandler{deps: deps}
	r.Register("sync", h)
	r.Register("sync_modules", h)
	r.Register("apply_config", h)
}
