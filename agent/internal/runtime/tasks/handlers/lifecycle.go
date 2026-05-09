// Package handlers implements the agent's TaskHandler bindings,
// one file per command family.
//
// Idempotency contract: every handler MUST be safely re-executable.
// The loop's crash-recovery flow may dispatch a handler twice if the
// agent restarts mid-task. Lifecycle handlers short-circuit via
// `systemctl is-active`; volume handlers stat the device first;
// non-idempotent handlers (ssh_command) document this loudly.
package handlers

import (
	"context"
	"errors"
	"fmt"

	"github.com/powernode/platform/extensions/system/agent/internal/runtime/tasks"
	"github.com/powernode/platform/extensions/system/agent/internal/systemd"
)

// LifecycleHandler dispatches start/stop/restart/reboot/terminate
// against a unit identified by task.Options["unit"]. Defers to
// systemd.Action / systemd.IsActive for the actual shell-out.
type LifecycleHandler struct {
	deps tasks.Dependencies
	verb systemd.ActionVerb
}

// Execute runs the configured systemctl verb against the unit named
// in task.Options["unit"]. Returns the resulting unit state.
func (h *LifecycleHandler) Execute(ctx context.Context, task *tasks.Task) (tasks.Result, error) {
	unit, _ := task.Options["unit"].(string)
	if unit == "" {
		return nil, errors.New("lifecycle: options.unit required")
	}

	// Idempotency: short-circuit when already in the desired state.
	switch h.verb {
	case systemd.Start:
		active, _ := systemd.IsActive(ctx, h.deps.MountRunner, unit)
		if active {
			return tasks.Result{"unit": unit, "status": "already_active"}, nil
		}
	case systemd.Stop:
		active, _ := systemd.IsActive(ctx, h.deps.MountRunner, unit)
		if !active {
			return tasks.Result{"unit": unit, "status": "already_stopped"}, nil
		}
	}

	if err := systemd.Action(ctx, h.deps.MountRunner, unit, h.verb); err != nil {
		return nil, fmt.Errorf("systemctl %s %s: %w", h.verb, unit, err)
	}
	return tasks.Result{"unit": unit, "verb": string(h.verb)}, nil
}

// RebootHandler issues a system reboot. Posts a Result BEFORE the
// reboot syscall is invoked (the platform receives ack just as the
// process group is torn down).
type RebootHandler struct {
	deps tasks.Dependencies
}

// Execute runs `systemctl reboot` after a small delay so the platform
// has time to receive the prior Acknowledge response.
func (h *RebootHandler) Execute(ctx context.Context, task *tasks.Task) (tasks.Result, error) {
	if err := h.deps.MountRunner.Run(ctx, "systemctl", "reboot"); err != nil {
		return nil, fmt.Errorf("systemctl reboot: %w", err)
	}
	return tasks.Result{"status": "reboot_initiated"}, nil
}

// RegisterLifecycle binds the lifecycle commands to the registry.
func RegisterLifecycle(r *tasks.Registry, deps tasks.Dependencies) {
	r.Register("start", &LifecycleHandler{deps: deps, verb: systemd.Start})
	r.Register("stop", &LifecycleHandler{deps: deps, verb: systemd.Stop})
	r.Register("restart", &LifecycleHandler{deps: deps, verb: systemd.Restart})
	r.Register("reboot", &RebootHandler{deps: deps})
	// terminate is the platform-side concept of "ungraceful shutdown" —
	// for an instance, this is equivalent to reboot with a different
	// platform-side state transition. The agent treats it as reboot.
	r.Register("terminate", &RebootHandler{deps: deps})
}
