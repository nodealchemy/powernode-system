package transport

import (
	"io"
	"net/http"
	"sync"
	"sync/atomic"
	"testing"
)

// TestDoRecoversUnderConcurrentCallers pins the property the single-threaded
// tests cannot: once the proxy starts requesting client certificates, EVERY
// caller converges, and no caller keeps 401ing because a poisoned connection
// was handed back to it.
//
// This is the shape the real agent runs in — heartbeat, task lease, the
// authorized_keys syncer, the reconcilers and the migration runner all share
// one *Client and poll near-simultaneously, so the recovery boundary is
// inherently concurrent. A version of Do that returns the poisoned connection
// to the idle pool (rather than letting Go destroy it) lets that connection
// daisy-chain between goroutines: one worker evicts, another checks the same
// bad connection straight back out, and the "if the retry also 401s the
// rejection is real" invariant becomes false.
func TestDoRecoversUnderConcurrentCallers(t *testing.T) {
	ps := newPoisonServer(t)
	c := clientFor(t, ps)

	// Poison a whole POOL, not one connection: at node boot the heartbeat, task
	// lease, reconcilers and keys syncer each open their own connection during
	// the window before the proxy asks for certs, so recovery has to contend
	// with several bad connections, not one.
	const seeds = 16
	var seedWG sync.WaitGroup
	for i := 0; i < seeds; i++ {
		seedWG.Add(1)
		go func() {
			defer seedWG.Done()
			req, _ := http.NewRequest(http.MethodGet, ps.srv.URL+"/seed", nil)
			resp, err := c.Client.Do(req) // bypass the wrapper: this is setup
			if err != nil {
				return
			}
			// Drain + close so the connection is POOLED (an undrained close
			// makes Go destroy it, which would defeat the seeding).
			_, _ = io.Copy(io.Discard, resp.Body)
			_ = resp.Body.Close()
		}()
	}
	seedWG.Wait()

	// The proxy's clientAuth config lands.
	ps.requestCerts.Store(true)

	const workers = 32
	const rounds = 8
	var stuck atomic.Int32
	var wg sync.WaitGroup

	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for r := 0; r < rounds; r++ {
				resp, err := c.GetJSON("/api/v1/system/node_api/status")
				if err != nil {
					t.Errorf("request error: %v", err)
					return
				}
				code := resp.StatusCode
				_ = resp.Body.Close()
				if code != http.StatusOK {
					// After the flip, a wrapper call that still returns 401 means
					// the retry did not get a fresh handshake.
					stuck.Add(1)
				}
			}
		}()
	}
	wg.Wait()

	if n := stuck.Load(); n != 0 {
		t.Fatalf("%d/%d wrapper calls still 401 after the proxy began requesting certs — "+
			"the retry is not guaranteed a fresh handshake under concurrency", n, workers*rounds)
	}
}
