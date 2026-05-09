// Package fleetevent posts agent-side events to the platform's
// /api/v1/system/node_api/fleet/events endpoint. Used by:
//
//   - the long-loop reconciler (module.attached, module.detached)
//   - cert rotation (cert.rotated)
//   - the operator CLI (script.executed, volume.provisioned, etc.)
//
// Events flow into the same Fleet::EventBroadcaster pipeline that
// trading + system autonomy already use, so the agent's view appears
// in the unified activity feed. Reference: extensions/system/server
// /app/services/system/fleet/event_broadcaster.rb.
package fleetevent

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
)

// HTTPClient is the minimal subset of *transport.Client that Emitter
// needs. Defined as an interface so tests can stub without an httptest
// server. transport.Client and transport.SwappableClient both satisfy
// this shape via PostJSON.
type HTTPClient interface {
	PostJSON(path string, body []byte) (*http.Response, error)
}

// Severity strings the platform recognizes. low/medium have 1-day
// retention; high/critical have 365-day retention (audit trail).
const (
	SeverityLow      = "low"
	SeverityMedium   = "medium"
	SeverityHigh     = "high"
	SeverityCritical = "critical"
)

// Event is the payload shape the platform's FleetController#events
// expects. Source is filled in server-side ("agent"), so it's not part
// of the wire payload.
type Event struct {
	Kind          string         `json:"kind"`
	Severity      string         `json:"severity"`
	Payload       map[string]any `json:"payload,omitempty"`
	CorrelationID string         `json:"correlation_id,omitempty"`
}

// Emitter posts batches of events to the platform.
type Emitter struct {
	Client HTTPClient
	// Path overrides the default endpoint. Empty value uses
	// /api/v1/system/node_api/fleet/events.
	Path string
}

// New returns an Emitter wired to the canonical agent endpoint.
func New(c HTTPClient) *Emitter {
	return &Emitter{Client: c}
}

const defaultPath = "/api/v1/system/node_api/fleet/events"

// Emit posts a single event. Returns nil on 2xx response from the
// platform, error otherwise. Caller is responsible for retry policy —
// this is a fire-and-forget interface, not a queue.
func (e *Emitter) Emit(ctx context.Context, ev Event) error {
	return e.EmitBatch(ctx, []Event{ev})
}

// EmitBatch posts multiple events in one HTTP request. Used by the
// reconciler to batch attach + detach events from the same tick.
func (e *Emitter) EmitBatch(ctx context.Context, events []Event) error {
	if e == nil || e.Client == nil {
		return errors.New("fleetevent.Emitter: nil client")
	}
	if len(events) == 0 {
		return nil
	}
	for i := range events {
		if events[i].Kind == "" {
			return fmt.Errorf("fleetevent: events[%d].Kind is required", i)
		}
		if events[i].Severity == "" {
			events[i].Severity = SeverityLow
		}
	}

	body, err := json.Marshal(struct {
		Events []Event `json:"events"`
	}{Events: events})
	if err != nil {
		return fmt.Errorf("marshal events: %w", err)
	}

	path := e.Path
	if path == "" {
		path = defaultPath
	}

	resp, err := e.Client.PostJSON(path, body)
	if err != nil {
		return fmt.Errorf("post fleet events: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		respBody, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return fmt.Errorf("fleet events status %d: %s", resp.StatusCode, bytes.TrimSpace(respBody))
	}
	return nil
}
