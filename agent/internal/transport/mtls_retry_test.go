package transport

import (
	"bytes"
	"crypto/tls"
	"crypto/x509"
	"io"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
)

// poisonServer reproduces the ops-hub failure exactly: a TLS server that
// initially does NOT ask for a client certificate (the reverse proxy before its
// clientAuth dynamic config has landed), and later does. A connection
// negotiated during the first phase carries no peer certificate for its whole
// lifetime, so the handler answers 401 on it forever — which is precisely why
// the real agent never recovered without a restart.
type poisonServer struct {
	srv          *httptest.Server
	requestCerts atomic.Bool
	mu           sync.Mutex
	handshakes   int
	requests     int
}

func newPoisonServer(t *testing.T) *poisonServer {
	t.Helper()
	ps := &poisonServer{}

	ps.srv = httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ps.mu.Lock()
		ps.requests++
		ps.mu.Unlock()
		// Mirrors the platform: authorization is decided purely by whether a
		// client certificate arrived on this connection.
		if r.TLS == nil || len(r.TLS.PeerCertificates) == 0 {
			w.WriteHeader(http.StatusUnauthorized)
			_, _ = io.WriteString(w, `{"error":"mTLS client certificate required"}`)
			return
		}
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, `{"ok":true}`)
	}))

	ps.srv.TLS = &tls.Config{
		MinVersion: tls.VersionTLS13,
		GetConfigForClient: func(*tls.ClientHelloInfo) (*tls.Config, error) {
			ps.mu.Lock()
			ps.handshakes++
			ps.mu.Unlock()
			cfg := &tls.Config{
				MinVersion:   tls.VersionTLS13,
				Certificates: ps.srv.TLS.Certificates,
			}
			if ps.requestCerts.Load() {
				cfg.ClientAuth = tls.RequestClientCert
			}
			return cfg, nil
		},
	}
	ps.srv.StartTLS()
	t.Cleanup(ps.srv.Close)
	return ps
}

func (ps *poisonServer) counts() (handshakes, requests int) {
	ps.mu.Lock()
	defer ps.mu.Unlock()
	return ps.handshakes, ps.requests
}

// clientFor builds a transport.Client that trusts the test server and always
// offers a client certificate when asked.
func clientFor(t *testing.T, ps *poisonServer) *Client {
	t.Helper()
	pool := x509.NewCertPool()
	pool.AddCert(ps.srv.Certificate())

	// Reuse the server's own leaf as the client identity — the test only cares
	// whether A certificate is presented, not who signed it.
	clientCert := tls.Certificate{
		Certificate: [][]byte{ps.srv.Certificate().Raw},
		PrivateKey:  ps.srv.TLS.Certificates[0].PrivateKey,
	}

	return &Client{
		Client: &http.Client{
			Transport: &http.Transport{
				TLSClientConfig: &tls.Config{
					Certificates: []tls.Certificate{clientCert},
					RootCAs:      pool,
					MinVersion:   tls.VersionTLS13,
				},
			},
		},
		PlatformURL: ps.srv.URL,
	}
}

