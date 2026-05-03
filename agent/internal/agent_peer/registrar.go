// Package agent_peer implements the NodeInstance-as-Agent peer registration
// protocol. After enrollment, the agent self-announces to the platform with
// its declared capabilities, skills, and addresses. The platform creates a
// System::NodeInstancePeer row (auto-disabled until operator activation).
//
// Re-announcement is triggered when capabilities change (module attach/
// detach, hardware delta detected). The platform deduplicates by
// node_instance_id.
//
// Reference: comprehensive stabilization sweep P6; Golden Eclipse F-3.
package agent_peer

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"sync"
	"time"
)

// Capabilities describes what a NodeInstance peer can be delegated to do.
// Hardware-derived (CPU/RAM/disk/GPU) plus module-derived (loaded modules
// each contribute their declared skills).
type Capabilities struct {
	HardwareSummary string         `json:"hardware_summary,omitempty"`
	ResourceLimits  ResourceLimits `json:"resource_limits,omitempty"`
	LoadedModules   []string       `json:"loaded_modules,omitempty"`
	OS              string         `json:"os,omitempty"`
	Arch            string         `json:"arch,omitempty"`
	KernelVersion   string         `json:"kernel_version,omitempty"`
	AgentVersion    string         `json:"agent_version,omitempty"`
}

type ResourceLimits struct {
	CPUCount   int    `json:"cpu_count,omitempty"`
	MemoryMB   int    `json:"memory_mb,omitempty"`
	DiskGB     int    `json:"disk_gb,omitempty"`
	GPUSummary string `json:"gpu_summary,omitempty"`
}

// Skill is a capability declared by a loaded module.
type Skill struct {
	Name   string                 `json:"name"`
	Schema map[string]interface{} `json:"schema,omitempty"`
}

// AnnouncePayload is the body POSTed to /api/v1/system/node_api/peer/announce.
type AnnouncePayload struct {
	Capabilities Capabilities `json:"capabilities"`
	Skills       []Skill      `json:"skills"`
	Addresses    []string     `json:"addresses"`
}

// AnnounceResponse is the structured response from a successful announce.
type AnnounceResponse struct {
	Success bool `json:"success"`
	Data    struct {
		Peer struct {
			ID          string  `json:"id"`
			Handle      string  `json:"handle"`
			Status      string  `json:"status"`
			Enabled     bool    `json:"enabled"`
			TrustScore  float64 `json:"trust_score"`
		} `json:"peer"`
		Created bool `json:"created"`
	} `json:"data"`
}

// HTTPClient is the minimal interface the Registrar needs from the
// platform mTLS transport client.
type HTTPClient interface {
	Do(req *http.Request) (*http.Response, error)
}

// Registrar tracks announcement state across capability changes and handles
// retry-with-backoff on transient platform unavailability.
type Registrar struct {
	platformBaseURL string
	httpClient      HTTPClient

	mu             sync.Mutex
	lastAnnounce   time.Time
	announcedHash  string
	consecutiveErrs int
}

const (
	// MaxAnnounceBodyBytes caps the announce request body to prevent
	// resource-constrained devices from emitting huge payloads.
	MaxAnnounceBodyBytes = 16 * 1024

	// MinReannounceInterval throttles capability re-announces so that
	// flapping modules don't spam the platform.
	MinReannounceInterval = 60 * time.Second

	announceTimeout = 30 * time.Second
)

// New constructs a Registrar. platformBaseURL is the absolute URL of the
// platform API (e.g., "https://platform.example.com").
func New(platformBaseURL string, httpClient HTTPClient) *Registrar {
	return &Registrar{
		platformBaseURL: platformBaseURL,
		httpClient:      httpClient,
	}
}

// Announce sends an AnnouncePayload to the platform. Returns the response on
// success, or an error. Throttles re-announces to MinReannounceInterval
// unless the payload hash has changed (capability delta forces immediate).
func (r *Registrar) Announce(ctx context.Context, payload AnnouncePayload) (*AnnounceResponse, error) {
	r.mu.Lock()
	defer r.mu.Unlock()

	hash := payloadHash(payload)
	if hash == r.announcedHash && time.Since(r.lastAnnounce) < MinReannounceInterval {
		return nil, fmt.Errorf("announce throttled (last: %s ago)", time.Since(r.lastAnnounce))
	}

	body, err := json.Marshal(payload)
	if err != nil {
		return nil, fmt.Errorf("marshal: %w", err)
	}
	if len(body) > MaxAnnounceBodyBytes {
		return nil, fmt.Errorf("announce body exceeds %d bytes (got %d)", MaxAnnounceBodyBytes, len(body))
	}

	url := r.platformBaseURL + "/api/v1/system/node_api/peer/announce"
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("new request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := r.httpClient.Do(req)
	if err != nil {
		r.consecutiveErrs++
		return nil, fmt.Errorf("do: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 400 {
		r.consecutiveErrs++
		return nil, fmt.Errorf("platform returned %d", resp.StatusCode)
	}

	var ar AnnounceResponse
	if err := json.NewDecoder(resp.Body).Decode(&ar); err != nil {
		return nil, fmt.Errorf("decode: %w", err)
	}

	r.announcedHash = hash
	r.lastAnnounce = time.Now()
	r.consecutiveErrs = 0
	return &ar, nil
}

// LastAnnounce returns the timestamp of the most-recent successful announce.
func (r *Registrar) LastAnnounce() time.Time {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.lastAnnounce
}

// ConsecutiveErrors returns the count of consecutive announce failures
// since the last success. Callers can use this to drive fallback behavior
// (e.g., heartbeat-only mode after N failures).
func (r *Registrar) ConsecutiveErrors() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.consecutiveErrs
}

// payloadHash derives a stable hash of the payload's content for dedup.
func payloadHash(payload AnnouncePayload) string {
	body, _ := json.Marshal(payload)
	return fmt.Sprintf("%x", body[:min(64, len(body))])
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
