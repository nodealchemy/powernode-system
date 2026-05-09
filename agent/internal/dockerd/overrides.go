package dockerd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"

	"github.com/nodealchemy/powernode-system/agent/internal/transport"
)

// OverridesPath is the agent → platform endpoint that returns the
// merged daemon.json overrides for the calling NodeInstance. Slice 10.
const OverridesPath = "/api/v1/system/node_api/runtime/docker/config"

// OverridesAPI is the surface the docker reconciler uses to fetch
// operator-supplied daemon.json overrides. Defined as an interface so
// tests can inject a stub without standing up an httptest server.
type OverridesAPI interface {
	// FetchOverrides returns the merged operator overrides for the
	// docker daemon and a content_hash the caller can use to
	// short-circuit no-change ticks. The map may be empty (no
	// dependant config-variety modules assigned); callers MUST
	// tolerate that as a normal steady state, not an error.
	FetchOverrides(ctx context.Context) (map[string]any, string, error)
}

// HTTPOverridesClient wraps a transport.Client to call the platform's
// runtime/docker/config endpoint. Mirrors HTTPModulesClient's shape
// for consistency.
type HTTPOverridesClient struct {
	transport *transport.Client
}

// NewHTTPOverridesClient constructs the production client.
func NewHTTPOverridesClient(t *transport.Client) *HTTPOverridesClient {
	return &HTTPOverridesClient{transport: t}
}

// overridesEnvelope captures the platform's
// render_success(data: { runtime, daemon_overrides, content_hash })
// shape: { success: true, data: {...} }.
type overridesEnvelope struct {
	Success bool   `json:"success"`
	Error   string `json:"error,omitempty"`
	Data    struct {
		Runtime         string         `json:"runtime"`
		DaemonOverrides map[string]any `json:"daemon_overrides"`
		ContentHash     string         `json:"content_hash"`
	} `json:"data"`
}

// FetchOverrides implements OverridesAPI.
func (c *HTTPOverridesClient) FetchOverrides(ctx context.Context) (map[string]any, string, error) {
	if c.transport == nil || c.transport.Client == nil {
		return nil, "", errors.New("HTTPOverridesClient: transport not configured")
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet,
		c.transport.PlatformURL+OverridesPath, nil)
	if err != nil {
		return nil, "", fmt.Errorf("build request: %w", err)
	}
	if c.transport.InstanceToken != "" {
		req.Header.Set("Authorization", "Bearer "+c.transport.InstanceToken)
	}

	resp, err := c.transport.Do(req)
	if err != nil {
		return nil, "", fmt.Errorf("get overrides: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, "", fmt.Errorf("read response: %w", err)
	}
	if resp.StatusCode == http.StatusForbidden {
		// Module not assigned — treat as "no overrides", not an error.
		// The reconciler's main path already guards on assignment, so
		// this branch only fires in narrow races where assignment
		// changes between the modules-list call and this call.
		return map[string]any{}, "", nil
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, "", fmt.Errorf("overrides fetch failed: HTTP %d: %s", resp.StatusCode, string(body))
	}

	var env overridesEnvelope
	if err := json.Unmarshal(body, &env); err != nil {
		return nil, "", fmt.Errorf("decode envelope: %w", err)
	}
	if !env.Success {
		return nil, "", fmt.Errorf("platform returned success=false: %s", env.Error)
	}

	if env.Data.DaemonOverrides == nil {
		env.Data.DaemonOverrides = map[string]any{}
	}
	return env.Data.DaemonOverrides, env.Data.ContentHash, nil
}
