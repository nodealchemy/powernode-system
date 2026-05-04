package dockerd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"

	"github.com/powernode/platform/extensions/system/agent/internal/transport"
)

// ModulesPath is the agent → platform endpoint that lists the assigned
// modules for the calling NodeInstance's Node. Read-only; mounted under
// the standard mTLS+JWT auth chain.
const ModulesPath = "/api/v1/system/node_api/modules"

// ModulesAPI is the surface the docker reconciler uses to learn
// whether the docker-engine module is assigned. Defined as an
// interface so tests can stub the round-trip without standing up an
// httptest server for every state-machine case.
type ModulesAPI interface {
	// AssignedModules returns the names of all enabled NodeModules
	// assigned to this instance's Node. The reconciler compares
	// against "docker-engine" (and in Phase 2, "k3s-server" /
	// "k3s-agent") to decide what to act on.
	AssignedModules(ctx context.Context) ([]string, error)
}

// HTTPModulesClient wraps a transport.Client to call the platform's
// modules listing endpoint. The transport handles mTLS + auth; this
// type just decodes the envelope.
type HTTPModulesClient struct {
	transport *transport.Client
}

// NewHTTPModulesClient constructs the production client.
func NewHTTPModulesClient(t *transport.Client) *HTTPModulesClient {
	return &HTTPModulesClient{transport: t}
}

// moduleSummary mirrors the controller's serialize_module shape. We
// only need the `name` field for the reconciler — everything else is
// used by the M2.E mount reconciler, which has its own decoder.
type moduleSummary struct {
	Name string `json:"name"`
}

// modulesEnvelope captures the platform's render_success(modules: [...])
// shape: { success: true, data: { modules: [...], count: N } }.
type modulesEnvelope struct {
	Success bool   `json:"success"`
	Error   string `json:"error,omitempty"`
	Data    struct {
		Modules []moduleSummary `json:"modules"`
		Count   int             `json:"count"`
	} `json:"data"`
}

// AssignedModules implements ModulesAPI. Returns the names of all
// enabled modules assigned to this Node.
func (c *HTTPModulesClient) AssignedModules(ctx context.Context) ([]string, error) {
	if c.transport == nil || c.transport.Client == nil {
		return nil, errors.New("HTTPModulesClient: transport not configured")
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet,
		c.transport.PlatformURL+ModulesPath, nil)
	if err != nil {
		return nil, fmt.Errorf("build request: %w", err)
	}
	if c.transport.InstanceToken != "" {
		req.Header.Set("Authorization", "Bearer "+c.transport.InstanceToken)
	}

	resp, err := c.transport.Do(req)
	if err != nil {
		return nil, fmt.Errorf("get modules: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("read response: %w", err)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("modules list failed: HTTP %d: %s", resp.StatusCode, string(body))
	}

	var env modulesEnvelope
	if err := json.Unmarshal(body, &env); err != nil {
		return nil, fmt.Errorf("decode envelope: %w", err)
	}
	if !env.Success {
		return nil, fmt.Errorf("platform returned success=false: %s", env.Error)
	}

	names := make([]string, 0, len(env.Data.Modules))
	for _, m := range env.Data.Modules {
		if m.Name != "" {
			names = append(names, m.Name)
		}
	}
	return names, nil
}
