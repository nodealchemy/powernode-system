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

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
	"github.com/nodealchemy/powernode-system/agent/internal/transport"
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
	// PKIDir is the agent's enrolled PKI directory (node.crt/key/ca-chain).
	// The a2a_call handler loads this node's identity from it to present as the
	// A2A client cert when executing a mission-delegated peer call.
	PKIDir string
}

// RunOnceAPI is the subset of *runtime.Reconciler the sync handler
// uses. Defined here as an interface to avoid an import cycle.
type RunOnceAPI interface {
	RunOnce(ctx context.Context) error
	// ClearAttachedManifestHashes drops the stamps the reattach gate compares,
	// forcing the next reconcile to re-materialize a module's files (or every
	// module's, when the id is empty). Needed because a plain RunOnce cannot
	// repair a root whose files were removed underneath an UNCHANGED digest —
	// nothing drifts in that state, so the reconcile correctly does nothing.
	ClearAttachedManifestHashes(moduleID string) error
}

// ConvergenceReporter is an OPTIONAL companion to RunOnceAPI: a reconciler that
// can report which modules failed to reach their desired state during the last
// pass. Kept separate from RunOnceAPI, and consumed via type assertion, so the
// existing fakes that implement RunOnceAPI keep compiling unchanged.
//
// IMP-f1c1e6d61104 — this exists because RunOnce returns an error only for
// whole-pass failures. Per-module failures (a reboot_required module declining
// live materialization, a scratch-budget abort, a copy error, an unpublished
// digest) report through OnError, which in service mode is a stderr printf the
// platform never sees. The task therefore COMPLETED while the node had not
// converged, and the server's ConfigDriftSensor suppresses drift for a node on
// a completed apply_config — so a vacuous completion silenced real drift.
type ConvergenceReporter interface {
	ConvergenceFailures() []string
}

// HTTPClient is the minimal interface task client needs. Both
// *transport.Client and *transport.SwappableClient satisfy it.
type HTTPClient interface {
	GetJSON(path string) (*http.Response, error)
	PostJSON(path string, body []byte) (*http.Response, error)
}