// THE regression test. Without the retry this fails exactly as ops-hub did:
// the second request rides the poisoned pooled connection and 401s forever.
func TestDoRecoversFromConnectionNegotiatedWithoutClientCert(t *testing.T) {
	ps := newPoisonServer(t)
	c := clientFor(t, ps)

	// Phase 1: proxy not yet asking for certs. This must leave a REUSABLE
	// connection in the pool, or the test proves nothing — see below.
	//
	// Deliberately bypasses c.Do: calling the wrapper here would trigger its
	// own eviction+retry and destroy the very pooled connection this test needs
	// to poison. Phase 1 is setup, not the behaviour under test.
	req, _ := http.NewRequest(http.MethodGet, ps.srv.URL+"/api/v1/system/node_api/status", nil)
	resp, err := c.Client.Do(req)
	if err != nil {
		t.Fatalf("phase 1 request: %v", err)
	}
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("phase 1 should 401 (no cert requested), got %d", resp.StatusCode)
	}
	// Go only returns a connection to the idle pool when its body is read to
	// EOF *and* closed. Closing without draining discards the connection, so
	// phase 2 would silently get a fresh handshake and pass even with the fix
	// removed — which is exactly how the first version of this test fooled me.
	_, _ = io.Copy(io.Discard, resp.Body)
	_ = resp.Body.Close()

	if h, _ := ps.counts(); h != 1 {
		t.Fatalf("setup: expected exactly 1 handshake so far, got %d", h)
	}

	// Phase 2: proxy's clientAuth config lands. The pooled connection is
	// unaffected — recovery must come from evicting and re-handshaking.
	ps.requestCerts.Store(true)

	resp2, err := c.GetJSON("/api/v1/system/node_api/status")
	if err != nil {
		t.Fatalf("phase 2 request: %v", err)
	}
	defer resp2.Body.Close()
	if resp2.StatusCode != http.StatusOK {
		t.Fatalf("still 401 after the proxy began requesting certs — the agent is stuck exactly as ops-hub was (got %d)", resp2.StatusCode)
	}

	handshakes, _ := ps.counts()
	if handshakes < 2 {
		t.Fatalf("expected a second TLS handshake after eviction, saw %d", handshakes)
	}
}

// A genuine rejection must stay a rejection — one extra handshake, then the
// 401 is returned unchanged rather than retried forever.
func TestDoReturnsRealUnauthorizedAfterOneRetry(t *testing.T) {
	ps := newPoisonServer(t) // never starts requesting certs
	c := clientFor(t, ps)

	resp, err := c.GetJSON("/whatever")
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected the real 401 to survive, got %d", resp.StatusCode)
	}
	_, requests := ps.counts()
	if requests != 2 {
		t.Fatalf("expected exactly 2 attempts (original + one retry), got %d", requests)
	}
}

// POSTs must be replayed with their body intact, or the retry silently sends an
// empty heartbeat.
func TestDoReplaysRequestBodyOnRetry(t *testing.T) {
	var got [][]byte
	var mu sync.Mutex
	requestCerts := &atomic.Bool{}

	srv := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		mu.Lock()
		got = append(got, b)
		mu.Unlock()
		if !requestCerts.Load() {
			requestCerts.Store(true)
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		w.WriteHeader(http.StatusOK)
	}))
	srv.StartTLS()
	defer srv.Close()

	pool := x509.NewCertPool()
	pool.AddCert(srv.Certificate())
	c := &Client{
		Client: &http.Client{Transport: &http.Transport{
			TLSClientConfig: &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS13},
		}},
		PlatformURL: srv.URL,
	}

	payload := []byte(`{"boot_id":"abc","uptime":42}`)
	resp, err := c.PostJSON("/api/v1/system/node_api/status/heartbeat", payload)
	if err != nil {
		t.Fatalf("post: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200 after retry, got %d", resp.StatusCode)
	}

	mu.Lock()
	defer mu.Unlock()
	if len(got) != 2 {
		t.Fatalf("expected 2 attempts, got %d", len(got))
	}
	if !bytes.Equal(got[0], payload) || !bytes.Equal(got[1], payload) {
		t.Fatalf("retry lost the body: first=%q second=%q want=%q", got[0], got[1], payload)
	}
}

// Non-401 responses must pass through untouched — no eviction, no extra
// handshake, no double-send of a mutating request.
func TestDoDoesNotRetryNon401(t *testing.T) {
	var attempts atomic.Int32
	srv := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		attempts.Add(1)
		w.WriteHeader(http.StatusInternalServerError)
	}))
	srv.StartTLS()
	defer srv.Close()

	pool := x509.NewCertPool()
	pool.AddCert(srv.Certificate())
	c := &Client{
		Client: &http.Client{Transport: &http.Transport{
			TLSClientConfig: &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS13},
		}},
		PlatformURL: srv.URL,
	}

	resp, err := c.GetJSON("/x")
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusInternalServerError {
		t.Fatalf("expected 500 passthrough, got %d", resp.StatusCode)
	}
	if n := attempts.Load(); n != 1 {
		t.Fatalf("500 must not be retried; saw %d attempts", n)
	}
}
