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
	"fmt"

	"github.com/nodealchemy/powernode-system/agent/internal/lifecycle"
	"github.com/nodealchemy/powernode-system/agent/internal/runtime/tasks"
	"github.com/nodealchemy/powernode-system/agent/internal/systemd"
	"github.com/nodealchemy/powernode-system/agent/internal/taskguard"
)

// LifecycleHandler dispatches start/stop/restart against ONE unit this
// node's agent generated, identified by task.Options["unit"]. Defers to
// systemd.Action / systemd.IsActive for the actual shell-out.
type LifecycleHandler struct {
	deps tasks.Dependencies
	verb systemd.ActionVerb
}

// The two fixed halves of lifecycle.UnitName's format,
// "powernode-<module-id>-<service>.service". TestManagedUnitShapeMatches-
// LifecycleGenerator pins them against the generator itself.
const (
	managedUnitPrefix = "powernode-"
	managedUnitSuffix = ".service"
)

// validateUnit is the ONE place options["unit"] is checked before it reaches
// systemctl as root. See package taskguard for why this lives at the agent:
// the node API serves every pending task on the instance to the agent, and
// TasksController#create permits options: {} as free-form JSONB, so the value
// is chosen by whoever holds system.infra_tasks.create — an AI agent included.
//
// Three rules, composed in this order and each doing one job:
//
//   - UnitName confines the value to a single ".service" filename: no
//     separator, no "..", no control character, so the Join below cannot be
//     steered out of the unit directory.
//   - NamePrefix requires lifecycle.UnitName's "powernode-" stamp.
//   - InstalledUnit requires a regular file of that exact name in
//     lifecycle.UnitDir() — the set lifecycle.AttachServices materialised on
//     THIS node. This is what separates a module unit from sshd.service,
//     powernode-agent.service, or any other legal unit the agent never wrote.
//
// The only in-process producer, System::RestartAfterUpdate#enqueue_restart!,
// names RestartAfterUpdate.unit_name(target.id, service) for a module attached
// to the node, which is exactly a name AttachServices wrote; the acceptance
// half of lifecycle_guard_test.go generates its fixtures through
// lifecycle.AttachServicesMode for that reason rather than from literals.
func validateUnit(unit string) error {
	if err := taskguard.UnitName("unit", unit, managedUnitSuffix); err != nil {
		return err
	}
	if err := taskguard.NamePrefix("unit", unit, managedUnitPrefix); err != nil {
		return err
	}
	return taskguard.InstalledUnit("unit", unit, lifecycle.UnitDir())
}

// Execute runs the configured systemctl verb against the unit named
// in task.Options["unit"]. Returns the resulting unit state. Refuses,
// before any systemctl call (the idempotency probe included), a unit
// that is not one this node's agent generated.
func (h *LifecycleHandler) Execute(ctx context.Context, task *tasks.Task) (tasks.Result, error) {
	unit, _ := task.Options["unit"].(string)
	if err := validateUnit(unit); err != nil {
		return nil, fmt.Errorf("lifecycle %s: %w", h.verb, err)
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
