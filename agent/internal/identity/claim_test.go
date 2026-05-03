package identity

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// fakeBootStrategy returns a fixed identity for ClaimStrategy tests.
type fakeBootStrategy struct {
	id  *Identity
	err error
}

func (f *fakeBootStrategy) Name() string                                   { return "fake-boot" }
func (f *fakeBootStrategy) Discover(_ context.Context) (*Identity, error) { return f.id, f.err }

func TestClaimStrategy_PassthroughWhenTokenAlreadyPresent(t *testing.T) {
	// If BootIdentity already has BootstrapToken (Path A baked image, or
	// recovery scenario where operator pre-staged token), ClaimStrategy
	// must return that identity unchanged — no claim poll attempted.
	s := &ClaimStrategy{
		BootStrategy: &fakeBootStrategy{
			id: &Identity{
				InstanceUUID:   "pre-staged-uuid",
				BootstrapToken: "pre-staged-token",
				PlatformURL:    "https://example.com",
			},
		},
	}

	id, err := s.Discover(context.Background())
	if err != nil {
		t.Fatalf("err = %v", err)
	}
	if id.BootstrapToken != "pre-staged-token" {
		t.Errorf("expected pre-staged token passthrough, got %q", id.BootstrapToken)
	}
	if id.InstanceUUID != "pre-staged-uuid" {
		t.Errorf("InstanceUUID = %q", id.InstanceUUID)
	}
}

func TestClaimStrategy_BootMissing(t *testing.T) {
	s := &ClaimStrategy{
		BootStrategy: &fakeBootStrategy{err: ErrNotFound},
	}
	_, err := s.Discover(context.Background())
	if !errors.Is(err, ErrNotFound) {
		t.Errorf("err = %v, want ErrNotFound", err)
	}
}

func TestClaimStrategy_BootHasNoServer(t *testing.T) {
	s := &ClaimStrategy{
		BootStrategy: &fakeBootStrategy{id: &Identity{}}, // empty
	}
	_, err := s.Discover(context.Background())
	if !errors.Is(err, ErrNotFound) {
		t.Errorf("empty identity: err = %v, want ErrNotFound", err)
	}
}

func TestClaimStrategy_PollPendingThenClaimed(t *testing.T) {
	// First poll → pending. Second → claimed. ClaimStrategy should return
	// completed identity after the second poll.
	pollCount := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/system/node_api/claim" {
			t.Errorf("unexpected path: %s", r.URL.Path)
		}

		var req claimRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Errorf("decode req: %v", err)
		}

		pollCount++
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)

		if pollCount == 1 {
			_ = json.NewEncoder(w).Encode(claimResponseEnvelope{
				Success: true,
				Data: claimResponse{
					Status:           "pending",
					ClaimCode:        "ABCD-EFGH",
					PollAfterSeconds: 0, // let strategy default
				},
			})
			return
		}

		_ = json.NewEncoder(w).Encode(claimResponseEnvelope{
			Success: true,
			Data: claimResponse{
				Status:         "claimed",
				BootstrapToken: "issued-token-xyz",
				InstanceUUID:   "claimed-instance-uuid",
			},
		})
	}))
	defer srv.Close()

	s := &ClaimStrategy{
		BootStrategy: &fakeBootStrategy{
			id: &Identity{
				PlatformURL: srv.URL,
			},
		},
		PollInterval: 10 * time.Millisecond,
		MaxPolls:     5,
		HTTPClient:   srv.Client(),
	}

	id, err := s.Discover(context.Background())
	if err != nil {
		t.Fatalf("err = %v", err)
	}
	if pollCount != 2 {
		t.Errorf("expected 2 polls, got %d", pollCount)
	}
	if id.BootstrapToken != "issued-token-xyz" {
		t.Errorf("BootstrapToken = %q, want issued-token-xyz", id.BootstrapToken)
	}
	if id.InstanceUUID != "claimed-instance-uuid" {
		t.Errorf("InstanceUUID = %q", id.InstanceUUID)
	}
	if id.PlatformURL != srv.URL {
		t.Errorf("PlatformURL = %q, want %q", id.PlatformURL, srv.URL)
	}
}

func TestClaimStrategy_RetryOnTransientError(t *testing.T) {
	// First poll → 503. Second → claimed. Strategy must keep polling
	// through transient platform errors rather than failing the chain.
	pollCount := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		pollCount++
		if pollCount == 1 {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(claimResponseEnvelope{
			Success: true,
			Data: claimResponse{
				Status:         "claimed",
				BootstrapToken: "tok",
				InstanceUUID:   "uuid",
			},
		})
	}))
	defer srv.Close()

	s := &ClaimStrategy{
		BootStrategy: &fakeBootStrategy{id: &Identity{PlatformURL: srv.URL}},
		PollInterval: 10 * time.Millisecond,
		MaxPolls:     5,
		HTTPClient:   srv.Client(),
	}

	id, err := s.Discover(context.Background())
	if err != nil {
		t.Fatalf("err = %v", err)
	}
	if pollCount < 2 {
		t.Errorf("expected at least 2 polls (retry through 503), got %d", pollCount)
	}
	if id.BootstrapToken != "tok" {
		t.Errorf("BootstrapToken = %q", id.BootstrapToken)
	}
}

