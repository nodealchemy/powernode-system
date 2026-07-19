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

	"github.com/nodealchemy/powernode-system/agent/internal/sdwan"
	"github.com/nodealchemy/powernode-system/agent/internal/transport"
)

// HeartbeatPayload is the body the agent POSTs to /status/heartbeat.
// Mirrors the platform's M0.M NodeInstance#record_heartbeat! parameters.
type HeartbeatPayload struct {
	BootID        string                  `json:"boot_id"`
	AgentVersion  string                  `json:"agent_version"`
	Architecture  string                  `json:"architecture,omitempty"`
	UptimeSeconds int64                   `json:"uptime_seconds"`
	ModuleDigests map[string]string       `json:"module_digests"` // node_module_id → oci_digest
	MountState    string                  `json:"mount_state"`    // "mounted" | "unmounted" | "transitioning"
	LoadAverage   string                  `json:"load_average,omitempty"`
	MemoryFreeKB  int64                   `json:"memory_free_kb,omitempty"`
	SdwanState    []sdwan.HeartbeatStatus `json:"sdwan_state,omitempty"`
	// Capabilities is the agent-detected kernel capability set
	// (erofs, overlayfs, fs-verity). The server records this on every
	// heartbeat for fleet introspection ("which nodes can mount
	// erofs?") and as a sanity gate before reconciling modules onto
	// a node. Detection runs once at service startup (see
	// internal/runtime/capabilities.go) and is stable across reboots
	// until the kernel changes.
	Capabilities *NodeCapabilities `json:"node_capabilities,omitempty"`
	// BootedImageGitSHA is the git_sha baked into the disk image this node
	// booted from (campaign 019f505f). Read once at service startup from the UKI
	// kernel cmdline (powernode.image_git_sha=); stable for the life of the boot,
	// so it's snapshotted rather than re-read each tick. The platform compares it
	// against the promoted image's git_sha to detect boot-image drift. Empty
	// (omitted) on netboot / non-UKI / pre-019f505f images that don't bake it —
	// the server reads that as "unknown", never drift.
	BootedImageGitSHA string `json:"booted_image_git_sha,omitempty"`
	// BootedFromLKG is true when this boot's ComposeForPivot fell back to the
	// frozen boot-LKG because the control plane was unreachable (#39 Level-1
	// boot-independence). Read from the boot breadcrumb; the platform surfaces it
	// so an operator can SEE which nodes are surviving on a frozen composition.
	BootedFromLKG bool `json:"booted_from_lkg,omitempty"`
	// LKGAgeSeconds is the age of the boot-LKG this node booted from (only
	// meaningful when BootedFromLKG). Lets the platform ALERT on a node running
	// an increasingly-stale frozen composition after its control plane went away.
	LKGAgeSeconds int64 `json:"lkg_age_seconds,omitempty"`
	// LKGPresent + LKGConfirmedAt + LKGModuleCount are ARM-telemetry (#39 HIGH-1):
	// emitted on EVERY boot's heartbeat (not just fallback boots) from the
	// on-disk frozen LKG, so an operator can VERIFY a node is armed with a valid
	// last-known-good BEFORE decommissioning its control plane (#14). Absence of
	// lkg_present=true means "not armed" — a decommission-blocking signal.
	LKGPresent     bool   `json:"lkg_present,omitempty"`
	LKGConfirmedAt string `json:"lkg_confirmed_at,omitempty"`
	LKGModuleCount int    `json:"lkg_module_count,omitempty"`
	// BootIncomplete is true when THIS boot composed an incomplete assigned set
	// (a data module was dropped at compose). The capturer skips LKG capture on
	// such a boot; this field makes the degraded boot directly visible.
	BootIncomplete bool `json:"boot_incomplete,omitempty"`
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
	// PostSend, if non-nil, is invoked after each successful heartbeat. The
	// service uses it to refresh ancillary state (e.g. authorized_keys) on the
	// same cadence without spinning up a separate goroutine.
	PostSend func()
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
		} else {
			if hr.Data.NextPollSeconds > 0 {
				nextInterval = time.Duration(hr.Data.NextPollSeconds) * time.Second
			}
			if h.PostSend != nil {
				h.PostSend()
			}
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
