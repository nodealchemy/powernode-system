package agent_peer

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
)

type fakeHTTPClient struct {
	calls    int
	response string
	status   int
	err      error
}

func (f *fakeHTTPClient) Do(req *http.Request) (*http.Response, error) {
	f.calls++
	if f.err != nil {
		return nil, f.err
	}
	body := io.NopCloser(strings.NewReader(f.response))
	return &http.Response{
		StatusCode: f.status,
		Body:       body,
	}, nil
}

func TestAnnounce_Success(t *testing.T) {
	fake := &fakeHTTPClient{
		status: 200,
		response: `{"success":true,"data":{"peer":{"id":"peer-1","handle":"instance-abc","status":"active","enabled":false,"trust_score":0.5},"created":true}}`,
	}
	r := New("https://platform.example.com", fake)

	resp, err := r.Announce(context.Background(), AnnouncePayload{
		Capabilities: Capabilities{HardwareSummary: "test"},
		Skills:       []Skill{{Name: "uptime"}},
		Addresses:    []string{"10.0.0.1"},
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !resp.Success {
		t.Errorf("expected success=true")
	}
	if resp.Data.Peer.Handle != "instance-abc" {
		t.Errorf("unexpected handle: %q", resp.Data.Peer.Handle)
	}
	if !resp.Data.Created {
		t.Errorf("expected created=true")
	}
}

func TestAnnounce_RejectsLargeBody(t *testing.T) {
	fake := &fakeHTTPClient{status: 200, response: `{}`}
	r := New("https://platform.example.com", fake)

	huge := strings.Repeat("x", MaxAnnounceBodyBytes)
	_, err := r.Announce(context.Background(), AnnouncePayload{
		Capabilities: Capabilities{HardwareSummary: huge},
	})
	if err == nil {
		t.Fatalf("expected error for oversized body")
	}
	if !strings.Contains(err.Error(), "exceeds") {
		t.Errorf("unexpected error message: %v", err)
	}
}

func TestAnnounce_ThrottlesIdenticalReannounce(t *testing.T) {
	fake := &fakeHTTPClient{
		status:   200,
		response: `{"success":true,"data":{"peer":{"handle":"a","status":"active","trust_score":0.5},"created":false}}`,
	}
	r := New("https://platform.example.com", fake)

	payload := AnnouncePayload{Skills: []Skill{{Name: "x"}}}

	// First call succeeds
	if _, err := r.Announce(context.Background(), payload); err != nil {
		t.Fatalf("first announce failed: %v", err)
	}

	// Immediate re-announce with same payload should be throttled
	_, err := r.Announce(context.Background(), payload)
	if err == nil {
		t.Errorf("expected throttle error on immediate re-announce")
	}
	if fake.calls != 1 {
		t.Errorf("expected 1 HTTP call, got %d", fake.calls)
	}
}

func TestAnnounce_Reannounces_OnPayloadDelta(t *testing.T) {
	fake := &fakeHTTPClient{
		status:   200,
		response: `{"success":true,"data":{"peer":{"handle":"a","status":"active","trust_score":0.5},"created":false}}`,
	}
	r := New("https://platform.example.com", fake)

	// Different payloads should NOT throttle
	if _, err := r.Announce(context.Background(), AnnouncePayload{
		Skills: []Skill{{Name: "x"}},
	}); err != nil {
		t.Fatalf("first announce failed: %v", err)
	}

	if _, err := r.Announce(context.Background(), AnnouncePayload{
		Skills: []Skill{{Name: "y"}},
	}); err != nil {
		t.Fatalf("second announce (delta) failed: %v", err)
	}

	if fake.calls != 2 {
		t.Errorf("expected 2 HTTP calls, got %d", fake.calls)
	}
}

func TestAnnounce_Records_Failures(t *testing.T) {
	fake := &fakeHTTPClient{
		status:   503,
		response: `{"error":"unavailable"}`,
	}
	r := New("https://platform.example.com", fake)

	for i := 0; i < 3; i++ {
		// Each iteration uses a different payload so throttle doesn't kick in
		_, err := r.Announce(context.Background(), AnnouncePayload{
			Skills: []Skill{{Name: payloadKey(i)}},
		})
		if err == nil {
			t.Fatalf("iteration %d: expected error", i)
		}
	}

	if got := r.ConsecutiveErrors(); got != 3 {
		t.Errorf("expected 3 consecutive errors, got %d", got)
	}
}

func TestAnnounce_LastAnnounce_TracksRecency(t *testing.T) {
	fake := &fakeHTTPClient{
		status:   200,
		response: `{"success":true,"data":{"peer":{"handle":"a","status":"active","trust_score":0.5},"created":true}}`,
	}
	r := New("https://platform.example.com", fake)

	if !r.LastAnnounce().IsZero() {
		t.Errorf("expected zero LastAnnounce before any call")
	}

	before := time.Now()
	if _, err := r.Announce(context.Background(), AnnouncePayload{}); err != nil {
		t.Fatalf("announce failed: %v", err)
	}

	if r.LastAnnounce().Before(before) {
		t.Errorf("LastAnnounce should be at or after %v, got %v", before, r.LastAnnounce())
	}
}

func payloadKey(i int) string {
	return string(rune('a' + i))
}

// Sanity: AnnounceResponse JSON shape matches platform's render_success
// envelope.
func TestAnnounceResponse_Decodes(t *testing.T) {
	body := `{"success":true,"data":{"peer":{"id":"p","handle":"instance-deadbeef","status":"registered","enabled":false,"trust_score":0.5},"created":true}}`
	var ar AnnounceResponse
	if err := json.NewDecoder(strings.NewReader(body)).Decode(&ar); err != nil {
		t.Fatalf("decode failed: %v", err)
	}
	if ar.Data.Peer.Handle != "instance-deadbeef" {
		t.Errorf("unexpected handle: %q", ar.Data.Peer.Handle)
	}
	if ar.Data.Peer.TrustScore != 0.5 {
		t.Errorf("unexpected trust_score: %v", ar.Data.Peer.TrustScore)
	}
}
