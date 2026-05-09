package transport

import (
	"net/http"
	"sync/atomic"
)

// SwappableClient wraps a *Client behind an atomic pointer so the cert
// rotation goroutine can publish a refreshed mTLS-configured client
// without the heartbeat / reconcile / task-lease loops needing to
// coordinate locks. Reads are wait-free; writes are single-store.
//
// Design intent (Phase 0): introduce the type now so Phase 1's cert
// rotator has a swap target. Existing managers (dockerd/k3sd/sdwan/
// heartbeat) continue accepting *Client for backward compatibility;
// the migration to *SwappableClient happens in Phase 1 alongside the
// cert rotator wiring.
//
// In-flight requests on the previous client complete cleanly because
// http.Client.Do holds a reference to the old TLS state for the
// duration of the request. Both old and new certs verify against the
// same platform CA chain, so no in-flight request fails due to a swap.
type SwappableClient struct {
	inner atomic.Pointer[Client]
}

// NewSwappableClient seeds the wrapper with c. c must not be nil.
func NewSwappableClient(c *Client) *SwappableClient {
	s := &SwappableClient{}
	s.inner.Store(c)
	return s
}

// Get returns the currently-active *Client. Each loop typically calls
// this once per tick and uses the returned pointer for the whole tick;
// a swap mid-tick is fine — the previous tick's pointer remains valid.
func (s *SwappableClient) Get() *Client {
	return s.inner.Load()
}

// Swap replaces the inner client. Old client remains valid for any
// in-flight requests already issued through it.
func (s *SwappableClient) Swap(c *Client) {
	s.inner.Store(c)
}

// PostJSON forwards to the active inner client. Convenience pass-through
// so call sites can use SwappableClient directly without an explicit Get.
func (s *SwappableClient) PostJSON(path string, body []byte) (*http.Response, error) {
	return s.inner.Load().PostJSON(path, body)
}

// GetJSON forwards to the active inner client.
func (s *SwappableClient) GetJSON(path string) (*http.Response, error) {
	return s.inner.Load().GetJSON(path)
}
