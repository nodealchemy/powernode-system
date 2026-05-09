package runtime

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
)

// AssignedModule is the typed view of one entry returned by
// GET /api/v1/system/node_api/modules. The reconciler uses these
// to drive its desired-state computation.
type AssignedModule struct {
	ID                string `json:"id"`
	Name              string `json:"name"`
	Priority          int    `json:"priority"`
	EffectivePriority int    `json:"effective_priority"`
	HasDataFile       bool   `json:"has_data_file"`
	Variety           string `json:"variety"`
}

// ModulesClient is the minimal subset *transport.Client must satisfy
// for the reconciler to fetch the assigned-modules list.
type ModulesClient interface {
	GetJSON(path string) (*http.Response, error)
}

// FetchAssignedModules returns the rich-shape module list the
// reconciler needs (id + priority + variety + has_data_file flag).
//
// The platform endpoint `/api/v1/system/node_api/modules` returns
// `serialize_module` per row — this decoder picks out the fields
// the reconciler cares about and ignores the rest.
func FetchAssignedModules(ctx context.Context, c ModulesClient) ([]AssignedModule, error) {
	if c == nil {
		return nil, errors.New("FetchAssignedModules: nil client")
	}
	resp, err := c.GetJSON("/api/v1/system/node_api/modules")
	if err != nil {
		return nil, fmt.Errorf("get modules: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("modules status %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}

	var env struct {
		Success bool   `json:"success"`
		Error   string `json:"error,omitempty"`
		Data    struct {
			Modules []AssignedModule `json:"modules"`
		} `json:"data"`
	}
	if err := json.Unmarshal(body, &env); err != nil {
		return nil, fmt.Errorf("decode modules: %w", err)
	}
	if !env.Success {
		return nil, fmt.Errorf("platform returned success=false: %s", env.Error)
	}
	_ = ctx // ctx reserved for future cancellation hook in the GetJSON impl
	return env.Data.Modules, nil
}