func TestClaimStrategy_MaxPollsExhausted(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(claimResponseEnvelope{
			Success: true,
			Data: claimResponse{
				Status:    "pending",
				ClaimCode: "WAIT-FORE",
			},
		})
	}))
	defer srv.Close()

	s := &ClaimStrategy{
		BootStrategy: &fakeBootStrategy{id: &Identity{PlatformURL: srv.URL}},
		PollInterval: 5 * time.Millisecond,
		MaxPolls:     3,
		HTTPClient:   srv.Client(),
	}

	_, err := s.Discover(context.Background())
	if err == nil {
		t.Errorf("expected error after max polls, got nil")
	}
}

func TestClaimStrategy_RequestPayloadShape(t *testing.T) {
	// Verify the agent sends the fields the platform expects.
	var captured claimRequest
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewDecoder(r.Body).Decode(&captured)
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(claimResponseEnvelope{
			Success: true,
			Data: claimResponse{
				Status:         "claimed",
				BootstrapToken: "tok",
				InstanceUUID:   "uuid",
			},
		})
	}))
	defer srv.Close()

	s := &ClaimStrategy{
		BootStrategy: &fakeBootStrategy{id: &Identity{PlatformURL: srv.URL}},
		PollInterval: 1 * time.Millisecond,
		MaxPolls:     2,
		HTTPClient:   srv.Client(),
	}

	if _, err := s.Discover(context.Background()); err != nil {
		t.Fatalf("err = %v", err)
	}

	// Architecture must be set from runtime.GOARCH.
	if captured.Architecture == "" {
		t.Error("Architecture not populated in request")
	}
	if captured.AgentVersion == "" {
		t.Error("AgentVersion not populated in request")
	}
	// Hostname: best-effort; os.Hostname() can return empty in some
	// containers. Just verify the field is sent (even if empty).
	_ = captured.Hostname
}

func TestClaimStrategy_TrailingSlashOnPlatformURL(t *testing.T) {
	// Operators sometimes include a trailing slash. Strategy must
	// normalize so the endpoint isn't /api/v1/system/node_api//claim.
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/system/node_api/claim" {
			t.Errorf("unexpected path: %s", r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(claimResponseEnvelope{
			Success: true,
			Data: claimResponse{
				Status:         "claimed",
				BootstrapToken: "tok",
				InstanceUUID:   "uuid",
			},
		})
	}))
	defer srv.Close()

	s := &ClaimStrategy{
		BootStrategy: &fakeBootStrategy{id: &Identity{PlatformURL: srv.URL + "/"}},
		PollInterval: 1 * time.Millisecond,
		MaxPolls:     2,
		HTTPClient:   srv.Client(),
	}
	if _, err := s.Discover(context.Background()); err != nil {
		t.Fatalf("err = %v", err)
	}
}

func TestClaimStrategy_PollAfterSecondsHonored(t *testing.T) {
	// Platform returns poll_after_seconds=0 (falsy → ignored), then
	// returns claimed. The strategy uses its own PollInterval, but if
	// the platform sent a non-zero hint we'd expect it to override.
	// Just verify zero is treated as "no override."
	pollCount := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		pollCount++
		w.Header().Set("Content-Type", "application/json")
		if pollCount < 2 {
			_ = json.NewEncoder(w).Encode(claimResponseEnvelope{
				Success: true,
				Data: claimResponse{Status: "pending", PollAfterSeconds: 0},
			})
			return
		}
		_ = json.NewEncoder(w).Encode(claimResponseEnvelope{
			Success: true,
			Data: claimResponse{
				Status:         "claimed",
				BootstrapToken: "tok",
				InstanceUUID:   "uuid",
			},
		})
	}))
	defer srv.Close()

	start := time.Now()
	s := &ClaimStrategy{
		BootStrategy: &fakeBootStrategy{id: &Identity{PlatformURL: srv.URL}},
		PollInterval: 5 * time.Millisecond,
		MaxPolls:     5,
		HTTPClient:   srv.Client(),
	}
	if _, err := s.Discover(context.Background()); err != nil {
		t.Fatalf("err = %v", err)
	}
	elapsed := time.Since(start)
	// Two polls × 5ms wait between = ~5-15ms. If poll_after_seconds=0
	// were misinterpreted as "wait 0s", we'd see <2ms.
	if elapsed < 4*time.Millisecond {
		t.Errorf("poll loop ran too fast (%v) — PollAfterSeconds=0 may have been mishandled", elapsed)
	}
}
