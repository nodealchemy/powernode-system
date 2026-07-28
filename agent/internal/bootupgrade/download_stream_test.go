package bootupgrade

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/nodealchemy/powernode-system/agent/internal/transport"
)

// slowUKIServer answers after `headerDelay`, then streams `total` bytes in
// chunks with `pause` between them. That is the shape of the real endpoint: the
// platform may have to pull the UKI from the OCI registry before it can answer
// (the delay), and an ~83MB body then takes real time to transfer (the stream).
func slowUKIServer(total, chunk int, headerDelay, pause time.Duration) *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		time.Sleep(headerDelay)
		w.WriteHeader(http.StatusOK)
		f, _ := w.(http.Flusher)
		if f != nil {
			f.Flush()
		}
		sent := 0
		for sent < total {
			n := chunk
			if rem := total - sent; rem < n {
				n = rem
			}
			_, _ = w.Write([]byte(strings.Repeat("u", n)))
			if f != nil {
				f.Flush()
			}
			sent += n
			time.Sleep(pause)
		}
	}))
}

// THE regression, observed on ops-hub 2026-07-28:
//
//	upgrade_boot_image: download UKI: net/http: timeout awaiting response
//	headers
//
// download() used c.Do, whose whole-request Timeout is a deadline on the ENTIRE
// request — not an idle timeout — so a UKI that the platform was slow to start
// serving, or simply large enough to take a while, killed the boot upgrade
// before a single byte reached the ESP. The identical defect was fixed for OCI
// module blobs; that fix corrected the module path and missed this one.
func TestDownload_SurvivesATransferLongerThanTheRequestTimeout(t *testing.T) {
	defer transport.SetBlobStallTimeoutForTest(3 * time.Second)()

	const total = 8192
	srv := slowUKIServer(total, 256, 40*time.Millisecond, 8*time.Millisecond)
	defer srv.Close()

	// 60ms whole-request cap: far shorter than the header delay plus transfer.
	c := transport.NewForTest(srv.URL, 60*time.Millisecond)
	dst := filepath.Join(t.TempDir(), "powernode.uki")

	if err := download(context.Background(), c, "/boot_image/download", dst); err != nil {
		t.Fatalf("download failed on a transfer that merely took longer than the request "+
			"timeout — the boot upgrade is still capped: %v", err)
	}

	fi, err := os.Stat(dst)
	if err != nil {
		t.Fatalf("no file written: %v", err)
	}
	if fi.Size() != total {
		t.Fatalf("wrote %d bytes, want %d — a short write means the transfer was cut off",
			fi.Size(), total)
	}
}

// The control: the capped client MUST fail this same transfer. If this ever
// passes, the premise above is wrong and the fix needs rethinking rather than
// quietly becoming a no-op test.
func TestDownload_CappedClientStillFailsTheSameTransfer(t *testing.T) {
	srv := slowUKIServer(8192, 256, 40*time.Millisecond, 8*time.Millisecond)
	defer srv.Close()

	c := transport.NewForTest(srv.URL, 60*time.Millisecond)
	req, _ := http.NewRequest(http.MethodGet, c.PlatformURL+"/boot_image/download", nil)

	resp, err := c.Do(req) // the OLD path
	if err == nil {
		_, err = readAllAndClose(resp)
	}
	if err == nil {
		t.Fatal("the capped client completed the transfer — the regression premise no longer holds")
	}
}

// A transfer that answers and then STOPS must still fail in bounded time, or the
// uncapped path would hang a boot upgrade forever.
func TestDownload_StalledTransferStillFails(t *testing.T) {
	defer transport.SetBlobStallTimeoutForTest(150 * time.Millisecond)()

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
		<-release
	}))
	defer srv.Close()
	defer close(release)

	c := transport.NewForTest(srv.URL, 0) // no whole-request cap at all
	dst := filepath.Join(t.TempDir(), "powernode.uki")

	done := make(chan error, 1)
	go func() { done <- download(context.Background(), c, "/boot_image/download", dst) }()

	select {
	case err := <-done:
		if err == nil {
			t.Fatal("a stalled download reported success")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("a stalled download hung well past the stall budget")
	}
}

func readAllAndClose(resp *http.Response) (int, error) {
	defer resp.Body.Close()
	buf := make([]byte, 32*1024)
	total := 0
	for {
		n, err := resp.Body.Read(buf)
		total += n
		if err != nil {
			if err.Error() == "EOF" {
				return total, nil
			}
			return total, err
		}
	}
}
