package k3sd

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/nodealchemy/powernode-system/agent/internal/transport"
)

func newK3sTestClient(t *testing.T, handler http.HandlerFunc) (*Client, *httptest.Server) {
	t.Helper()
	srv := httptest.NewServer(handler)
	tc := &transport.Client{Client: srv.Client(), PlatformURL: srv.URL, InstanceID: "i-test"}
	return NewClient(tc), srv
}

func TestBootstrap_HappyPath(t *testing.T) {
	c, srv := newK3sTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != HandshakePath {
			t.Fatalf("unexpected path %s", r.URL.Path)
		}
		body, _ := io.ReadAll(r.Body)
		var req HandshakeRequest
		if err := json.Unmarshal(body, &req); err != nil {
			t.Fatalf("unmarshal: %v", err)
		}
		if req.Runtime != RuntimeK3sServer || req.Phase != PhaseBootstrap {
			t.Fatalf("envelope: %+v", req)
		}
		if req.Kubeconfig == "" || req.ServerToken == "" {
			t.Fatalf("expected kubeconfig + server_token, got %+v", req)
		}
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(map[string]any{
			"success": true,
			"data": map[string]any{
				"cluster_id":     "cluster-abc",
				"cluster_status": "bootstrapping",
				"api_endpoint":   "https://[fd00::1]:6443",
			},
		})
	})
	defer srv.Close()

	ack, err := c.Bootstrap(context.Background(),
		"fake-kubeconfig", "K10server-token", "K10agent-token", "v1.30.4+k3s1")
	if err != nil {
		t.Fatalf("Bootstrap: %v", err)
	}
	if ack.ClusterID != "cluster-abc" {
		t.Fatalf("cluster_id: got %q", ack.ClusterID)
	}
	if ack.ClusterStatus != "bootstrapping" {
		t.Fatalf("cluster_status: got %q", ack.ClusterStatus)
	}
	if ack.APIEndpoint != "https://[fd00::1]:6443" {
		t.Fatalf("api_endpoint: got %q", ack.APIEndpoint)
	}
}

func TestBootstrap_RejectsMissingKubeconfig(t *testing.T) {
	c, srv := newK3sTestClient(t, func(http.ResponseWriter, *http.Request) {
		t.Fatal("server should not be hit for missing kubeconfig")
	})
	defer srv.Close()
	if _, err := c.Bootstrap(context.Background(), "", "tok", "agent", "v1"); err == nil {
		t.Fatal("expected error for empty kubeconfig")
	}
}

func TestBootstrap_RejectsMissingServerToken(t *testing.T) {
	c, srv := newK3sTestClient(t, func(http.ResponseWriter, *http.Request) {
		t.Fatal("server should not be hit for missing token")
	})
	defer srv.Close()
	if _, err := c.Bootstrap(context.Background(), "kc", "", "agent", "v1"); err == nil {
		t.Fatal("expected error for empty server_token")
	}
}

func TestJoinRequest_HappyPath(t *testing.T) {
	c, srv := newK3sTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		var req HandshakeRequest
		_ = json.Unmarshal(body, &req)
		if req.Runtime != RuntimeK3sAgent || req.Phase != PhaseJoinRequest {
			t.Fatalf("envelope: %+v", req)
		}
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(map[string]any{
			"success": true,
			"data": map[string]any{
				"cluster_id":   "cluster-xyz",
				"api_endpoint": "https://[fd00::1]:6443",
				"agent_token":  "K10agent-tok",
			},
		})
	})
	defer srv.Close()

	payload, err := c.JoinRequest(context.Background(), "")
	if err != nil {
		t.Fatalf("JoinRequest: %v", err)
	}
	if payload.AgentToken != "K10agent-tok" {
		t.Fatalf("agent_token: got %q", payload.AgentToken)
	}
	if payload.APIEndpoint != "https://[fd00::1]:6443" {
		t.Fatalf("api_endpoint: got %q", payload.APIEndpoint)
	}
}

