package transport

import (
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
)

func TestSwappableClientGet(t *testing.T) {
	c := &Client{Client: &http.Client{}, PlatformURL: "https://a.example"}
	s := NewSwappableClient(c)

	if got := s.Get(); got != c {
		t.Errorf("Get returned different pointer: got %p want %p", got, c)
	}
}

func TestSwappableClientSwap(t *testing.T) {
	first := &Client{Client: &http.Client{}, PlatformURL: "https://a.example"}
	second := &Client{Client: &http.Client{}, PlatformURL: "https://b.example"}
	s := NewSwappableClient(first)

	s.Swap(second)
	if got := s.Get(); got != second {
		t.Errorf("after swap got %p, want %p", got, second)
	}
	if got := s.Get().PlatformURL; got != "https://b.example" {
		t.Errorf("PlatformURL after swap: got %q", got)
	}
}

// TestSwappableClientConcurrent verifies the swap is race-clean under
// the race detector. Two writers and many readers race on the same
// SwappableClient.
func TestSwappableClientConcurrent(t *testing.T) {
	a := &Client{Client: &http.Client{}, PlatformURL: "a"}
	b := &Client{Client: &http.Client{}, PlatformURL: "b"}
	s := NewSwappableClient(a)

	const writers = 4
	const readers = 16
	const iterations = 200

	var reads atomic.Int64

	var wg sync.WaitGroup
	for i := 0; i < writers; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			for j := 0; j < iterations; j++ {
				if (i+j)%2 == 0 {
					s.Swap(a)
				} else {
					s.Swap(b)
				}
			}
		}(i)
	}
	for i := 0; i < readers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < iterations; j++ {
				c := s.Get()
				_ = c.PlatformURL
				reads.Add(1)
			}
		}()
	}
	wg.Wait()

	if reads.Load() != int64(readers*iterations) {
		t.Errorf("reads count off: %d", reads.Load())
	}
}

// TestSwappableClientPassThrough exercises the PostJSON/GetJSON
// convenience methods against an httptest server. Confirms that the
// wrapper forwards requests to the active inner client.
func TestSwappableClientPassThrough(t *testing.T) {
	hits := atomic.Int32{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer srv.Close()

	c := &Client{Client: srv.Client(), PlatformURL: srv.URL}
	s := NewSwappableClient(c)

	resp, err := s.GetJSON("/probe")
	if err != nil {
		t.Fatalf("GetJSON: %v", err)
	}
	resp.Body.Close()

	resp2, err := s.PostJSON("/probe", []byte(`{}`))
	if err != nil {
		t.Fatalf("PostJSON: %v", err)
	}
	resp2.Body.Close()

	if hits.Load() != 2 {
		t.Errorf("expected 2 hits, got %d", hits.Load())
	}
}
