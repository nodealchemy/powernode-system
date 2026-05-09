package handlers

import (
	"context"

	"github.com/powernode/platform/extensions/system/agent/internal/runtime/tasks"
)

// PassthroughHandler acks and completes the task without doing any
// node-side work. Used for platform-side concepts (provision,
// deprovision) where the heavy lifting happens server-side and the
// agent's role is just to confirm it observed the dispatched task.
//
// This pattern keeps the platform's task table consistent (every
// dispatched task has an explicit completion event) without forcing
// the agent to interpret commands it has no actual work to do for.
type PassthroughHandler struct {
	Note string
}

// Execute returns a static result describing what the handler
// observed. The Note field becomes the result.note for operator
// visibility in the activity feed.
func (h *PassthroughHandler) Execute(_ context.Context, task *tasks.Task) (tasks.Result, error) {
	return tasks.Result{
		"command": task.Command,
		"status":  "noop_passthrough",
		"note":    h.Note,
	}, nil
}

// RegisterPassthrough binds command names whose execution is purely
// platform-side. The agent acks + completes them with a noop result.
func RegisterPassthrough(r *tasks.Registry, _ tasks.Dependencies) {
	r.Register("provision", &PassthroughHandler{
		Note: "provision is a platform-side concept; agent observed dispatch",
	})
	r.Register("deprovision", &PassthroughHandler{
		Note: "deprovision is a platform-side concept; agent observed dispatch",
	})
}
