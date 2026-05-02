// Package runtime is the agent's long-lived service mode: heartbeat,
// task lease, cert rotation, and reconciliation. Each runs in its own
// goroutine; service.Run() ties them together.
//
// Reference: Golden Eclipse plan M2.E.
package runtime

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"

	"github.com/powernode/platform/extensions/system/agent/internal/transport"
)

// HeartbeatPayload is the body the agent POSTs to /status/heartbeat.
// Mirrors the platform's M0.M NodeInstance#record_heartbeat! parameters.
type HeartbeatPayload struct {
	BootID         string            `json:"boot_id"`
	AgentVersion   string            `json:"agent_version"`
	Architecture   string            `json:"architecture,omitempty"`
	UptimeSeconds  int64             `json:"uptime_seconds"`
	ModuleDigests  map[string]string `json:"module_digests"` // node_module_id → oci_digest
	MountState     string            `json:"mount_state"`     // "mounted" | "unmounted" | "transitioning"
	LoadAverage    string            `json:"load_average,omitempty"`
	MemoryFreeKB   int64             `json:"memory_free_kb,omitempty"`
}

// HeartbeatResponse is what the platform sends back. Includes a hint at
// the next poll interval (lets the platform throttle agents under load).
type HeartbeatResponse struct {
	Success bool `json:"success"`
	Data    struct {
		Acknowledged    bool `json:"acknowledged"`
		PendingTasks    int  `json:"tasks_pending"`
		NextPollSeconds int  `json:"next_poll_seconds"`
	} `json:"data"`
}

// Heartbeat sends one HeartbeatPayload + parses the response.
type Heartbeater struct {
	Client       *transport.Client
	StartedAt    time.Time
	BuildPayload func() HeartbeatPayload // closure that gathers fresh runtime metrics
}

// Send delivers one heartbeat. Returns the parsed response so callers
// can adjust their poll interval based on platform feedback.
func (h *Heartbeater) Send(ctx context.Context) (*HeartbeatResponse, error) {
	payload := h.BuildPayload()
	if h.StartedAt.IsZero() {
		h.StartedAt = time.Now()
	}
	payload.UptimeSeconds = int64(time.Since(h.StartedAt).Seconds())

	body, err := json.Marshal(payload)
	if err != nil {
		return nil, fmt.Errorf("marshal heartbeat: %w", err)
	}

	resp, err := postJSON(ctx, h.Client, "/api/v1/system/node_api/status/heartbeat", body)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(io.LimitReader(resp.Body, 64*1024))

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("heartbeat status %d: %s", resp.StatusCode, string(respBody))
	}
	var hr HeartbeatResponse
	if err := json.Unmarshal(respBody, &hr); err != nil {
		return nil, fmt.Errorf("parse heartbeat response: %w", err)
	}
	return &hr, nil
}

// Run loops Send + sleep until ctx is canceled. The next-poll-seconds
// hint from the platform is honored when present; otherwise falls back
// to defaultInterval.
func (h *Heartbeater) Run(ctx context.Context, defaultInterval time.Duration, onError func(error)) {
	if defaultInterval <= 0 {
		defaultInterval = 30 * time.Second
	}
	for {
		select {
		case <-ctx.Done():
			return
		default:
		}

		nextInterval := defaultInterval
		hr, err := h.Send(ctx)
		if err != nil {
			if onError != nil {
				onError(err)
			}
		} else if hr.Data.NextPollSeconds > 0 {
			nextInterval = time.Duration(hr.Data.NextPollSeconds) * time.Second
		}

		select {
		case <-ctx.Done():
			return
		case <-time.After(nextInterval):
		}
	}
}

// postJSON is a small helper since transport.Client.PostJSON returns
// the raw response (we want to parse status + body uniformly).
func postJSON(ctx context.Context, c *transport.Client, path string, body []byte) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.PlatformURL+path, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	return c.Do(req)
}
