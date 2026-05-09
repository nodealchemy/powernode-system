package handlers

import (
	"context"
	"errors"
	"fmt"

	"github.com/nodealchemy/powernode-system/agent/internal/runtime/tasks"
)

// SSHHandler runs an arbitrary shell command via the agent's
// MountRunner. NOT idempotent — re-execution on agent restart will
// run the command twice. The platform's task reaper handles stuck
// tasks; operators should NOT use ssh_command for non-idempotent
// state mutations they care about being applied once.
type SSHHandler struct {
	deps tasks.Dependencies
}

// Execute reads task.Options["command"] (string) and runs it via
// `bash -lc <command>`. Returns stdout/stderr captured as a result.
func (h *SSHHandler) Execute(ctx context.Context, task *tasks.Task) (tasks.Result, error) {
	cmd, _ := task.Options["command"].(string)
	if cmd == "" {
		return nil, errors.New("ssh_command: options.command required")
	}
	out, err := h.deps.MountRunner.Output(ctx, "bash", "-lc", cmd)
	result := tasks.Result{
		"command": cmd,
		"output":  string(out),
	}
	if err != nil {
		return result, fmt.Errorf("ssh_command failed: %w", err)
	}
	return result, nil
}

// RegisterSSH binds the ssh_command + custom commands. custom is the
// catch-all for operator-defined task types — agent dispatches it the
// same way as ssh_command, expecting options.command.
func RegisterSSH(r *tasks.Registry, deps tasks.Dependencies) {
	h := &SSHHandler{deps: deps}
	r.Register("ssh_command", h)
	r.Register("custom", h)
}
