package runtime

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/enroll"
	"github.com/nodealchemy/powernode-system/agent/internal/transport"
)

// countingCloser records CloseIdleConnections calls. http.Client delegates that
// call to its Transport, so a RoundTripper implementing it is enough to observe
// whether a displaced pool was retired.
type countingCloser struct {
	inner  http.RoundTripper
	closes atomic.Int32
}

// Must really serve requests: rotate() POSTs the CSR through the SAME client it
// later displaces, so a tracker that refuses requests would fail the rotation
// before there is anything to displace.
func (c *countingCloser) RoundTrip(req *http.Request) (*http.Response, error) {
	return c.inner.RoundTrip(req)
}

func (c *countingCloser) CloseIdleConnections() { c.closes.Add(1) }

// rotationServer returns a stub platform that answers /enroll/refresh with a
// freshly minted cert, plus the notBefore of the ON-DISK cert it expects.
func rotationServer(t *testing.T) (*httptest.Server, enroll.PKIPaths, time.Time) {
	t.Helper()
	dir := t.TempDir()
	notBefore := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	notAfter := notBefore.Add(10 * 24 * time.Hour)
	paths := writePKIFiles(t, dir, "subj", notBefore, notAfter)

	newNotBefore := notBefore.Add(8 * 24 * time.Hour)
	newNotAfter := newNotBefore.Add(10 * 24 * time.Hour)
	newCertPEM, _ := mintCert(t, "subj", newNotBefore, newNotAfter)

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"success": true,
			"data": map[string]any{
				"cert_pem":       string(newCertPEM),
				"ca_chain_pem":   string(newCertPEM),
				"instance_id":    "test-instance",
				"mtls_subject":   "subj",
				"not_after":      newNotAfter.Format(time.RFC3339),
				"certificate_id": "cert-2",
			},
		})
	}))
	t.Cleanup(srv.Close)
	return srv, paths, notBefore
}

// Rotating the cert must RETIRE the displaced connection pool, not merely swap
// the pointer. Connections in the old pool completed their handshake with the
// PREVIOUS certificate and keep presenting it while reused — and after the swap
// nothing else holds that client, so nothing would ever close them. kubernetes
// client-go closes all connections on cert rotation for the same reason.
func TestRotateClosesDisplacedConnectionPool(t *testing.T) {
	srv, paths, notBefore := rotationServer(t)

	built := &transport.Client{Client: srv.Client(), PlatformURL: srv.URL + "/rotated"}
	swap := transport.NewSwappableClient(&transport.Client{Client: srv.Client(), PlatformURL: srv.URL})

	r, err := NewCertRotator(&CertRotator{
		PKIPaths:     paths,
		PlatformURL:  srv.URL,
		Transport:    swap,
		Subject:      "subj",
		AgentVersion: "test",
		Now:          func() time.Time { return notBefore.Add(8 * 24 * time.Hour) },
		BuildTransport: func(string, enroll.PKIPaths) (*transport.Client, error) {
			return built, nil
		},
	})
	if err != nil {
		t.Fatalf("NewCertRotator: %v", err)
	}

	// The rotation POST itself must succeed, so run it with a working client and
	// only then observe which pool gets retired: swap the tracked client in
	// immediately before rotate reads Get().
	tracker := &countingCloser{inner: srv.Client().Transport}
	swap.Swap(&transport.Client{Client: &http.Client{Transport: tracker}, PlatformURL: srv.URL})
	if err := r.CheckAndRotate(context.Background()); err != nil {
		t.Fatalf("CheckAndRotate: %v", err)
	}

	if swap.Get() != built {
		t.Fatalf("transport was not swapped to the new client")
	}
	if n := tracker.closes.Load(); n != 1 {
		t.Fatalf("displaced pool not retired: CloseIdleConnections called %d times, want 1 — "+
			"old connections keep presenting the PREVIOUS certificate until the server drops them", n)
	}
}

// Degenerate case: if the builder hands back the client already in place,
// closing it would retire connections still in active use.
func TestRotateDoesNotCloseWhenClientIsUnchanged(t *testing.T) {
	srv, paths, notBefore := rotationServer(t)

	tracker := &countingCloser{inner: srv.Client().Transport}
	same := &transport.Client{Client: &http.Client{Transport: tracker}, PlatformURL: srv.URL}
	swap := transport.NewSwappableClient(&transport.Client{Client: srv.Client(), PlatformURL: srv.URL})

	r, err := NewCertRotator(&CertRotator{
		PKIPaths:     paths,
		PlatformURL:  srv.URL,
		Transport:    swap,
		Subject:      "subj",
		AgentVersion: "test",
		Now:          func() time.Time { return notBefore.Add(8 * 24 * time.Hour) },
		BuildTransport: func(string, enroll.PKIPaths) (*transport.Client, error) {
			return same, nil
		},
	})
	if err != nil {
		t.Fatalf("NewCertRotator: %v", err)
	}

	swap.Swap(same) // the client in place IS what the builder returns
	if err := r.CheckAndRotate(context.Background()); err != nil {
		t.Fatalf("CheckAndRotate: %v", err)
	}
	if n := tracker.closes.Load(); n != 0 {
		t.Fatalf("retired a pool that is still live: %d close(s)", n)
	}
}

// A FAILED rotation must retry on a short interval rather than sleeping out the
// full 6h CheckInterval — every boot-time cause clears within minutes, and the
// failure mode of waiting is an EXPIRED cert.
func TestFailureRetryIntervalIsShortAndClamped(t *testing.T) {
	r := &CertRotator{CheckInterval: defaultCheckInterval}
	got := r.failureRetryInterval()
	if got != defaultFailureRetryInterval {
		t.Fatalf("default failure retry = %v, want %v", got, defaultFailureRetryInterval)
	}
	if got >= r.CheckInterval {
		t.Fatalf("failure retry %v must be shorter than CheckInterval %v", got, r.CheckInterval)
	}

	// Never retry LATER than the configured cadence.
	short := &CertRotator{CheckInterval: 30 * time.Second}
	if got := short.failureRetryInterval(); got != 30*time.Second {
		t.Fatalf("clamped failure retry = %v, want 30s", got)
	}

	explicit := &CertRotator{CheckInterval: time.Hour, FailureRetryInterval: 2 * time.Minute}
	if got := explicit.failureRetryInterval(); got != 2*time.Minute {
		t.Fatalf("explicit failure retry = %v, want 2m", got)
	}
}
