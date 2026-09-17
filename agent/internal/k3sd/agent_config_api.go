// agent_config_api.go — agent-side HTTP client for the K3s agent
// runtime config endpoint. IMP-a5f236e8cc56 gap 3: the platform now
// surfaces the operator-set target_cluster_id (from the node's
// enabled k3s-agent NodeModuleAssignment#config) on the existing
// runtime/:runtime/config surface; this is the agent-side fetch path
// that closes the loop, so AgentManager.TargetClusterID finally has a
// producer.
//
// Mirrors bootstrap_config_api.go's HTTPBootstrapConfigClient shape
// so the runtime/service.go wiring follows the same template: fetch
// each PostSend tick, refresh the manager field, then Reconcile.

package k3sd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"

	"github.com/nodealchemy/powernode-system/agent/internal/transport"
)

// AgentConfigPath is the agent → platform endpoint that returns the
// K3s agent runtime config envelope for the calling NodeInstance.
// Same controller/route as BootstrapConfigPath, different runtime
// segment.
const AgentConfigPath = "/api/v1/system/node_api/runtime/k3s_agent/config"

// AgentConfigAPI is the surface AgentManager's refresh uses to fetch
// the platform-emitted target_cluster_id. Defined as an interface so
// tests inject a stub without standing up an httptest server.
type AgentConfigAPI interface {
	// FetchAgentConfig returns the target_cluster_id the platform
	// resolved for this node's enabled k3s-agent module assignment.
	// Empty is a normal steady state (no assignment, no config key,
	// or the id didn't name a live in-account cluster) — callers MUST
	// tolerate it, not treat it as an error.
	FetchAgentConfig(ctx context.Context) (targetClusterID string, err error)
}

// HTTPAgentConfigClient wraps a transport.Client to call the
// platform's runtime/k3s_agent/config endpoint. Mirrors the shape of
// HTTPBootstrapConfigClient for consistency.
type HTTPAgentConfigClient struct {
	transport *transport.Client
}

// NewHTTPAgentConfigClient constructs the production client.
func NewHTTPAgentConfigClient(t *transport.Client) *HTTPAgentConfigClient {
	return &HTTPAgentConfigClient{transport: t}
}

// agentConfigEnvelope captures the platform's
// render_success(data: { runtime, target_cluster_id, content_hash })
// shape: { success: true, data: {...} }.
type agentConfigEnvelope struct {
	Success bool   `json:"success"`
	Error   string `json:"error,omitempty"`
	Data    struct {
		Runtime         string `json:"runtime"`
		TargetClusterID string `json:"target_cluster_id"`
		ContentHash     string `json:"content_hash"`
	} `json:"data"`
}

// FetchAgentConfig implements AgentConfigAPI.
func (c *HTTPAgentConfigClient) FetchAgentConfig(ctx context.Context) (string, error) {
	if c.transport == nil || c.transport.Client == nil {
		return "", errors.New("HTTPAgentConfigClient: transport not configured")
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet,
		c.transport.PlatformURL+AgentConfigPath, nil)
	if err != nil {
		return "", fmt.Errorf("build request: %w", err)
	}

	resp, err := c.transport.Do(req)
	if err != nil {
		return "", fmt.Errorf("get agent config: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("read response: %w", err)
	}
	if resp.StatusCode == http.StatusForbidden {
		// Module not assigned — treat as "no target cluster", not an
		// error. The reconciler's main path already guards on
		// assignment, so this branch only fires in narrow races where
		// assignment changes between calls.
		return "", nil
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "", fmt.Errorf("agent config fetch failed: HTTP %d: %s", resp.StatusCode, string(body))
	}

	var env agentConfigEnvelope
	if err := json.Unmarshal(body, &env); err != nil {
		return "", fmt.Errorf("decode envelope: %w", err)
	}
	if !env.Success {
		return "", fmt.Errorf("platform returned success=false: %s", env.Error)
	}

	return env.Data.TargetClusterID, nil
}
