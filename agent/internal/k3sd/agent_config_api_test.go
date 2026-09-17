package k3sd

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestHTTPAgentConfigClient_HappyPath_ReturnsTargetClusterID(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != AgentConfigPath {
			t.Errorf("unexpected path %q, want %q", r.URL.Path, AgentConfigPath)
		}
		if got := r.Header.Get("Authorization"); got != "" {
			t.Errorf("unexpected Authorization header %q (auth is mTLS only)", got)
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"success": true,
			"data": map[string]any{
				"runtime":           "k3s_agent",
				"target_cluster_id": "cluster-abc-123",
				"content_hash":      "hash1",
			},
		})
	}))
	defer srv.Close()

	c := NewHTTPAgentConfigClient(newTestTransport(t, srv))
	targetClusterID, err := c.FetchAgentConfig(context.Background())
	if err != nil {
		t.Fatalf("fetch: %v", err)
	}
	if targetClusterID != "cluster-abc-123" {
		t.Errorf("target_cluster_id = %q, want %q", targetClusterID, "cluster-abc-123")
	}
}

func TestHTTPAgentConfigClient_HappyPath_EmptyWhenNoOperatorTarget(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{
			"success": true,
			"data": map[string]any{
				"runtime":           "k3s_agent",
				"target_cluster_id": "",
				"content_hash":      "hash2",
			},
		})
	}))
	defer srv.Close()

	c := NewHTTPAgentConfigClient(newTestTransport(t, srv))
	targetClusterID, err := c.FetchAgentConfig(context.Background())
	if err != nil {
		t.Fatalf("fetch: %v", err)
	}
	if targetClusterID != "" {
		t.Errorf("target_cluster_id = %q, want empty", targetClusterID)
	}
}

func TestHTTPAgentConfigClient_ForbiddenIsTreatedAsEmpty(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusForbidden)
		fmt.Fprintln(w, `{"success": false, "error": "module not enabled"}`)
	}))
	defer srv.Close()

	c := NewHTTPAgentConfigClient(newTestTransport(t, srv))
	targetClusterID, err := c.FetchAgentConfig(context.Background())
	if err != nil {
		t.Fatalf("403 should return empty without error, got: %v", err)
	}
	if targetClusterID != "" {
		t.Errorf("expected empty on 403, got %q", targetClusterID)
	}
}

func TestHTTPAgentConfigClient_ServerErrorReturnsError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		fmt.Fprintln(w, "internal error")
	}))
	defer srv.Close()

	c := NewHTTPAgentConfigClient(newTestTransport(t, srv))
	_, err := c.FetchAgentConfig(context.Background())
	if err == nil {
		t.Fatal("expected error on 500, got nil")
	}
	if !strings.Contains(err.Error(), "HTTP 500") {
		t.Errorf("error should mention HTTP 500, got: %v", err)
	}
}

func TestHTTPAgentConfigClient_PlatformFailureBubblesUp(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{
			"success": false,
			"error":   "boom",
		})
	}))
	defer srv.Close()

	c := NewHTTPAgentConfigClient(newTestTransport(t, srv))
	_, err := c.FetchAgentConfig(context.Background())
	if err == nil {
		t.Fatal("expected error when success=false, got nil")
	}
	if !strings.Contains(err.Error(), "boom") {
		t.Errorf("error should bubble platform message, got: %v", err)
	}
}

func TestHTTPAgentConfigClient_NilTransportRefuses(t *testing.T) {
	c := &HTTPAgentConfigClient{transport: nil}
	_, err := c.FetchAgentConfig(context.Background())
	if err == nil {
		t.Fatal("nil transport should error, got nil")
	}
}
