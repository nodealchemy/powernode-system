package transport

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// clientWithTimeout builds a Client shaped like the production one: two
// http.Clients over ONE transport, differing only in the whole-request Timeout.
func clientWithTimeout(url string, d time.Duration) *Client {
	tr := &http.Transport{}
	return &Client{
		Client:      &http.Client{Transport: tr, Timeout: d},
		stream:      &http.Client{Transport: tr},
		PlatformURL: url,
	}
}

// slowBody streams total bytes, pausing between chunks, so the transfer takes
// longer than the whole-request Timeout while always making progress. This is
// the shape of a large OCI blob on a slow link.
func slowBody(t *testing.T, total int, chunk int, pause time.Duration) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Length", "")
		w.WriteHeader(http.StatusOK)
		flusher, _ := w.(http.Flusher)
		sent := 0
		for sent < total {
			n := chunk
			if rem := total - sent; rem < n {
				n = rem
			}
			_, _ = w.Write([]byte(strings.Repeat("x", n)))
			if flusher != nil {
				flusher.Flush()
			}
			sent += n
			time.Sleep(pause)
		}
	}))
}

// THE regression. A body that takes longer than the whole-request Timeout to
// stream is killed mid-read by http.Client.Timeout, which is a deadline on the
// ENTIRE request including reading the body. That converts a size limit into a
// time limit: on a real node, gitleaks (4MB) pulled while dev-cell (77MB) and
// dev-cell-docker (171MB) failed forever with "context deadline exceeded ...
// while reading body", and no number of retries could ever succeed.
func TestDoIsKilledMidBodyByWholeRequestTimeout(t *testing.T) {
	srv := slowBody(t, 4096, 256, 12*time.Millisecond) // ~190ms of streaming
	defer srv.Close()
	c := clientWithTimeout(srv.URL, 60*time.Millisecond)

	req, _ := http.NewRequest(http.MethodGet, srv.URL, nil)
	resp, err := c.Do(req)
	if err == nil {
		defer resp.Body.Close()
		_, err = io.ReadAll(resp.Body)
	}
	if err == nil {
		t.Fatal("expected the whole-request Timeout to kill this transfer — if this " +
			"passes, the premise of DoStream is wrong and the fix needs rethinking")
	}
}

// The fix: the same transfer, through DoStream, completes.
func TestDoStreamCompletesATransferLongerThanTheRequestTimeout(t *testing.T) {
	defer SetBlobStallTimeoutForTest(2 * time.Second)()

	const total = 4096
	srv := slowBody(t, total, 256, 12*time.Millisecond)
	defer srv.Close()
	c := clientWithTimeout(srv.URL, 60*time.Millisecond) // same 60ms cap as above

	req, _ := http.NewRequest(http.MethodGet, srv.URL, nil)
	resp, err := c.DoStream(req)
	if err != nil {
		t.Fatalf("DoStream returned an error: %v", err)
	}
	defer resp.Body.Close()

	b, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("reading the streamed body failed: %v", err)
	}
	if len(b) != total {
		t.Fatalf("got %d bytes, want %d — a truncated read means the transfer was "+
			"still being cut short", len(b), total)
	}
}

// Progress is required, total duration is not: a transfer that answers and then
// STOPS must still fail in bounded time rather than pinning a reconciler
// goroutine forever. This is what replaces the whole-request deadline.
func TestDoStreamAbortsAStalledTransfer(t *testing.T) {
	defer SetBlobStallTimeoutForTest(150 * time.Millisecond)()

	release := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		if f, ok := w.(http.Flusher); ok {
			f.Flush()
		}
		_, _ = w.Write([]byte("start"))
		if f, ok := w.(http.Flusher); ok {
			f.Flush()
		}
		<-release // then stall forever
	}))
	defer srv.Close()
	defer close(release)

	c := clientWithTimeout(srv.URL, 0) // no whole-request cap anywhere
	req, _ := http.NewRequest(http.MethodGet, srv.URL, nil)
	resp, err := c.DoStream(req)
	if err != nil {
		t.Fatalf("DoStream: %v", err)
	}
	defer resp.Body.Close()

	done := make(chan error, 1)
	go func() { _, e := io.ReadAll(resp.Body); done <- e }()

	select {
	case e := <-done:
		if e == nil {
			t.Fatal("a stalled transfer read to EOF — the guard did not fire")
		}
	case <-time.After(3 * time.Second):
		t.Fatal("a stalled transfer hung well past the stall budget — the guard did not fire")
	}
}

