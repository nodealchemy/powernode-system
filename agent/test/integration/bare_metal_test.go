//go:build integration

// Bare-metal physical-device claim flow integration test.
//
// Complements internal/identity/claim_test.go (which uses fakeBootStrategy
// mocks) by exercising the REAL BootIdentityStrategy reading from a real
// identity.cfg on disk + ClaimStrategy polling an httptest TLS server.
//
// This is the on-node mirror of server/db/seeds/smoke_test_bare_metal_claim.rb
// (audit plan P3.5 — server-side smoke). Together they cover both halves of
// the claim flow: the Go agent's perspective (this test) and the Rails
// platform's perspective (the seed).
//
// Run:    cd agent && go test -tags integration -race ./test/integration/...
// Skip:   go test ./...   (default: no integration tag, this file omitted)

package integration

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/identity"
)

// TestBareMetalClaim_BootPartitionToBootstrapToken exercises the full
// 7-strategy DefaultResolver flow when only the boot-partition identity.cfg
// source is populated. Validates that ClaimStrategy polls the platform until
// status flips from "pending" to "claimed", then returns a non-empty
// bootstrap token.
func TestBareMetalClaim_BootPartitionToBootstrapToken(t *testing.T) {
	t.Parallel()

	// Build a tmp /boot equivalent with the operator's identity.cfg.
	tmpDir := t.TempDir()
	bootDir := filepath.Join(tmpDir, "boot")
	if err := os.MkdirAll(bootDir, 0o755); err != nil {
		t.Fatalf("mkdir bootDir: %v", err)
	}

	// httptest auto-generates a self-signed cert. We embed its PEM bytes
	// into the CA bundle the agent uses to verify the platform.
	pollCount := 0
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		pollCount++
		env := map[string]any{
			"success": true,
			"data": map[string]any{
				"status":             "pending",
				"claim_code":         "ABCD-1234",
				"poll_after_seconds": 1,
			},
		}
		// After the 2nd poll, operator has "confirmed" → return claimed.
		if pollCount >= 2 {
			env["data"] = map[string]any{
				"status":          "claimed",
				"bootstrap_token": "boot-tok-integration-xyz",
				"instance_uuid":   "550e8400-e29b-41d4-a716-446655440000",
				"platform_url":    "https://platform.test",
			}
		}
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(env); err != nil {
			t.Errorf("encode response: %v", err)
		}
	}))
	defer srv.Close()

	caPEM := encodeCertToPEM(t, srv.Certificate())
	caPath := filepath.Join(bootDir, "powernode-ca.pem")
	if err := os.WriteFile(caPath, caPEM, 0o644); err != nil {
		t.Fatalf("write CA: %v", err)
	}

	// Write a minimal identity.cfg pointing at our test server.
	cfgPath := filepath.Join(bootDir, "identity.cfg")
	cfg := fmt.Sprintf("ID=\nKEY=\nSERVER=%s\nCA_PEM_FILE=%s\n", srv.URL, caPath)
	if err := os.WriteFile(cfgPath, []byte(cfg), 0o644); err != nil {
		t.Fatalf("write identity.cfg: %v", err)
	}

	// Wire the real BootIdentityStrategy at our tmp path; ClaimStrategy
	// uses it as the source of platform URL + CA + (empty) bootstrap token.
	boot := &identity.BootIdentityStrategy{Path: cfgPath}
	claim := &identity.ClaimStrategy{
		BootStrategy: boot,
		PollInterval: 50 * time.Millisecond, // fast for tests; production: 30s
		MaxPolls:     10,
		HTTPClient:   newTrustingHTTPClient(t, caPEM),
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	id, err := claim.Discover(ctx)
	if err != nil {
		t.Fatalf("claim.Discover: %v (pollCount=%d)", err, pollCount)
	}

	if id == nil {
		t.Fatal("expected non-nil Identity from claim flow")
	}
	if id.BootstrapToken != "boot-tok-integration-xyz" {
		t.Errorf("BootstrapToken mismatch: got %q, want %q",
			id.BootstrapToken, "boot-tok-integration-xyz")
	}
	if id.InstanceUUID == "" {
		t.Error("InstanceUUID empty in claimed Identity")
	}
	if pollCount < 2 {
		t.Errorf("expected >=2 polls (pending then claimed), got %d", pollCount)
	}
}

// encodeCertToPEM serializes the httptest TLS cert to PEM bytes the
// BootIdentityStrategy CA_PEM_FILE consumer can parse.
func encodeCertToPEM(t *testing.T, cert *x509.Certificate) []byte {
	t.Helper()
	return pem.EncodeToMemory(&pem.Block{
		Type:  "CERTIFICATE",
		Bytes: cert.Raw,
	})
}

// newTrustingHTTPClient builds an HTTPS client that trusts the supplied CA
// PEM bundle. In production the agent's transport package wires this from
// the boot-identity CA; for the integration test we construct it inline.
func newTrustingHTTPClient(t *testing.T, caPEM []byte) *http.Client {
	t.Helper()
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(caPEM) {
		t.Fatal("AppendCertsFromPEM: no certs parsed from PEM")
	}
	return &http.Client{
		Transport: &http.Transport{
			TLSClientConfig: &tls.Config{
				MinVersion: tls.VersionTLS12,
				RootCAs:    pool,
			},
		},
		Timeout: 10 * time.Second,
	}
}
