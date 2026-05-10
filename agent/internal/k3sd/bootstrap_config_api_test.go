package k3sd

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/transport"
)

// newTestTransport builds a transport.Client pointed at the given
// httptest server. Mirrors the pattern dockerd's overrides_test uses.
func newTestTransport(t *testing.T, srv *httptest.Server) *transport.Client {
	t.Helper()
	return &transport.Client{
		Client:        srv.Client(),
		PlatformURL:   srv.URL,
		InstanceToken: "test-token",
	}
}

func TestHTTPBootstrapConfigClient_HappyPath_OvnKubernetes(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != BootstrapConfigPath {
			t.Errorf("unexpected path %q, want %q", r.URL.Path, BootstrapConfigPath)
		}
		if got := r.Header.Get("Authorization"); got != "Bearer test-token" {
			t.Errorf("missing/incorrect Authorization header: %q", got)
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"success": true,
			"data": map[string]any{
				"runtime":          "k3s_server",
				"bootstrap_config": map[string]any{"cni_plugin": "ovn_kubernetes"},
				"content_hash":     "abc123",
			},
		})
	}))
	defer srv.Close()

	c := NewHTTPBootstrapConfigClient(newTestTransport(t, srv))
	cfg, hash, err := c.FetchBootstrapConfig(context.Background())
	if err != nil {
		t.Fatalf("fetch: %v", err)
	}
	if cfg.CniPlugin != CniPluginOvnKubernetes {
		t.Errorf("CniPlugin = %q, want %q", cfg.CniPlugin, CniPluginOvnKubernetes)
	}
	if hash != "abc123" {
		t.Errorf("content_hash = %q, want abc123", hash)
	}
}

func TestHTTPBootstrapConfigClient_HappyPath_FlannelDefault(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{
			"success": true,
			"data": map[string]any{
				"runtime":          "k3s_server",
				"bootstrap_config": map[string]any{"cni_plugin": "flannel"},
				"content_hash":     "def456",
			},
		})
	}))
	defer srv.Close()

	c := NewHTTPBootstrapConfigClient(newTestTransport(t, srv))
	cfg, hash, err := c.FetchBootstrapConfig(context.Background())
	if err != nil {
		t.Fatalf("fetch: %v", err)
	}
	if cfg.CniPlugin != CniPluginFlannel {
		t.Errorf("CniPlugin = %q, want %q", cfg.CniPlugin, CniPluginFlannel)
	}
	if hash != "def456" {
		t.Errorf("content_hash = %q, want def456", hash)
	}
}

func TestHTTPBootstrapConfigClient_ForbiddenIsTreatedAsEmpty(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusForbidden)
		fmt.Fprintln(w, `{"success": false, "error": "module not enabled"}`)
	}))
	defer srv.Close()

	c := NewHTTPBootstrapConfigClient(newTestTransport(t, srv))
	cfg, hash, err := c.FetchBootstrapConfig(context.Background())
	if err != nil {
		t.Fatalf("403 should return empty cfg without error, got: %v", err)
	}
	if cfg.CniPlugin != "" {
		t.Errorf("expected empty cfg on 403, got CniPlugin=%q", cfg.CniPlugin)
	}
	if hash != "" {
		t.Errorf("expected empty hash on 403, got %q", hash)
	}
}

func TestHTTPBootstrapConfigClient_ServerErrorReturnsError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		fmt.Fprintln(w, "internal error")
	}))
	defer srv.Close()

	c := NewHTTPBootstrapConfigClient(newTestTransport(t, srv))
	_, _, err := c.FetchBootstrapConfig(context.Background())
	if err == nil {
		t.Fatal("expected error on 500, got nil")
	}
	if !strings.Contains(err.Error(), "HTTP 500") {
		t.Errorf("error should mention HTTP 500, got: %v", err)
	}
}

func TestHTTPBootstrapConfigClient_PlatformFailureBubblesUp(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{
			"success": false,
			"error":   "boom",
		})
	}))
	defer srv.Close()

	c := NewHTTPBootstrapConfigClient(newTestTransport(t, srv))
	_, _, err := c.FetchBootstrapConfig(context.Background())
	if err == nil {
		t.Fatal("expected error when success=false, got nil")
	}
	if !strings.Contains(err.Error(), "boom") {
		t.Errorf("error should bubble platform message, got: %v", err)
	}
}

func TestHTTPBootstrapConfigClient_NilTransportRefuses(t *testing.T) {
	c := &HTTPBootstrapConfigClient{transport: nil}
	_, _, err := c.FetchBootstrapConfig(context.Background())
	if err == nil {
		t.Fatal("nil transport should error, got nil")
	}
}
