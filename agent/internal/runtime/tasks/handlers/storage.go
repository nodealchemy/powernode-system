package handlers

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/nodealchemy/powernode-system/agent/internal/runtime/tasks"
	"github.com/nodealchemy/powernode-system/agent/internal/storage"
)

// StorageHandler routes all storage.* task commands to the right
// per-action implementation. Implements tasks.TaskHandler; one
// instance handles every storage.* command (registered against all of
// them in RegisterStorage).
type StorageHandler struct {
	deps tasks.Dependencies
}

// Execute dispatches based on task.Command. Each branch unmarshals the
// task's options into the typed payload and calls into the storage
// package. Errors include the command name so failure surfaces are
// self-explanatory in the platform's task error_message field.
func (h *StorageHandler) Execute(ctx context.Context, task *tasks.Task) (tasks.Result, error) {
	body, err := json.Marshal(task.Options)
	if err != nil {
		return nil, fmt.Errorf("%s: marshal options: %w", task.Command, err)
	}

	client := h.deps.Transport.Get()
	runner := h.deps.MountRunner

	switch task.Command {
	case "storage.mount":
		var mt storage.MountTask
		if err := json.Unmarshal(body, &mt); err != nil {
			return nil, fmt.Errorf("storage.mount unmarshal: %w", err)
		}
		if err := storage.Apply(ctx, runner, client, &mt); err != nil {
			return nil, err
		}
		return tasks.Result{"assignment_id": mt.AssignmentID, "mounted": true}, nil

	case "storage.unmount":
		var ut storage.UnmountTask
		if err := json.Unmarshal(body, &ut); err != nil {
			return nil, fmt.Errorf("storage.unmount unmarshal: %w", err)
		}
		if err := storage.Unapply(ctx, runner, &ut, storage.EncryptionSpec{}, ""); err != nil {
			return nil, err
		}
		return tasks.Result{"assignment_id": ut.AssignmentID, "unmounted": true}, nil

	case "storage.exports.apply":
		var et storage.ExportsApplyTask
		if err := json.Unmarshal(body, &et); err != nil {
			return nil, fmt.Errorf("storage.exports.apply unmarshal: %w", err)
		}
		if err := storage.ApplyExports(ctx, runner, &et); err != nil {
			return nil, err
		}
		return tasks.Result{"storage_id": et.StorageID, "entries": len(et.Entries)}, nil

	case "storage.smb_user.apply":
		var st storage.SmbUserApplyTask
		if err := json.Unmarshal(body, &st); err != nil {
			return nil, fmt.Errorf("storage.smb_user.apply unmarshal: %w", err)
		}
		if err := storage.ApplySambaUser(ctx, runner, &st); err != nil {
			return nil, err
		}
		return tasks.Result{"storage_id": st.StorageID, "username": st.Username, "action": st.Action}, nil

	case "storage.gateway.provision":
		var gp storage.GatewayProvisionTask
		if err := json.Unmarshal(body, &gp); err != nil {
			return nil, fmt.Errorf("storage.gateway.provision unmarshal: %w", err)
		}
		if err := storage.ProvisionGateway(ctx, runner, &gp); err != nil {
			return nil, err
		}
		return tasks.Result{"storage_id": gp.StorageID, "gateway_provisioned": true}, nil

	case "storage.gateway.deprovision":
		var gd storage.GatewayDeprovisionTask
		if err := json.Unmarshal(body, &gd); err != nil {
			return nil, fmt.Errorf("storage.gateway.deprovision unmarshal: %w", err)
		}
		if err := storage.DeprovisionGateway(ctx, runner, &gd); err != nil {
			return nil, err
		}
		return tasks.Result{"storage_id": gd.StorageID, "gateway_deprovisioned": true}, nil

	default:
		return nil, fmt.Errorf("unsupported storage command: %s", task.Command)
	}
}

// RegisterStorage binds every storage.* command to a single shared
// handler. Add new storage commands here and in the switch above.
func RegisterStorage(r *tasks.Registry, deps tasks.Dependencies) {
	h := &StorageHandler{deps: deps}
	for _, cmd := range []string{
		"storage.mount",
		"storage.unmount",
		"storage.exports.apply",
		"storage.smb_user.apply",
		"storage.gateway.provision",
		"storage.gateway.deprovision",
	} {
		r.Register(cmd, h)
	}
}
