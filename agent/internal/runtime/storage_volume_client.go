package runtime

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"

	"github.com/nodealchemy/powernode-system/agent/internal/mount"
)

// FetchStorageVolume pulls the durable-storage binding the platform's
// PlatformDeploymentOrchestrator stamped onto NodeInstance.config.
// Returns (nil, nil) when no binding is set — the agent treats that as
// "no durable volume bound, nothing to reconcile".
//
// The platform endpoint is /api/v1/system/node_api/storage_volume and
// always returns 200 with `{success:true, data:{storage_volume: ...}}`
// where storage_volume may be null. We do NOT treat a null payload as
// an error — it's the steady-state for instances that haven't had a
// volume attached.
//
// Plan reference: E8.2 — consumer side of the
// orchestrator→agent storage_volume contract.
func FetchStorageVolume(ctx context.Context, c ModulesClient) (*mount.StorageVolumeBinding, error) {
	if c == nil {
		return nil, errors.New("FetchStorageVolume: nil client")
	}
	resp, err := c.GetJSON("/api/v1/system/node_api/storage_volume")
	if err != nil {
		return nil, fmt.Errorf("get storage_volume: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("storage_volume status %d: %s",
			resp.StatusCode, strings.TrimSpace(string(body)))
	}

	var env struct {
		Success bool   `json:"success"`
		Error   string `json:"error,omitempty"`
		Data    struct {
			StorageVolume *mount.StorageVolumeBinding `json:"storage_volume"`
		} `json:"data"`
	}
	if err := json.Unmarshal(body, &env); err != nil {
		return nil, fmt.Errorf("decode storage_volume: %w", err)
	}
	if !env.Success {
		return nil, fmt.Errorf("platform returned success=false: %s", env.Error)
	}
	_ = ctx
	return env.Data.StorageVolume, nil
}
