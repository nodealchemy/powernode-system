// Package tasks implements the agent's task lease loop: poll the
// platform's pending-tasks endpoint, dispatch each task to a typed
// handler, and report success/failure. Crash-safe: persists inflight
// state so a mid-task agent restart can resume the right action.
//
// Phase 1 of the agent stub implementation plan; consumes the
// /status/tasks/* endpoints documented in the M2 plan.
package tasks

import (
	"context"
	"net/http"
	"time"

	"github.com/powernode/platform/extensions/system/agent/internal/mount"
	"github.com/powernode/platform/extensions/system/agent/internal/transport"
)

// Task is the agent-side typed view of one pending operation. Mirrors
// the platform's serialize_operation_full shape from
// extensions/system/server/app/controllers/api/v1/system/node_api/status_controller.rb.
type Task struct {
	ID        string         `json:"id"`
	Command   string         `json:"command"`
	Status    string         `json:"status"`
	Progress  int            `json:"progress,omitempty"`
	Options   map[string]any `json:"options,omitempty"`
	StartedAt time.Time      `json:"started_at,omitempty"`
	CreatedAt time.Time      `json:"created_at"`
}

// Result is what a TaskHandler returns to the platform on success.
// Free-form JSON; the platform stores it on the operation row for
// operator UI display + later programmatic inspection.
type Result map[string]any

// TaskHandler implements one task command's logic. Implementations
// MUST be idempotent — the loop's crash-recovery flow may re-execute
// a handler after a restart. Handlers that genuinely cannot be
// idempotent (ssh_command, custom) should document this and rely on
// the platform's reaper to clean up.
type TaskHandler interface {
	Execute(ctx context.Context, task *Task) (Result, error)
}

// Dependencies bundles the shared infrastructure handlers may need.
// Passed to each handler family's Register function so individual
// handler files don't have to thread these through their constructors.
type Dependencies struct {
	// Transport is the SwappableClient — handlers that talk to the
	// platform get the current mTLS-configured *transport.Client via
	// .Get(). Cert rotation can swap the inner client without breaking
	// inflight tasks.
	Transport *transport.SwappableClient
	// MountRunner is the os/exec abstraction for shell-based handlers
	// (systemctl, etc.). Tests inject mount.RecorderRunner.
	MountRunner mount.Runner
	// Reconciler is the module reconciler — sync / sync_modules tasks
	// drive a synchronous reconcile cycle through it.
	Reconciler RunOnceAPI
	// AgentVersion is reported in error events for diagnostics.
	AgentVersion string
}

// RunOnceAPI is the subset of *runtime.Reconciler the sync handler
// uses. Defined here as an interface to avoid an import cycle.
type RunOnceAPI interface {
	RunOnce(ctx context.Context) error
}

// HTTPClient is the minimal interface task client needs. Both
// *transport.Client and *transport.SwappableClient satisfy it.
type HTTPClient interface {
	GetJSON(path string) (*http.Response, error)
	PostJSON(path string, body []byte) (*http.Response, error)
}
