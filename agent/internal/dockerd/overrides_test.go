package dockerd

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"reflect"
	"testing"

	"github.com/powernode/platform/extensions/system/agent/internal/transport"
)

func TestHTTPOverridesClient_FetchOverrides(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != OverridesPath {
			t.Fatalf("unexpected path %s", r.URL.Path)
		}
		if r.Method != http.MethodGet {
			t.Fatalf("unexpected method %s", r.Method)
		}
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(map[string]any{
			"success": true,
			"data": map[string]any{
				"runtime": "docker",
				"daemon_overrides": map[string]any{
					"registry-mirrors": []string{"https://mirror.gcr.io"},
					"log-driver":       "journald",
				},
				"content_hash": "sha256-abc123",
			},
		})
	}))
	defer srv.Close()

	c := NewHTTPOverridesClient(&transport.Client{Client: srv.Client(), PlatformURL: srv.URL})
	overrides, hash, err := c.FetchOverrides(context.Background())
	if err != nil {
		t.Fatalf("FetchOverrides: %v", err)
	}
	if hash != "sha256-abc123" {
		t.Fatalf("hash mismatch: got %q", hash)
	}
	if overrides["log-driver"] != "journald" {
		t.Fatalf("log-driver missing or wrong: got %v", overrides["log-driver"])
	}
	mirrors, ok := overrides["registry-mirrors"].([]any)
	if !ok || len(mirrors) != 1 || mirrors[0] != "https://mirror.gcr.io" {
		t.Fatalf("registry-mirrors missing or wrong: got %v", overrides["registry-mirrors"])
	}
}

func TestHTTPOverridesClient_EmptyOverridesMap(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(map[string]any{
			"success": true,
			"data": map[string]any{
				"runtime":          "docker",
				"daemon_overrides": map[string]any{},
				"content_hash":     "sha256-empty",
			},
		})
	}))
	defer srv.Close()

	c := NewHTTPOverridesClient(&transport.Client{Client: srv.Client(), PlatformURL: srv.URL})
	overrides, hash, err := c.FetchOverrides(context.Background())
	if err != nil {
		t.Fatalf("FetchOverrides: %v", err)
	}
	if hash != "sha256-empty" {
		t.Fatalf("hash mismatch: got %q", hash)
	}
	if !reflect.DeepEqual(overrides, map[string]any{}) {
		t.Fatalf("expected empty map, got %v", overrides)
	}
}

// 403 from platform = "module not assigned" — should be treated as
// "no overrides", not an error. Avoids reconcile noise during the
// narrow race between modules-list and overrides-fetch.
func TestHTTPOverridesClient_403IsEmpty(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusForbidden)
		_ = json.NewEncoder(w).Encode(map[string]any{
			"success": false,
			"error":   "module not assigned",
		})
	}))
	defer srv.Close()

	c := NewHTTPOverridesClient(&transport.Client{Client: srv.Client(), PlatformURL: srv.URL})
	overrides, hash, err := c.FetchOverrides(context.Background())
	if err != nil {
		t.Fatalf("expected no error on 403, got %v", err)
	}
	if hash != "" {
		t.Fatalf("expected empty hash on 403, got %q", hash)
	}
	if !reflect.DeepEqual(overrides, map[string]any{}) {
		t.Fatalf("expected empty map on 403, got %v", overrides)
	}
}

func TestHTTPOverridesClient_PropagatesNon403Error(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		_ = json.NewEncoder(w).Encode(map[string]any{
			"success": false,
			"error":   "internal server error",
		})
	}))
	defer srv.Close()

	c := NewHTTPOverridesClient(&transport.Client{Client: srv.Client(), PlatformURL: srv.URL})
	_, _, err := c.FetchOverrides(context.Background())
	if err == nil {
		t.Fatal("expected error on 500")
	}
}

func TestHTTPOverridesClient_RejectsNilTransport(t *testing.T) {
	c := &HTTPOverridesClient{transport: nil}
	if _, _, err := c.FetchOverrides(context.Background()); err == nil {
		t.Fatal("expected error on nil transport")
	}
}
