package transport

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

// Auth model: mTLS only. Requests carry no Bearer header — the client cert
// presented at TLS handshake time is the credential, and the reverse proxy
// (Traefik v3 with tls.options=mtls-required@file) is responsible for
// verifying it against the platform's internal CA. PostJSON / GetJSON
// must not inject an Authorization header.

func TestPostJSON_NoAuthorizationHeader(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got := r.Header.Get("Authorization"); got != "" {
			t.Errorf("expected no Authorization header on PostJSON, got %q", got)
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	c := &Client{Client: srv.Client(), PlatformURL: srv.URL}
	resp, err := c.PostJSON("/anything", []byte(`{}`))
	if err != nil {
		t.Fatalf("PostJSON: %v", err)
	}
	resp.Body.Close()
}

func TestGetJSON_NoAuthorizationHeader(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got := r.Header.Get("Authorization"); got != "" {
			t.Errorf("expected no Authorization header on GetJSON, got %q", got)
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	c := &Client{Client: srv.Client(), PlatformURL: srv.URL}
	resp, err := c.GetJSON("/anything")
	if err != nil {
		t.Fatalf("GetJSON: %v", err)
	}
	resp.Body.Close()
}
