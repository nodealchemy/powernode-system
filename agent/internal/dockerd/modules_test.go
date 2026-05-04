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

func TestHTTPModulesClient_AssignedModules(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != ModulesPath {
			t.Fatalf("unexpected path %s", r.URL.Path)
		}
		if r.Method != http.MethodGet {
			t.Fatalf("unexpected method %s", r.Method)
		}
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(map[string]any{
			"success": true,
			"data": map[string]any{
				"modules": []map[string]any{
					{"name": "system-base", "id": "m-1"},
					{"name": "sdwan-overlay", "id": "m-2"},
					{"name": "docker-engine", "id": "m-3"},
				},
				"count": 3,
			},
		})
	}))
	defer srv.Close()

	c := NewHTTPModulesClient(&transport.Client{Client: srv.Client(), PlatformURL: srv.URL})
	got, err := c.AssignedModules(context.Background())
	if err != nil {
		t.Fatalf("AssignedModules: %v", err)
	}
	want := []string{"system-base", "sdwan-overlay", "docker-engine"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}

func TestHTTPModulesClient_PropagatesPlatformError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_ = json.NewEncoder(w).Encode(map[string]any{
			"success": false,
			"error":   "instance token expired",
		})
	}))
	defer srv.Close()

	c := NewHTTPModulesClient(&transport.Client{Client: srv.Client(), PlatformURL: srv.URL})
	_, err := c.AssignedModules(context.Background())
	if err == nil {
		t.Fatal("expected error on 401")
	}
}

func TestHTTPModulesClient_RejectsNilTransport(t *testing.T) {
	c := &HTTPModulesClient{transport: nil}
	if _, err := c.AssignedModules(context.Background()); err == nil {
		t.Fatal("expected error on nil transport")
	}
}

func TestHTTPModulesClient_SkipsEmptyNames(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(map[string]any{
			"success": true,
			"data": map[string]any{
				"modules": []map[string]any{
					{"name": "docker-engine"},
					{"name": ""},
					{"name": "system-base"},
				},
			},
		})
	}))
	defer srv.Close()

	c := NewHTTPModulesClient(&transport.Client{Client: srv.Client(), PlatformURL: srv.URL})
	got, err := c.AssignedModules(context.Background())
	if err != nil {
		t.Fatalf("AssignedModules: %v", err)
	}
	want := []string{"docker-engine", "system-base"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}
