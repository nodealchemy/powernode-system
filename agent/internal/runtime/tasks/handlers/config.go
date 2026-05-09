package handlers

import (
	"context"
	"errors"
	"fmt"

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
func (h *SyncHandler) Execute(ctx context.Context, _ *tasks.Task) (tasks.Result, error) {
	if h.deps.Reconciler == nil {
		return nil, errors.New("sync: Reconciler not configured")
	}
	if err := h.deps.Reconciler.RunOnce(ctx); err != nil {
		return nil, fmt.Errorf("reconciler: %w", err)
	}
	return tasks.Result{"status": "reconciled"}, nil
}

// RegisterConfig binds the sync / config commands.
func RegisterConfig(r *tasks.Registry, deps tasks.Dependencies) {
	h := &SyncHandler{deps: deps}
	r.Register("sync", h)
	r.Register("sync_modules", h)
	r.Register("apply_config", h)
}
