// bootstrap_config_api.go — agent-side HTTP client for the K3s
// server bootstrap config endpoint. The platform's controller emits
// the per-host BootstrapConfig (currently carrying just cni_plugin,
// but designed to grow with future install knobs); the agent fetches
// it and sets ServerManager.Bootstrap before each K3s install.
//
// Mirrors dockerd.OverridesAPI's interface + HTTPOverridesClient
// shape so the runtime/service.go wiring follows the same template.
//
// Phase O4 follow-up — closes the loop the original O4 work left
// dangling (k3sd had the consumption struct but no fetch path).

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

// BootstrapConfigPath is the agent → platform endpoint that returns
// the K3s server bootstrap config envelope for the calling
// NodeInstance. Mirrors dockerd's runtime/docker/config layout.
const BootstrapConfigPath = "/api/v1/system/node_api/runtime/k3s_server/config"

// BootstrapConfigAPI is the surface ServerManager uses to fetch the
// platform-emitted K3s server install knobs (cni_plugin today, future
// fields like cluster-cidr / service-cidr / node-ip later). Defined as
// an interface so tests inject a stub without standing up an httptest
// server.
type BootstrapConfigAPI interface {
	// FetchBootstrapConfig returns the bootstrap config + a content_hash
	// the caller can use to short-circuit no-change ticks. The struct
	// may be zero-valued (no operator config); callers MUST tolerate
	// that as a normal steady state, not an error.
	FetchBootstrapConfig(ctx context.Context) (BootstrapConfig, string, error)
}

// HTTPBootstrapConfigClient wraps a transport.Client to call the
// platform's runtime/k3s_server/config endpoint. Mirrors the shape of
// HTTPOverridesClient for consistency.
type HTTPBootstrapConfigClient struct {
	transport *transport.Client
}

// NewHTTPBootstrapConfigClient constructs the production client.
func NewHTTPBootstrapConfigClient(t *transport.Client) *HTTPBootstrapConfigClient {
	return &HTTPBootstrapConfigClient{transport: t}
}

// bootstrapConfigEnvelope captures the platform's
// render_success(data: { runtime, bootstrap_config, content_hash })
// shape: { success: true, data: {...} }.
type bootstrapConfigEnvelope struct {
	Success bool   `json:"success"`
	Error   string `json:"error,omitempty"`
	Data    struct {
		Runtime         string          `json:"runtime"`
		BootstrapConfig BootstrapConfig `json:"bootstrap_config"`
		ContentHash     string          `json:"content_hash"`
	} `json:"data"`
}

// FetchBootstrapConfig implements BootstrapConfigAPI.
func (c *HTTPBootstrapConfigClient) FetchBootstrapConfig(ctx context.Context) (BootstrapConfig, string, error) {
	if c.transport == nil || c.transport.Client == nil {
		return BootstrapConfig{}, "", errors.New("HTTPBootstrapConfigClient: transport not configured")
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet,
		c.transport.PlatformURL+BootstrapConfigPath, nil)
	if err != nil {
		return BootstrapConfig{}, "", fmt.Errorf("build request: %w", err)
	}
	if c.transport.InstanceToken != "" {
		req.Header.Set("Authorization", "Bearer "+c.transport.InstanceToken)
	}

	resp, err := c.transport.Do(req)
	if err != nil {
		return BootstrapConfig{}, "", fmt.Errorf("get bootstrap config: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return BootstrapConfig{}, "", fmt.Errorf("read response: %w", err)
	}
	if resp.StatusCode == http.StatusForbidden {
		// Module not assigned — treat as "no bootstrap config", not an
		// error. The reconciler's main path already guards on
		// assignment, so this branch only fires in narrow races where
		// assignment changes between calls.
		return BootstrapConfig{}, "", nil
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return BootstrapConfig{}, "", fmt.Errorf("bootstrap config fetch failed: HTTP %d: %s", resp.StatusCode, string(body))
	}

	var env bootstrapConfigEnvelope
	if err := json.Unmarshal(body, &env); err != nil {
		return BootstrapConfig{}, "", fmt.Errorf("decode envelope: %w", err)
	}
	if !env.Success {
		return BootstrapConfig{}, "", fmt.Errorf("platform returned success=false: %s", env.Error)
	}

	return env.Data.BootstrapConfig, env.Data.ContentHash, nil
}