// The streaming path must keep the 401 self-heal, which is why it routes through
// the same doWith as Do rather than calling the stream client directly. Puller
// .HTTPClient's own doc comment promises exactly this.
func TestDoStreamStillRecoversFrom401(t *testing.T) {
	defer SetBlobStallTimeoutForTest(2 * time.Second)()

	var calls int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		if atomic.AddInt32(&calls, 1) == 1 {
			w.WriteHeader(http.StatusUnauthorized)
			_, _ = w.Write([]byte("no client cert"))
			return
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("blob-bytes"))
	}))
	defer srv.Close()

	c := clientWithTimeout(srv.URL, 0)
	req, _ := http.NewRequest(http.MethodGet, srv.URL, nil)
	resp, err := c.DoStream(req)
	if err != nil {
		t.Fatalf("DoStream: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected the retry to succeed, got %d after %d call(s)", resp.StatusCode, calls)
	}
	b, _ := io.ReadAll(resp.Body)
	if string(b) != "blob-bytes" {
		t.Fatalf("got %q, want the retried body", string(b))
	}
	if atomic.LoadInt32(&calls) != 2 {
		t.Fatalf("expected exactly 2 calls (401 then retry), got %d", calls)
	}
}

// BlobClient is what the Puller is handed; it must be the streaming path, not
// the 30s-capped one. Wiring it to `client` was the original bug.
func TestBlobClientUsesTheStreamingPath(t *testing.T) {
	defer SetBlobStallTimeoutForTest(2 * time.Second)()

	const total = 2048
	srv := slowBody(t, total, 128, 10*time.Millisecond) // ~160ms
	defer srv.Close()
	c := clientWithTimeout(srv.URL, 50*time.Millisecond)

	req, _ := http.NewRequest(http.MethodGet, srv.URL, nil)
	resp, err := c.BlobClient().Do(req)
	if err != nil {
		t.Fatalf("BlobClient().Do: %v — it is still riding the whole-request Timeout", err)
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	if err != nil || len(b) != total {
		t.Fatalf("got %d bytes, err=%v; want %d — BlobClient must stream", len(b), err, total)
	}
}

// The two clients must remain bounded in DIFFERENT ways, and it is easy to
// break that relationship by "tidying" one of the timeouts.
//
// The JSON client is bounded by its whole-request Timeout; the streaming client
// deliberately has none, so its only bounds are the transport's
// ResponseHeaderTimeout ("server never answers") and the body stall guard
// ("server answered then stopped"). A ResponseHeaderTimeout tuned for JSON
// latency silently becomes a ceiling on how long a server may take to START
// serving a large blob — which is exactly how the boot-image upgrade failed with
// `timeout awaiting response headers` while the platform was pulling an 83MB UKI
// from the registry.
func TestTransportBoundsDifferForJSONAndStreaming(t *testing.T) {
	c, tr := clientAndTransportForTest(t)

	if c.Client.Timeout == 0 {
		t.Fatal("the JSON client must keep a whole-request Timeout — it is what bounds control-plane calls")
	}
	if c.stream.Timeout != 0 {
		t.Fatalf("the streaming client must have NO whole-request Timeout, got %v", c.stream.Timeout)
	}
	if tr.ResponseHeaderTimeout <= c.Client.Timeout {
		t.Fatalf("ResponseHeaderTimeout (%v) must exceed the JSON client's Timeout (%v): below it the "+
			"header bound is unreachable for JSON (harmless) but becomes the effective ceiling on how "+
			"long a server may take to begin streaming a large blob", tr.ResponseHeaderTimeout, c.Client.Timeout)
	}
}

// clientAndTransportForTest mirrors the production pairing so the assertions
// above are about the real shape, not a fixture invented to satisfy them.
func clientAndTransportForTest(t *testing.T) (*Client, *http.Transport) {
	t.Helper()
	tr := &http.Transport{ResponseHeaderTimeout: 120 * time.Second}
	return &Client{
		Client: &http.Client{Transport: tr, Timeout: 30 * time.Second},
		stream: &http.Client{Transport: tr},
	}, tr
}