func TestJoinRequest_NoCluster_PropagatesError(t *testing.T) {
	c, srv := newK3sTestClient(t, func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusUnprocessableEntity)
		_ = json.NewEncoder(w).Encode(map[string]any{
			"success": false,
			"error":   "no Kubernetes cluster available in account 0193 — bootstrap a k3s-server first",
		})
	})
	defer srv.Close()

	_, err := c.JoinRequest(context.Background(), "")
	if err == nil {
		t.Fatal("expected error on 422")
	}
	var hsErr *HandshakeError
	if !errors.As(err, &hsErr) {
		t.Fatalf("expected *HandshakeError, got %T", err)
	}
	if hsErr.Status != http.StatusUnprocessableEntity {
		t.Fatalf("status: got %d", hsErr.Status)
	}
	if !strings.Contains(hsErr.Body, "no Kubernetes cluster") {
		t.Fatalf("expected error body to contain 'no Kubernetes cluster', got %q", hsErr.Body)
	}
}

func TestReportReady_Server(t *testing.T) {
	c, srv := newK3sTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		var req HandshakeRequest
		_ = json.Unmarshal(body, &req)
		if req.Runtime != RuntimeK3sServer || req.Phase != PhaseReady {
			t.Fatalf("envelope: %+v", req)
		}
		if req.Role != RoleServer || req.Version != "v1.30.4+k3s1" {
			t.Fatalf("expected role=server + version, got %+v", req)
		}
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(map[string]any{
			"success": true,
			"data": map[string]any{
				"node_id":     "node-1",
				"cluster_id":  "cluster-abc",
				"node_status": "active",
				"role":        "server",
			},
		})
	})
	defer srv.Close()

	ack, err := c.ReportReady(context.Background(), RuntimeK3sServer, RoleServer, "v1.30.4+k3s1")
	if err != nil {
		t.Fatalf("ReportReady: %v", err)
	}
	if ack.NodeStatus != "active" {
		t.Fatalf("status: got %q", ack.NodeStatus)
	}
	if ack.Role != RoleServer {
		t.Fatalf("role: got %q", ack.Role)
	}
}

func TestReportReady_Agent(t *testing.T) {
	c, srv := newK3sTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		var req HandshakeRequest
		_ = json.Unmarshal(body, &req)
		if req.Runtime != RuntimeK3sAgent || req.Role != RoleAgent {
			t.Fatalf("expected k3s_agent + role=agent, got %+v", req)
		}
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(map[string]any{
			"success": true,
			"data": map[string]any{
				"node_id": "node-2", "cluster_id": "cluster-abc",
				"node_status": "active", "role": "agent",
			},
		})
	})
	defer srv.Close()

	ack, err := c.ReportReady(context.Background(), RuntimeK3sAgent, RoleAgent, "v1.30.4+k3s1")
	if err != nil {
		t.Fatalf("ReportReady: %v", err)
	}
	if ack.Role != RoleAgent {
		t.Fatalf("role: got %q", ack.Role)
	}
}

func TestReportStopped(t *testing.T) {
	c, srv := newK3sTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		var req HandshakeRequest
		_ = json.Unmarshal(body, &req)
		if req.Phase != PhaseStopped {
			t.Fatalf("expected stopped, got %s", req.Phase)
		}
		// omitempty: optional fields should be empty on stopped
		if req.Kubeconfig != "" || req.ServerToken != "" || req.Version != "" {
			t.Fatalf("expected omitempty fields blank, got %+v", req)
		}
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(map[string]any{
			"success": true,
			"data": map[string]any{
				"acknowledged": true, "node_id": "node-1",
			},
		})
	})
	defer srv.Close()

	ack, err := c.ReportStopped(context.Background(), RuntimeK3sServer)
	if err != nil {
		t.Fatalf("ReportStopped: %v", err)
	}
	if !ack.Acknowledged {
		t.Fatal("expected acknowledged=true")
	}
}

func TestHandshake_RejectsNilTransport(t *testing.T) {
	c := &Client{transport: nil}
	if _, err := c.Bootstrap(context.Background(), "kc", "tok", "agent", "v1"); err == nil {
		t.Fatal("expected error for nil transport")
	}
}
