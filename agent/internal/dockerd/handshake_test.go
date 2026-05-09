package dockerd

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/transport"
)

// All three phase tests stand up a real httptest server returning the
// platform's render_success envelope shape. This keeps the test honest
// about wire compatibility without depending on a running Rails app.

func newTestClient(t *testing.T, handler http.HandlerFunc) (*Client, *httptest.Server) {
	t.Helper()
	srv := httptest.NewServer(handler)
	tc := &transport.Client{Client: srv.Client(), PlatformURL: srv.URL, InstanceID: "i-test"}
	return NewClient(tc), srv
}

func TestRequestServerCert_HappyPath(t *testing.T) {
	wantInstanceID := "0193cdef-1234-7000-aaaa-bbbbbbbbbbbb"
	c, srv := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != HandshakePath {
			t.Fatalf("unexpected path %s", r.URL.Path)
		}
		if r.Method != http.MethodPost {
			t.Fatalf("unexpected method %s", r.Method)
		}
		body, _ := io.ReadAll(r.Body)
		var req HandshakeRequest
		if err := json.Unmarshal(body, &req); err != nil {
			t.Fatalf("unmarshal req: %v", err)
		}
		if req.Runtime != RuntimeDocker || req.Phase != PhaseWantsCert {
			t.Fatalf("unexpected request envelope: %+v", req)
		}
		if !strings.Contains(req.CSRPEM, "BEGIN CERTIFICATE REQUEST") {
			t.Fatalf("expected CSR PEM in request body, got %q", req.CSRPEM)
		}

		// Mirror render_success(certificate: {...}) shape.
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(map[string]any{
			"success": true,
			"data": map[string]any{
				"certificate": map[string]any{
					"cert_pem":     "-----BEGIN CERTIFICATE-----\nfake-leaf\n-----END CERTIFICATE-----\n",
					"ca_chain_pem": "-----BEGIN CERTIFICATE-----\nfake-ca\n-----END CERTIFICATE-----\n",
					"serial":       "DEADBEEF",
					"not_after":    "2026-08-04T18:00:00Z",
				},
			},
		})
	})
	defer srv.Close()

	kp, signed, err := c.RequestServerCert(context.Background(), wantInstanceID)
	if err != nil {
		t.Fatalf("RequestServerCert: %v", err)
	}
	if kp == nil || kp.Private == nil {
		t.Fatalf("expected keypair returned with non-nil private")
	}
	if !strings.Contains(signed.CertPEM, "fake-leaf") {
		t.Fatalf("expected fake-leaf in cert: %q", signed.CertPEM)
	}
	if signed.Serial != "DEADBEEF" {
		t.Fatalf("expected serial DEADBEEF, got %q", signed.Serial)
	}
	wantNA, _ := time.Parse(time.RFC3339, "2026-08-04T18:00:00Z")
	if !signed.NotAfter.Equal(wantNA) {
		t.Fatalf("NotAfter parse failed: %v vs %v", signed.NotAfter, wantNA)
	}
}

func TestRequestServerCert_RejectsEmptyInstanceID(t *testing.T) {
	c, srv := newTestClient(t, func(http.ResponseWriter, *http.Request) {
		t.Fatal("server should not be hit with empty instance id")
	})
	defer srv.Close()

	if _, _, err := c.RequestServerCert(context.Background(), ""); err == nil {
		t.Fatal("expected error for empty nodeInstanceID")
	}
}

func TestRequestServerCert_PropagatesPlatformError(t *testing.T) {
	c, srv := newTestClient(t, func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusForbidden)
		_ = json.NewEncoder(w).Encode(map[string]any{
			"success": false,
			"error":   "module 'docker-engine' not enabled for this node",
		})
	})
	defer srv.Close()

	_, _, err := c.RequestServerCert(context.Background(), "i-aaa")
	if err == nil {
		t.Fatal("expected error on 403")
	}
	var hsErr *HandshakeError
	if !errors.As(err, &hsErr) {
		t.Fatalf("expected *HandshakeError, got %T", err)
	}
	if hsErr.Status != http.StatusForbidden {
		t.Fatalf("status: got %d want 403", hsErr.Status)
	}
	if !strings.Contains(hsErr.Body, "not enabled") {
		t.Fatalf("expected platform error message in Body, got %q", hsErr.Body)
	}
	if hsErr.Phase != PhaseWantsCert {
		t.Fatalf("phase: got %s want wants_cert", hsErr.Phase)
	}
}

func TestReportReady_HappyPath(t *testing.T) {
	c, srv := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		var req HandshakeRequest
		_ = json.Unmarshal(body, &req)
		if req.Phase != PhaseReady || req.Version != "25.0.3" {
			t.Fatalf("unexpected request: %+v", req)
		}
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(map[string]any{
			"success": true,
			"data": map[string]any{
				"host_id":      "h-abc",
				"host_status":  "connected",
				"api_endpoint": "tcp://[fd00::1]:2376",
			},
		})
	})
	defer srv.Close()

	ack, err := c.ReportReady(context.Background(), "25.0.3", "tcp://[fd00::1]:2376")
	if err != nil {
		t.Fatalf("ReportReady: %v", err)
	}
	if ack.HostID != "h-abc" || ack.HostStatus != "connected" {
		t.Fatalf("unexpected ack: %+v", ack)
	}
}

func TestReportStopped_HappyPath(t *testing.T) {
	c, srv := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		var req HandshakeRequest
		_ = json.Unmarshal(body, &req)
		if req.Phase != PhaseStopped {
			t.Fatalf("expected stopped phase, got %s", req.Phase)
		}
		// Make sure transient fields aren't sent on stopped (omitempty).
		if req.CSRPEM != "" || req.Version != "" {
			t.Fatalf("expected empty optional fields on stopped: %+v", req)
		}
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(map[string]any{
			"success": true,
			"data": map[string]any{
				"acknowledged": true,
				"host_id":      "h-xyz",
			},
		})
	})
	defer srv.Close()

	ack, err := c.ReportStopped(context.Background())
	if err != nil {
		t.Fatalf("ReportStopped: %v", err)
	}
	if !ack.Acknowledged || ack.HostID != "h-xyz" {
		t.Fatalf("unexpected ack: %+v", ack)
	}
}

func TestHandshake_RejectsNilTransport(t *testing.T) {
	c := &Client{transport: nil}
	if _, _, err := c.RequestServerCert(context.Background(), "i-aaa"); err == nil {
		t.Fatal("expected error for nil transport")
	}
}
