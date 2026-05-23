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

	case "storage.chown":
		var ct storage.ChownTask
		if err := json.Unmarshal(body, &ct); err != nil {
			return nil, fmt.Errorf("storage.chown unmarshal: %w", err)
		}
		err := storage.ApplyChown(ctx, &ct)
		// Whether the chown succeeds or fails, the agent POSTs to the
		// platform's callback so the StorageAssignment's chown_state
		// transitions correctly. Failures are reported as a non-nil
		// task error AND a callback with status=failed so the operator
		// sees the diagnostic in both surfaces.
		reportErr := postChownCompletion(client, &ct, err)
		if err != nil {
			return tasks.Result{
				"assignment_id": ct.StorageAssignmentID,
				"chown_status":  "failed",
				"error":         err.Error(),
			}, err
		}
		if reportErr != nil {
			return nil, fmt.Errorf("storage.chown completed but callback POST failed: %w", reportErr)
		}
		return tasks.Result{
			"assignment_id": ct.StorageAssignmentID,
			"chown_status":  "complete",
		}, nil

	default:
		return nil, fmt.Errorf("unsupported storage command: %s", task.Command)
	}
}

// postChownCompletion POSTs the storage.chown task outcome to the
// platform's worker_api callback. Called regardless of success — the
// platform-side state machine flips to complete or failed based on
// the body. If runErr is nil, status=complete; otherwise failed +
// error message.
func postChownCompletion(client tasks.HTTPClient, ct *storage.ChownTask, runErr error) error {
	if client == nil || ct == nil {
		return nil // no platform connection (e.g. dry-run / test)
	}
	path := ct.CallbackPath
	if path == "" {
		path = "/api/v1/system/worker_api/storage/chown_complete"
	}
	body := map[string]any{
		"storage_assignment_id": ct.StorageAssignmentID,
		"status":                "complete",
	}
	if runErr != nil {
		body["status"] = "failed"
		body["error_message"] = runErr.Error()
	}
	encoded, err := json.Marshal(body)
	if err != nil {
		return fmt.Errorf("marshal chown callback body: %w", err)
	}
	resp, err := client.PostJSON(path, encoded)
	if err != nil {
		return err
	}
	if resp != nil && resp.Body != nil {
		_ = resp.Body.Close()
	}
	if resp != nil && (resp.StatusCode < 200 || resp.StatusCode >= 300) {
		return fmt.Errorf("chown callback returned status %d", resp.StatusCode)
	}
	return nil
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
		"storage.chown",
	} {
		r.Register(cmd, h)
	}
}
