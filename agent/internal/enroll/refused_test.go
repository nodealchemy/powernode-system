package enroll

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestEnrollClassifiesClientErrorsAsRefused(t *testing.T) {
	for code, want := range map[int]bool{400: true, 401: true, 403: true, 422: true, 408: false, 429: false, 500: false, 503: false} {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(code) }))
		c := &Client{PlatformURL: srv.URL, CABundlePEM: []byte("x"), CAFingerprint: "", HTTPClient: srv.Client()}
		_, err := c.Enroll(context.Background(), EnrollRequest{BootstrapToken: "not-a-real-enrol-key", Subject: "s"})
		srv.Close()
		if err == nil {
			t.Fatalf("%d: expected error", code)
		}
		if IsRefused(err) != want {
			t.Errorf("status %d: IsRefused=%v want %v (%v)", code, IsRefused(err), want, err)
		}
	}
}
